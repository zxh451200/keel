//! 手动备份与恢复。
//!
//! - 备份用 `VACUUM INTO`，得到一份一致的单文件副本（WAL 里的内容也包含在内），放在数据库旁的 `backups/`。
//! - 只保留最新 [`KEEP`] 份。界面只能用备份的"名字"，不能传路径（名字格式严格校验）。
//! - 恢复不是立刻覆盖正在使用的数据库，而是先校验备份、写一个"待恢复"标记，下次启动打开数据库之前再换：
//!   旧数据库改名为 `.pre-restore-<毫秒>` 保留，不删除。

use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::{access, audit};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::SqlitePool;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

// 仅串行运行期登记/取消；apply_pending 必须在启动发布数据库和用户前执行。
static RESTORE_LOCK: Mutex<()> = Mutex::const_new(());

/// 最多保留的手动备份数。
pub const KEEP: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupFile {
    pub name: String,
    pub size_bytes: u64,
    /// UTC epoch 毫秒（取文件修改时间）
    pub modified_ms: i64,
}

/// 备份目录：数据库文件所在目录下的 `backups`。
pub fn backups_dir(db_path: &Path) -> PathBuf {
    db_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("backups")
}

/// 备份名只能是 `keel-<毫秒>.db`。界面传来的名字先过这里，不让路径片段混进来。
pub fn validate_name(name: &str) -> Result<u128, KeelError> {
    let digits = name
        .strip_prefix("keel-")
        .and_then(|rest| rest.strip_suffix(".db"))
        .filter(|d| !d.is_empty() && d.len() <= 20 && d.bytes().all(|b| b.is_ascii_digit()));
    match digits.and_then(|d| d.parse::<u128>().ok()) {
        Some(ms) => Ok(ms),
        None => Err(KeelError::Validation("备份名无效".into())),
    }
}

/// 列出备份，最新的在前。
pub fn list(db_path: &Path) -> Result<Vec<BackupFile>, KeelError> {
    let dir = backups_dir(db_path);
    let entries = match std::fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e.into()),
    };
    let mut files: Vec<(u128, BackupFile)> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(stamp) = validate_name(&name) else {
            continue;
        };
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        let modified_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64)
            .unwrap_or_default();
        files.push((
            stamp,
            BackupFile {
                name,
                size_bytes: meta.len(),
                modified_ms,
            },
        ));
    }
    files.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    Ok(files.into_iter().map(|(_, file)| file).collect())
}

/// 立即备份。需要"创建备份"权限，写审计。
pub async fn create(pool: &SqlitePool, db_path: &Path) -> Result<BackupFile, KeelError> {
    access::require(pool, Permission::BackupCreate).await?;
    let dir = backups_dir(db_path);
    std::fs::create_dir_all(&dir)?;

    let mut stamp = audit::now_ms().max(0) as u128;
    let mut path = dir.join(format!("keel-{stamp}.db"));
    while path.exists() {
        stamp += 1;
        path = dir.join(format!("keel-{stamp}.db"));
    }
    sqlx::query("VACUUM INTO ?1")
        .bind(path.to_string_lossy().into_owned())
        .execute(pool)
        .await
        .map_err(|e| KeelError::Backup(format!("备份失败：{e}")))?;

    prune(db_path, KEEP);
    audit::record(pool, "backup.create", &format!("keel-{stamp}.db"), "ok").await?;
    list(db_path)?
        .into_iter()
        .find(|f| f.name == format!("keel-{stamp}.db"))
        .ok_or(KeelError::NotFound)
}

/// 删除最旧的备份，只留 `keep` 份。清理失败不影响备份本身。
pub fn prune(db_path: &Path, keep: usize) {
    let Ok(files) = list(db_path) else {
        return;
    };
    let dir = backups_dir(db_path);
    for file in files.into_iter().skip(keep) {
        let _ = std::fs::remove_file(dir.join(file.name));
    }
}

/// 待恢复标记文件。内容是要恢复的备份名。
pub fn marker_path(db_path: &Path) -> PathBuf {
    let mut name = db_path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".restore-pending");
    db_path.with_file_name(name)
}

pub fn pending_restore(db_path: &Path) -> Option<String> {
    let name = std::fs::read_to_string(marker_path(db_path)).ok()?;
    let name = name.trim().to_string();
    validate_name(&name).ok()?;
    Some(name)
}

fn clear_restore_marker(db_path: &Path) -> Result<bool, KeelError> {
    match std::fs::remove_file(marker_path(db_path)) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.into()),
    }
}

/// 用户取消恢复：先授权，即使没有标记也不能绕过权限检查。
///
/// 固定 target 不读取或记录标记正文（正文可能损坏或含敏感路径）。
/// request 审计落盘后才删除；无标记幂等返回，不记成功。
/// SQLite 与文件系统没有共同事务：删除失败/崩溃可能只留下 request；
/// 删除后成功审计失败时标记已清除，返回明确错误，不伪造回滚。
pub async fn cancel_restore(pool: &SqlitePool, db_path: &Path) -> Result<(), KeelError> {
    let _guard = RESTORE_LOCK.lock().await;
    let actor = access::require(pool, Permission::BackupRestore).await?;
    match std::fs::symlink_metadata(marker_path(db_path)) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    }
    audit::record_as(
        pool,
        &actor.name,
        "backup.restore.cancel.request",
        "pending restore",
        "requested",
    )
    .await?;
    if clear_restore_marker(db_path)? {
        audit::record_as(
            pool,
            &actor.name,
            "backup.restore.cancel",
            "pending restore",
            "ok",
        )
        .await
        .map_err(|_| KeelError::Backup("恢复已取消，但成功审计写入失败".into()))?;
    }
    Ok(())
}

