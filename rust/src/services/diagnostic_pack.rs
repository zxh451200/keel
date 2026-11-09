//! 诊断包：把环境信息和最近的诊断事件整理成一份文本，导出前先给用户预览。
//!
//! runtime 只采集版本、系统和架构；recent_events 必须显式选择。不读取原始日志、配置或 DB 内容。
//! 快照只缓存已经二次脱敏的文本，导出不重读事件；缓存锁不跨 await 或文件 IO。
//! 脱敏是规则匹配，不保证识别所有敏感内容，所以导出前一定要让用户看到将要写入的内容。

/// 内部入口：调用者须传入完整、已脱敏的文本。绝不重读来源或再次截短。
/// 与采集预览共享容量、TTL、owner 和单次导出语义，不扩大采集类别白名单。
pub(crate) fn register_redacted_snapshot(
    owner: &access::CurrentUser,
    content: &str,
) -> Result<String, KeelError> {
    if content.len() > MAX_CONTENT_BYTES {
        return Err(KeelError::Validation("诊断快照超过 1 MiB".into()));
    }
    let mut cache = cache()
        .lock()
        .map_err(|_| KeelError::internal("diagnostic cache unavailable"))?;
    // 等待缓存锁后复查完整身份与权限；句柄本身从不充当授权凭据。
    let current = access::current()?;
    if current != *owner || !current.role.allows(Permission::DiagnosticsExport) {
        return Err(KeelError::PermissionDenied(
            "diagnostics.preview.owner".into(),
        ));
    }
    let nonce = new_correlation_id();
    let preview_id = format!(
        "{:016x}{:016x}",
        RandomState::new().hash_one((&nonce, 0_u8)),
        RandomState::new().hash_one((&nonce, 1_u8))
    );
    let now = Instant::now();
    cache.insert(
        PreparedPack {
            id: preview_id.clone(),
            owner: owner.clone(),
            created: now,
            content: content.to_owned(),
        },
        now,
    );
    Ok(preview_id)
}

use crate::api::diagnostics::{DiagnosticPackPreview, DiagnosticPackRequest};
use crate::diagnostics::correlation::new_correlation_id;
use crate::diagnostics::events::{self, Event, Level};
use crate::diagnostics::redact::redact;
use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::{access, audit};
use sqlx::SqlitePool;
use std::collections::{hash_map::RandomState, VecDeque};
use std::fs::OpenOptions;
use std::hash::BuildHasher;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// 诊断包里最多放多少条事件。
pub const MAX_EVENTS: usize = 500;
const CACHE_CAPACITY: usize = 6;
const CACHE_TTL: Duration = Duration::from_secs(300);
const MAX_CONTENT_BYTES: usize = 1024 * 1024;

struct PreparedPack {
    id: String,
    owner: access::CurrentUser,
    created: Instant,
    content: String,
}

#[derive(Default)]
struct PreviewCache {
    items: VecDeque<PreparedPack>,
}

impl PreviewCache {
    fn prune(&mut self, now: Instant) {
        self.items
            .retain(|p| now.saturating_duration_since(p.created) < CACHE_TTL);
    }

    fn insert(&mut self, pack: PreparedPack, now: Instant) {
        self.prune(now);
        while self.items.len() >= CACHE_CAPACITY {
            self.items.pop_front();
        }
        self.items.push_back(pack);
    }

    fn take(
        &mut self,
        id: &str,
        owner: &access::CurrentUser,
        now: Instant,
    ) -> Result<PreparedPack, KeelError> {
        self.prune(now);
        let index =
            self.items.iter().position(|p| p.id == id).ok_or_else(|| {
                KeelError::Validation("预览已失效或已消费，请重新 prepare".into())
            })?;
        if &self.items[index].owner != owner {
            return Err(KeelError::PermissionDenied(
                "diagnostics.preview.owner".into(),
            ));
        }
        // 同一把锁内检查并移除；并发导出只有一个能消费。
        self.items
            .remove(index)
            .ok_or_else(|| KeelError::internal("preview removed"))
    }
}

