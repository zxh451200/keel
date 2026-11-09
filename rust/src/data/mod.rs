//! 数据访问层：连接池、迁移、查询。SQL 只写在这一层（AGENTS.md §3）。

pub mod audit;
pub(crate) mod audit_export_history;
pub mod auth;
pub mod customer;
pub(crate) mod grid_preferences;
// Isolated POC has no product entry point; integration tests load this source.
#[allow(dead_code)]
pub(crate) mod grid_fixture;
pub mod user;
pub(crate) mod user_import;

use crate::errors::KeelError;
use sqlx::migrate::Migrator;
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions};
use sqlx::SqlitePool;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// 迁移前备份最多保留几份。
const KEEP_PRE_MIGRATION_BACKUPS: usize = 3;
static OPEN_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

/// 打开（必要时创建）数据库并执行迁移。
///
/// 连接参数：WAL、外键开启、`busy_timeout` 5 秒（初值，以并发测试结果为准，AGENTS.md §5.2）。
/// 数据库文件已存在且有待执行的迁移时，先在旁边做一份备份；备份失败就不迁移。
pub async fn open(path: &Path) -> Result<SqlitePool, KeelError> {
    let lock = OPEN_LOCK.get_or_init(|| tokio::sync::Mutex::new(()));
    let _guard = lock.lock().await;
    let existed = path.exists();

    let options = SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(true)
        .foreign_keys(true)
        .journal_mode(SqliteJournalMode::Wal)
        .busy_timeout(Duration::from_millis(5000));
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(options)
        .await?;

    let migrator = sqlx::migrate!("./migrations");
    if existed && has_pending(&pool, &migrator).await? {
        pre_migration_backup(&pool, path).await?;
    }
    migrator.run(&pool).await.map_err(KeelError::DbMigration)?;
    Ok(pool)
}

async fn applied_versions(pool: &SqlitePool) -> Result<Vec<i64>, KeelError> {
    let table: Option<(i64,)> = sqlx::query_as(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'",
    )
    .fetch_optional(pool)
    .await?;
    if table.is_none() {
        return Ok(Vec::new());
    }
    let rows: Vec<(i64,)> =
        sqlx::query_as("SELECT version FROM _sqlx_migrations WHERE success = 1")
            .fetch_all(pool)
            .await?;
    Ok(rows.into_iter().map(|row| row.0).collect())
}

async fn has_pending(pool: &SqlitePool, migrator: &Migrator) -> Result<bool, KeelError> {
    let applied = applied_versions(pool).await?;
    Ok(migrator.iter().any(|m| !applied.contains(&m.version)))
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default()
}

fn backup_prefix(db_path: &Path) -> String {
    let name = db_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "db".to_string());
    format!("{name}.pre-migration-")
}

/// 用 `VACUUM INTO` 生成一份一致的备份（WAL 里的内容也包含在内），只保留最新几份。
async fn pre_migration_backup(pool: &SqlitePool, db_path: &Path) -> Result<PathBuf, KeelError> {
    let dir = db_path.parent().unwrap_or_else(|| Path::new("."));
    let prefix = backup_prefix(db_path);
    let target = dir.join(format!("{prefix}{}", now_ms()));
    sqlx::query("VACUUM INTO ?1")
        .bind(target.to_string_lossy().into_owned())
        .execute(pool)
        .await
        .map_err(|e| KeelError::Backup(format!("迁移前备份失败：{e}")))?;
    prune_pre_migration(dir, &prefix, KEEP_PRE_MIGRATION_BACKUPS);
    Ok(target)
}

/// 删除最旧的迁移前备份，只留 `keep` 份。清理失败不影响迁移。
fn prune_pre_migration(dir: &Path, prefix: &str, keep: usize) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut backups: Vec<PathBuf> = entries
        .flatten()
        .filter(|entry| {
            entry
                .file_type()
                .map(|kind| kind.is_file())
                .unwrap_or(false)
                && entry.file_name().to_string_lossy().starts_with(prefix)
        })
        .map(|entry| entry.path())
        .collect();
    backups.sort();
    let excess = backups.len().saturating_sub(keep);
    for path in backups.into_iter().take(excess) {
        let _ = std::fs::remove_file(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("keel-data-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn prune_keeps_only_newest_matching_backups() {
        let dir = temp_dir("prune");
        let prefix = "main.db.pre-migration-";
        for suffix in ["0001", "0002", "0003", "0004"] {
            std::fs::write(dir.join(format!("{prefix}{suffix}")), suffix).unwrap();
        }
        std::fs::write(dir.join("other.db.pre-migration-0000"), "keep").unwrap();
        std::fs::create_dir(dir.join(format!("{prefix}directory"))).unwrap();

        prune_pre_migration(&dir, prefix, 3);

        assert!(!dir.join(format!("{prefix}0001")).exists());
        for suffix in ["0002", "0003", "0004"] {
            assert!(dir.join(format!("{prefix}{suffix}")).exists());
        }
        assert!(dir.join("other.db.pre-migration-0000").exists());
        assert!(dir.join(format!("{prefix}directory")).exists());
        let _ = std::fs::remove_dir_all(dir);
    }
}