/// 校验一份备份：能打开、完整性检查通过、有审计表。
pub async fn verify(path: &Path) -> Result<(), KeelError> {
    let options = SqliteConnectOptions::new().filename(path).read_only(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(|_| KeelError::Backup("备份文件无法打开".into()))?;
    let integrity: Result<String, sqlx::Error> = sqlx::query_scalar("PRAGMA integrity_check")
        .fetch_one(&pool)
        .await;
    let table: Result<Option<(i64,)>, sqlx::Error> =
        sqlx::query_as("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'audit_log'")
            .fetch_optional(&pool)
            .await;
    pool.close().await;
    match (integrity, table) {
        (Ok(ok), Ok(Some(_))) if ok == "ok" => Ok(()),
        _ => Err(KeelError::Backup("备份文件校验未通过".into())),
    }
}

/// 登记一次恢复：校验备份、写待恢复标记，下次启动时生效。需要"恢复"权限，写审计。
pub async fn schedule_restore(
    pool: &SqlitePool,
    db_path: &Path,
    name: &str,
) -> Result<(), KeelError> {
    let _guard = RESTORE_LOCK.lock().await;
    let actor = access::require(pool, Permission::BackupRestore).await?;
    validate_name(name)?;
    let file = backups_dir(db_path).join(name);
    if !file.is_file() {
        return Err(KeelError::NotFound);
    }
    verify(&file).await?;
    write_restore_marker(db_path, name)?;
    audit::record_as(pool, &actor.name, "backup.restore.schedule", name, "ok").await
}

/// 启动时、打开数据库之前调用：有待恢复标记就执行恢复，返回恢复用的备份名。
///
/// 旧数据库（含 -wal / -shm）改名为 `.pre-restore-<毫秒>` 保留，不删除。
/// 恢复失败时尽量还原旧文件，并且无论成败都清掉标记，避免每次启动都重试。
pub fn apply_pending(db_path: &Path) -> Result<Option<String>, KeelError> {
    let Some(name) = pending_restore(db_path) else {
        // 标记内容无效也清掉，免得一直残留。
        clear_restore_marker(db_path)?;
        return Ok(None);
    };
    let result = swap_in(db_path, &name);
    let _ = clear_restore_marker(db_path);
    result.map(|()| Some(name))
}

fn suffixed(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(suffix);
    path.with_file_name(name)
}

fn unique_temp_path(path: &Path, suffix: &str) -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let pid = std::process::id();
    for attempt in 0..100u32 {
        let candidate = suffixed(path, &format!("{suffix}-{pid}-{stamp}-{attempt}"));
        if std::fs::symlink_metadata(&candidate).is_err() {
            return candidate;
        }
    }
    // The caller still uses create/rename semantics and will return a safe I/O error
    // if an adversary continually occupies every candidate.
    suffixed(path, &format!("{suffix}-{pid}-{stamp}-fallback"))
}

fn write_restore_marker(db_path: &Path, name: &str) -> Result<(), KeelError> {
    let marker = marker_path(db_path);
    if let Ok(metadata) = std::fs::symlink_metadata(&marker)
        && metadata.file_type().is_symlink()
    {
        return Err(KeelError::Validation("恢复标记路径不安全".into()));
    }
    let tmp = unique_temp_path(db_path, ".restore-pending-tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    let mut file = options.open(&tmp)?;
    let write_result = (|| -> Result<(), std::io::Error> {
        file.write_all(name.as_bytes())?;
        file.sync_all()
    })();
    drop(file);
    if let Err(error) = write_result.and_then(|()| std::fs::rename(&tmp, &marker)) {
        let _ = std::fs::remove_file(&tmp);
        return Err(error.into());
    }
    Ok(())
}

fn swap_in(db_path: &Path, name: &str) -> Result<(), KeelError> {
    let source = backups_dir(db_path).join(name);
    if !source.is_file() {
        return Err(KeelError::NotFound);
    }
    let tmp = unique_temp_path(db_path, ".restore-tmp");
    std::fs::copy(&source, &tmp)?;

    let stamp = audit::now_ms().max(0);
    let moved: Vec<(PathBuf, PathBuf)> = ["", "-wal", "-shm"]
        .iter()
        .map(|ext| {
            (
                suffixed(db_path, ext),
                suffixed(db_path, &format!(".pre-restore-{stamp}{ext}")),
            )
        })
        .filter(|(from, _)| from.exists())
        .collect();

    for (from, to) in &moved {
        if let Err(e) = std::fs::rename(from, to) {
            let _ = std::fs::remove_file(&tmp);
            rollback(&moved);
            return Err(e.into());
        }
    }
    if let Err(e) = std::fs::rename(&tmp, db_path) {
        let _ = std::fs::remove_file(&tmp);
        rollback(&moved);
        return Err(e.into());
    }
    Ok(())
}

/// 把已经改名的旧文件放回去。
fn rollback(moved: &[(PathBuf, PathBuf)]) {
    for (from, to) in moved {
        if to.exists() {
            let _ = std::fs::rename(to, from);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_strict_backup_names_are_accepted() {
        assert!(validate_name("keel-1730000000000.db").is_ok());
        for bad in [
            "",
            "keel-.db",
            "keel-12a.db",
            "../keel-1.db",
            "keel-1.db/..",
            "keel-1.db.bak",
            "other-1.db",
            "keel-123456789012345678901.db",
        ] {
            assert!(validate_name(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn marker_sits_next_to_the_database() {
        let marker = marker_path(Path::new("/data/keel.db"));
        assert_eq!(marker, Path::new("/data/keel.db.restore-pending"));
    }
}