fn cache() -> &'static Mutex<PreviewCache> {
    static CACHE: OnceLock<Mutex<PreviewCache>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(PreviewCache::default()))
}

fn categories(input: &[String]) -> Result<Vec<String>, KeelError> {
    let mut runtime = false;
    let mut recent = false;
    for name in input {
        match name.as_str() {
            "runtime" => runtime = true,
            "recent_events" => recent = true,
            // 不把未知输入写入错误/诊断（输入可能包含正文或 token）。
            _ => return Err(KeelError::Validation("未知诊断包类别".into())),
        }
    }
    let mut result = Vec::new();
    if runtime {
        result.push("runtime".into());
    }
    if recent {
        result.push("recent_events".into());
    }
    if result.is_empty() {
        return Err(KeelError::Validation("至少选择一个诊断包类别".into()));
    }
    Ok(result)
}

fn compose_selected(events: &[Event], version: &str, selected: &[String]) -> (String, u32) {
    let mut out = String::from("Keel diagnostic pack\n");
    out.push_str(&format!("categories: {}\n", selected.join(", ")));
    if selected.iter().any(|c| c == "runtime") {
        out.push_str(&format!(
            "version: {version}\nplatform: {} {}\n",
            std::env::consts::OS,
            std::env::consts::ARCH
        ));
    }
    let included = if selected.iter().any(|c| c == "recent_events") {
        &events[..events.len().min(MAX_EVENTS)]
    } else {
        &[]
    };
    out.push_str(&format!("events: {}\n\n", included.len()));
    for e in included {
        out.push_str(&format!(
            "{} {} {} {} {} {}\n",
            e.at,
            e.level.as_str().to_uppercase(),
            e.area,
            e.code,
            e.correlation_id,
            e.summary
        ));
    }
    (redact(&out), included.len() as u32)
}

pub async fn prepare(
    pool: &SqlitePool,
    request: DiagnosticPackRequest,
    version: &str,
) -> Result<DiagnosticPackPreview, KeelError> {
    let owner = access::require(pool, Permission::DiagnosticsExport).await?;
    let selected = categories(&request.categories)?;
    let events = if selected.iter().any(|c| c == "recent_events") {
        events::recent(MAX_EVENTS, Level::Info)
    } else {
        Vec::new()
    };
    let (content, event_count) = compose_selected(&events, version, &selected);
    let current = access::require(pool, Permission::DiagnosticsExport).await?;
    if current != owner {
        return Err(KeelError::PermissionDenied(
            "diagnostics.preview.owner".into(),
        ));
    }
    let preview_id = register_redacted_snapshot(&owner, &content)?;
    Ok(DiagnosticPackPreview {
        preview_id,
        content,
        categories: selected,
        event_count,
    })
}

/// 拼出诊断包文本。
pub fn compose(events: &[Event], version: &str) -> String {
    compose_selected(events, version, &["runtime".into(), "recent_events".into()]).0
}

/// 旧预览安全兼容：只含 runtime；新流程使用 prepare + export_prepared。
pub fn preview(version: &str) -> String {
    compose_selected(&[], version, &["runtime".into()]).0
}

/// 诊断包目录：数据库所在目录下的 `diagnostics`。
pub fn export_dir(db_path: &Path) -> PathBuf {
    db_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("diagnostics")
}

/// 授权成功后单次消费，即使文件/审计失败也不恢复句柄；调用方必须重新 prepare。
/// 权限/owner 拒绝不消费他人的快照；过期和容量淘汰同样需要重新 prepare。
pub async fn export_prepared(
    pool: &SqlitePool,
    db_path: &Path,
    preview_id: &str,
) -> Result<PathBuf, KeelError> {
    let owner = access::require(pool, Permission::DiagnosticsExport).await?;
    let pack = cache()
        .lock()
        .map_err(|_| KeelError::internal("diagnostic cache unavailable"))?
        .take(preview_id, &owner, Instant::now())?;
    write_and_audit(pool, db_path, &owner, &pack.content).await
}

/// create_new 原子创建，遇重名重试，不先 exists 再覆盖。
fn write_new(dir: &Path, content: &str, stamp: i64) -> Result<PathBuf, KeelError> {
    for suffix in 0..128 {
        let path = dir.join(format!("keel-diagnostics-{stamp}-{suffix}.txt"));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = match options.open(&path) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(KeelError::Io(e)),
        };
        if let Err(e) = file
            .write_all(content.as_bytes())
            .and_then(|()| file.sync_all())
        {
            drop(file);
            let _ = std::fs::remove_file(&path);
            return Err(KeelError::Io(e));
        }
        return Ok(path);
    }
    Err(KeelError::Io(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "diagnostic export name collision; prepare again",
    )))
}

async fn write_and_audit(
    pool: &SqlitePool,
    db_path: &Path,
    owner: &access::CurrentUser,
    content: &str,
) -> Result<PathBuf, KeelError> {
    if content.len() > MAX_CONTENT_BYTES {
        return Err(KeelError::Validation(
            "诊断快照超过 1 MiB，请减少采集类别".into(),
        ));
    }
    let dir = export_dir(db_path);
    std::fs::create_dir_all(&dir).map_err(KeelError::Io)?;
    let path = write_new(&dir, content, audit::now_ms().max(0))?;
    if let Err(e) = audit::record_as(
        pool,
        &owner.name,
        "diagnostics.export",
        "diagnostic pack",
        "ok",
    )
    .await
    {
        // 不留下一个对调用方报告失败的导出文件；清理失败也不恢复 token。
        let _ = std::fs::remove_file(&path);
        return Err(e);
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(summary: &str) -> Event {
        Event {
            at: 1,
            level: Level::Error,
            area: "api".into(),
            code: "KEEL-IO".into(),
            correlation_id: "K1-0001".into(),
            summary: summary.into(),
        }
    }

    #[test]
    fn report_has_header_and_event_lines() {
        let text = compose(&[event("disk full")], "0.1.0");
        assert!(text.starts_with("Keel diagnostic pack\n"));
        assert!(text.contains("version: 0.1.0"));
        assert!(text.contains("events: 1"));
        assert!(text.contains("ERROR api KEEL-IO K1-0001 disk full"));
    }

    #[test]
    fn report_is_redacted_again() {
        let text = compose(
            &[event("failed password=hunter2 at C:\\Users\\alice\\x")],
            "0.1.0",
        );
        assert!(!text.contains("hunter2"));
        assert!(!text.contains("alice"));
    }

    #[test]
    fn categories_are_required_whitelisted_and_canonical() {
        assert!(categories(&[]).is_err());
        for value in ["logs", "", "Runtime", "../config", "runtime "] {
            assert!(categories(&["runtime".into(), value.into()]).is_err());
        }
        assert_eq!(
            categories(&[
                "recent_events".into(),
                "runtime".into(),
                "recent_events".into()
            ])
            .unwrap(),
            vec!["runtime", "recent_events"]
        );
    }

    #[test]
    fn runtime_excludes_events_and_recent_events_is_opt_in_and_bounded() {
        let input = vec![event("private-marker"); MAX_EVENTS + 1];
        let (text, count) = compose_selected(&input, "test-version", &["runtime".into()]);
        assert_eq!(count, 0);
        assert!(text.contains("test-version"));
        assert!(!text.contains("private-marker"));
        let (text, count) = compose_selected(&input, "test-version", &["recent_events".into()]);
        assert_eq!(count as usize, MAX_EVENTS);
        assert_eq!(text.matches("private-marker").count(), MAX_EVENTS);
        assert!(!text.contains("test-version"));
        assert!(!text.contains("platform:"));
    }

    #[test]
    fn every_event_field_and_runtime_are_redacted() {
        let mut e = event("password=summary-secret");
        e.area = "token=area-secret".into();
        e.code = "password=code-secret".into();
        e.correlation_id = "token=correlation-secret".into();
        let text = compose(&[e], "password=version-secret");
        for secret in [
            "summary-secret",
            "area-secret",
            "code-secret",
            "correlation-secret",
            "version-secret",
        ] {
            assert!(!text.contains(secret));
        }
    }

    fn owner(name: &str, role: crate::domain::permissions::Role) -> access::CurrentUser {
        access::CurrentUser {
            name: name.into(),
            role,
        }
    }

    fn pack(id: &str, owner: &access::CurrentUser, now: Instant) -> PreparedPack {
        PreparedPack {
            id: id.into(),
            owner: owner.clone(),
            created: now,
            content: "redacted snapshot".into(),
        }
    }

    #[test]
    fn cache_binds_both_name_and_role_and_consumes_once() {
        use crate::domain::permissions::Role;
        let now = Instant::now();
        let me = owner("a", Role::Admin);
        let mut cache = PreviewCache::default();
        cache.insert(pack("id", &me, now), now);
        for other in [owner("b", Role::Admin), owner("a", Role::Operator)] {
            assert!(matches!(
                cache.take("id", &other, now),
                Err(KeelError::PermissionDenied(_))
            ));
            assert_eq!(cache.items.len(), 1);
        }
        assert_eq!(
            cache.take("id", &me, now).unwrap().content,
            "redacted snapshot"
        );
        assert!(cache.take("id", &me, now).is_err());
        assert!(cache.items.is_empty());
    }

    #[test]
    fn cache_expires_at_ttl_and_evicts_oldest_without_sleep() {
        use crate::domain::permissions::Role;
        let now = Instant::now();
        let me = owner("a", Role::Admin);
        let mut cache = PreviewCache::default();
        cache.insert(pack("live", &me, now), now);
        assert!(cache
            .take("live", &me, now + CACHE_TTL - Duration::from_nanos(1))
            .is_ok());
        cache.insert(pack("expired", &me, now), now);
        assert!(cache.take("expired", &me, now + CACHE_TTL).is_err());
        assert!(cache.items.is_empty());
        for i in 0..=CACHE_CAPACITY {
            cache.insert(pack(&i.to_string(), &me, now), now);
            assert!(cache.items.len() <= CACHE_CAPACITY);
        }
        assert!(cache.take("0", &me, now).is_err());
        assert!(cache.take("1", &me, now).is_ok());
        // insert 也会清理过期项，容量可立即复用。
        let later = now + CACHE_TTL;
        cache.insert(pack("new", &me, later), later);
        assert_eq!(cache.items.len(), 1);
        assert!(cache.take("new", &me, later).is_ok());
    }

    #[test]
    fn create_new_preserves_collision_and_writes_exact_bytes() {
        let dir = std::env::temp_dir().join(format!(
            "keel-diagnostic-write-{}-{}",
            std::process::id(),
            new_correlation_id()
        ));
        std::fs::create_dir(&dir).unwrap();
        let first = write_new(&dir, "existing", 42).unwrap();
        let second = write_new(&dir, "snapshot\n中文\n", 42).unwrap();
        assert_ne!(first, second);
        assert_eq!(std::fs::read(&first).unwrap(), b"existing");
        assert_eq!(
            std::fs::read(&second).unwrap(),
            "snapshot\n中文\n".as_bytes()
        );
        // 重名重试有上限；失败也不能覆盖既有文件。
        for _ in 2..128 {
            write_new(&dir, "existing", 42).unwrap();
        }
        assert!(write_new(&dir, "replacement", 42).is_err());
        assert_eq!(std::fs::read(&first).unwrap(), b"existing");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
