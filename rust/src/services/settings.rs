//! 配置变更/导入审计的持久队列：preferences + pending 在同一 JSON 原子提交，
//! DB 成功后才清队列；提交后崩溃或清理失败可按事件 ID 幂等重放。
//!
//! 仅支持 single process 应用写者：save/flush 共用进程内锁，不提供跨多进程
//! 配置文件并发控制；本地 JSON 与 SQLite 审计均不承诺本机防篡改。

use crate::config::{
    self, AppConfig, PendingSettingsAudit, PendingSettingsImportAudit, WorkspaceNavigation,
    MAX_PENDING_SETTINGS_AUDIT,
};
use crate::diagnostics::import_screen;
use crate::diagnostics::{
    correlation::new_correlation_id,
    events::{self, Level},
};
use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::{access, audit};
use crate::{data, state};
use sqlx::SqlitePool;
use std::collections::hash_map::RandomState;
use std::collections::VecDeque;
use std::hash::BuildHasher;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

static SETTINGS_LOCK: Mutex<()> = Mutex::const_new(());
static EVENT_SEQUENCE: AtomicU64 = AtomicU64::new(0);
const IMPORT_CACHE_CAPACITY: usize = 6;
const IMPORT_CACHE_TTL: Duration = Duration::from_secs(300);

struct PreparedExternalConfig {
    id: String,
    owner: access::CurrentUser,
    created: Instant,
    input: Vec<u8>,
    screened: import_screen::ScreenedInput,
}

#[derive(Default)]
struct ImportCache {
    items: VecDeque<PreparedExternalConfig>,
}

impl ImportCache {
    fn insert(&mut self, item: PreparedExternalConfig, now: Instant) {
        self.prune(now);
        if self.items.len() >= IMPORT_CACHE_CAPACITY {
            self.items.pop_front();
        }
        self.items.push_back(item);
    }

    fn prune(&mut self, now: Instant) {
        self.items
            .retain(|item| now.saturating_duration_since(item.created) < IMPORT_CACHE_TTL);
    }

    fn take(
        &mut self,
        id: &str,
        owner: &access::CurrentUser,
        now: Instant,
    ) -> Result<PreparedExternalConfig, KeelError> {
        self.prune(now);
        let index = self
            .items
            .iter()
            .position(|item| item.id == id)
            .ok_or_else(|| KeelError::Import("外部配置预览已过期或不存在".into()))?;
        if self.items[index].owner != *owner {
            return Err(KeelError::PermissionDenied(
                "外部配置预览属于其他用户".into(),
            ));
        }
        self.items
            .remove(index)
            .ok_or_else(|| KeelError::internal("外部配置预览缓存状态异常"))
    }
}

fn import_cache() -> &'static StdMutex<ImportCache> {
    static CACHE: OnceLock<StdMutex<ImportCache>> = OnceLock::new();
    CACHE.get_or_init(|| StdMutex::new(ImportCache::default()))
}

fn require_settings_import() -> Result<access::CurrentUser, KeelError> {
    let owner = access::current()?;
    if !owner.role.allows(Permission::SettingsImport) {
        return Err(KeelError::PermissionDenied(
            Permission::SettingsImport.as_str().to_string(),
        ));
    }
    Ok(owner)
}

fn event_id() -> String {
    let correlation_id = new_correlation_id();
    let seq = EVENT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    // 两个独立随机种子的 64 位 hash 加关联 ID，不只依赖时间戳/16 位序号。
    // RandomState 是标准库随机化来源；此 ID 用于防碰撞，不作为权限凭据。
    let high = RandomState::new().hash_one((&correlation_id, seq, 0u8));
    let low = RandomState::new().hash_one((&correlation_id, seq, 1u8));
    format!("S{high:016x}{low:016x}-{correlation_id}")
}

fn import_preview_id() -> String {
    let correlation_id = new_correlation_id();
    let sequence = EVENT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let value = RandomState::new().hash_one((&correlation_id, sequence));
    format!("I{value:016x}-{correlation_id}")
}

/// 只记固定摘要/错误码和新诊断 ID；禁止附带 actor、配置内容、路径或底层错误。
pub(crate) fn warn_pending(error: &KeelError) {
    let correlation_id = new_correlation_id();
    let summary = "Settings audit replay deferred; pending events retained.";
    tracing::warn!(code = error.code(), correlation_id = %correlation_id, "{summary}");
    events::record(
        Level::Warn,
        "settings",
        error.code(),
        &correlation_id,
        summary,
    );
}

pub async fn save(
    language: Option<String>,
    theme: Option<String>,
    format_locale: Option<String>,
) -> Result<(), KeelError> {
    // 在解析路径/读取原配置之前先校验请求。
    let request = AppConfig {
        language,
        theme,
        format_locale,
        ..AppConfig::default()
    };
    request.validate()?;
    save_at(
        &config::config_path()?,
        request.language,
        request.theme,
        request.format_locale,
        None,
    )
    .await
}

pub fn load_navigation() -> Result<WorkspaceNavigation, KeelError> {
    load_navigation_at(&config::config_path()?)
}

/// 原子替换配置保证同步读取只会看到一次完整保存。
pub fn load_navigation_at(path: &Path) -> Result<WorkspaceNavigation, KeelError> {
    Ok(config::load(path)?.workspace_navigation)
}

pub async fn save_navigation(preferences: WorkspaceNavigation) -> Result<(), KeelError> {
    preferences.validate()?;
    save_navigation_at(&config::config_path()?, preferences).await
}

/// 与语言/主题/显示区域保存、审计补写共用锁；仅修改导航，不新增或清理审计事件。
/// 显式路径用于隔离测试，不向跨语言调用者开放路径。
pub async fn save_navigation_at(
    path: &Path,
    preferences: WorkspaceNavigation,
) -> Result<(), KeelError> {
    preferences.validate()?;
    let _guard = SETTINGS_LOCK.lock().await;
    let mut config = config::load(path)?;
    if config.workspace_navigation == preferences {
        return Ok(());
    }
    config.workspace_navigation = preferences;
    config::save(path, &config)
}

/// 显式路径/可选池便于隔离服务测试；不是跨语言路径入口。
/// 返回 Ok 表示偏好已保存（或没有变化）；审计补写失败不撤销或误报设置保存。
pub async fn save_at(
    path: &Path,
    language: Option<String>,
    theme: Option<String>,
    format_locale: Option<String>,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    let request = AppConfig {
        language,
        theme,
        format_locale,
        ..AppConfig::default()
    };
    save_preferences_at(path, Some(request), None, pool).await
}

pub async fn save_regional(preferences: config::RegionalPreferences) -> Result<(), KeelError> {
    preferences.validate()?;
    save_regional_at(&config::config_path()?, preferences, None).await
}

pub async fn save_regional_at(
    path: &Path,
    preferences: config::RegionalPreferences,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    preferences.validate()?;
    save_preferences_at(path, None, Some(preferences), pool).await
}

async fn save_preferences_at(
    path: &Path,
    legacy: Option<AppConfig>,
    regional: Option<config::RegionalPreferences>,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    if let Some(request) = &legacy {
        request.validate()?;
    }
    let _guard = SETTINGS_LOCK.lock().await;
    let mut config = config::load(path)?;
    let mut request = config.clone();
    if let Some(legacy) = legacy {
        request.language = legacy.language;
        request.theme = legacy.theme;
        request.format_locale = legacy.format_locale;
    }
    if let Some(regional) = regional {
        request.time_zone = regional.time_zone;
        request.currency = regional.currency;
    }
    request.validate()?;
    let actor = access::current_name();
    let mut changed_fields = Vec::new();
    if config.language != request.language {
        changed_fields.push("language".to_string());
    }
    if config.theme != request.theme {
        changed_fields.push("theme".to_string());
    }
    if config.format_locale != request.format_locale {
        changed_fields.push("format_locale".to_string());
    }
    if config.time_zone != request.time_zone {
        changed_fields.push("time_zone".to_string());
    }
    if config.currency != request.currency {
        changed_fields.push("currency".to_string());
    }
    let available_pool = pool.or_else(|| state::pool().ok());
    // 满队列且数据库已恢复时先尝试排空，避免每次保存都在补写前被拒绝。
    if !changed_fields.is_empty() && config.pending_audit_len() >= MAX_PENDING_SETTINGS_AUDIT {
        if let Some(pool) = available_pool {
            if let Err(error) = flush_locked(path, pool, &mut config).await {
                warn_pending(&error);
            }
        }
    }
    if !changed_fields.is_empty() {
        // 满队列拒绝新持久变更，原配置/队列均不动；可单独 flush 或无变化保存来排空。
        if config.pending_audit_len() >= MAX_PENDING_SETTINGS_AUDIT {
            return Err(KeelError::Validation(
                "配置待写审计队列已满，请先重试审计补写".into(),
            ));
        }
        config.pending_settings_audit.push(PendingSettingsAudit {
            id: event_id(),
            at: audit::now_ms(),
            actor,
            changed_fields,
        });
        config.language = request.language;
        config.theme = request.theme;
        config.format_locale = request.format_locale;
        config.time_zone = request.time_zone;
        config.currency = request.currency;
        config::save(path, &config)?;
    }
    // 偏好与事件已一同落盘，此后所有失败只告警；无变化也可重试既有队列。
    if let Some(pool) = available_pool {
        if let Err(error) = flush_locked(path, pool, &mut config).await {
            warn_pending(&error);
        }
    }
    Ok(())
}

/// 在设置锁内重新筛查并合并外部配置。外部 pending 审计队列永不覆盖本机队列。
/// 该核心入口不接受源路径，调用方应先由系统文件选择器读取受限字节。
pub async fn import_external_config_at(path: &Path, input: &[u8]) -> Result<(), KeelError> {
    import_external_config_at_with_pool(path, input, state::pool().ok()).await
}

/// 显式注入池供独立服务测试使用；None 表示没有池，不回退到全局池。
pub async fn import_external_config_at_with_pool(
    path: &Path,
    input: &[u8],
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    import_with_audit(path, ImportSource::Bytes(input), pool).await
}

/// 文件选择器接入前的 Rust 文件层入口；源路径不应直接暴露给跨语言 API。
pub async fn import_external_config_file_at(path: &Path, source: &Path) -> Result<(), KeelError> {
    import_external_config_file_at_with_pool(path, source, state::pool().ok()).await
}

pub async fn import_external_config_file_at_with_pool(
    path: &Path,
    source: &Path,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    import_with_audit(path, ImportSource::File(source), pool).await
}

pub fn prepare_external_config(
    input: Vec<u8>,
) -> Result<(String, import_screen::ScreenedInput), KeelError> {
    let owner = require_settings_import()?;
    let screened = import_screen::screen_bytes(&input)?;
    if !screened.config_importable {
        return Err(KeelError::Import("外部内容不能作为配置导入".into()));
    }
    let item = PreparedExternalConfig {
        id: import_preview_id(),
        owner,
        created: Instant::now(),
        input,
        screened: screened.clone(),
    };
    let cache = import_cache();
    let mut cache = cache
        .lock()
        .map_err(|_| KeelError::internal("外部配置预览缓存不可用"))?;
    cache.insert(item, Instant::now());
    let id = cache
        .items
        .back()
        .map(|item| item.id.clone())
        .ok_or_else(|| KeelError::internal("外部配置预览缓存状态异常"))?;
    Ok((id, screened))
}

/// 文件选择只准备一次内容；读取前检查权限，读取后比较完整身份，
/// 再复用文本入口的校验、owner 快照和有界一次性缓存，不缓存路径。
pub fn prepare_external_config_file(
    path: &Path,
) -> Result<(String, import_screen::ScreenedInput), KeelError> {
    let owner = require_settings_import()?;
    let input = import_screen::read_file(path)?;
    if require_settings_import()? != owner {
        return Err(KeelError::PermissionDenied("配置准备期间用户已变化".into()));
    }
    import_screen::parse_importable_config(&input)?;
    let (id, screened) = prepare_external_config(input)?;
    // prepare 本身再次捕获 owner；覆盖两次身份检查之间的切换窗口。
    let mut cache = import_cache()
        .lock()
        .map_err(|_| KeelError::internal("外部配置预览缓存不可用"))?;
    let valid = require_settings_import().is_ok_and(|current| current == owner)
        && cache
            .items
            .iter()
            .any(|item| item.id == id && item.owner == owner);
    if !valid {
        cache.items.retain(|item| item.id != id);
        return Err(KeelError::PermissionDenied("配置准备期间用户已变化".into()));
    }
    Ok((id, screened))
}

pub async fn import_prepared_external_config_at(
    path: &Path,
    preview_id: &str,
) -> Result<(), KeelError> {
    import_prepared_external_config_at_with_pool(path, preview_id, state::pool().ok()).await
}

pub async fn import_prepared_external_config_at_with_pool(
    path: &Path,
    preview_id: &str,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    import_with_audit(path, ImportSource::Prepared(preview_id), pool).await
}

enum ImportSource<'a> {
    Bytes(&'a [u8]),
    File(&'a Path),
    Prepared(&'a str),
}

/// 成功结果与偏好同次原子保存；失败仅在本机配置健康且有容量时持久记录。
/// 不承诺跨 SQLite/config 事务，或在磁盘故障、坏配置、满队列时记录所有失败。
async fn import_with_audit(
    path: &Path,
    source: ImportSource<'_>,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    let owner = access::current();
    let actor = owner
        .as_ref()
        .map(|user| user.name.clone())
        .unwrap_or_else(|_| access::DEFAULT_USER.to_string());
    let mut event = PendingSettingsImportAudit {
        id: event_id(),
        at: audit::now_ms(),
        actor,
        result: "ok".into(),
    };
    let _guard = SETTINGS_LOCK.lock().await;
    let outcome = async {
        let owner = owner?;
        // 等待期间可能切换用户或角色，比较完整身份，不能仅复查权限。
        if require_settings_import()? != owner {
            return Err(KeelError::PermissionDenied("配置导入期间用户已变化".into()));
        }
        match source {
            ImportSource::Bytes(input) => {
                import_external_config_locked(path, input, &event, &owner, pool).await
            }
            ImportSource::File(source) => {
                // 权限与锁后身份复查均在文件读取之前。
                let input = import_screen::read_file(source)?;
                import_external_config_locked(path, &input, &event, &owner, pool).await
            }
            ImportSource::Prepared(id) => {
                let prepared = import_cache()
                    .lock()
                    .map_err(|_| KeelError::internal("外部配置预览缓存不可用"))?
                    .take(id, &owner, Instant::now())?;
                if !prepared.screened.config_importable {
                    return Err(KeelError::Import("外部配置预览不可导入".into()));
                }
                import_external_config_locked(path, &prepared.input, &event, &owner, pool).await
            }
        }
    }
    .await;
    if let Err(error) = &outcome {
        event.result = format!("failed:{}", error.code());
        // 从磁盘重新读取：不能把失败尝试已合并的内存偏好写入正式配置。
        if let Err(record_error) = persist_import_failure_locked(path, event, pool).await {
            let correlation_id = new_correlation_id();
            let summary =
                "Settings import outcome not persisted; replay unavailable for this attempt.";
            tracing::warn!(code = record_error.code(), correlation_id = %correlation_id, "{summary}");
            events::record(
                Level::Warn,
                "settings",
                record_error.code(),
                &correlation_id,
                summary,
            );
        }
    }
    outcome
}

async fn ensure_audit_capacity_locked(
    path: &Path,
    current: &mut AppConfig,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    if current.pending_audit_len() >= MAX_PENDING_SETTINGS_AUDIT {
        if let Some(pool) = pool {
            if let Err(error) = flush_locked(path, pool, current).await {
                warn_pending(&error);
            }
        }
    }
    if current.pending_audit_len() >= MAX_PENDING_SETTINGS_AUDIT {
        return Err(KeelError::Import(
            "配置待写审计队列已满，请先重试审计补写".into(),
        ));
    }
    Ok(())
}

async fn persist_import_failure_locked(
    path: &Path,
    event: PendingSettingsImportAudit,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    let mut current = config::load(path)?;
    ensure_audit_capacity_locked(path, &mut current, pool).await?;
    current.pending_settings_import_audit.push(event);
    config::save(path, &current)?;
    if let Some(pool) = pool {
        if let Err(error) = flush_locked(path, pool, &mut current).await {
            warn_pending(&error);
        }
    }
    Ok(())
}

async fn import_external_config_locked(
    path: &Path,
    input: &[u8],
    event: &PendingSettingsImportAudit,
    owner: &access::CurrentUser,
    pool: Option<&SqlitePool>,
) -> Result<(), KeelError> {
    let imported = import_screen::parse_importable_config(input)?;
    let mut current = config::load(path)?;
    ensure_audit_capacity_locked(path, &mut current, pool).await?;
    // 上面的 flush 可能等待 SQLite；写入前再次复查调用时的完整身份。
    if require_settings_import()? != *owner {
        return Err(KeelError::PermissionDenied("配置导入期间用户已变化".into()));
    }
    current.language = imported.language;
    current.theme = imported.theme;
    current.format_locale = imported.format_locale;
    current.time_zone = imported.time_zone;
    current.currency = imported.currency;
    current.workspace_navigation = imported.workspace_navigation;
    current.version = config::CURRENT_VERSION;
    current.pending_settings_import_audit.push(event.clone());
    current
        .validate()
        .map_err(|_| KeelError::Import("合并后的配置校验失败".into()))?;
    config::save(path, &current).map_err(|_| KeelError::Import("外部配置写入失败".into()))?;
    if let Some(pool) = pool {
        if let Err(error) = flush_locked(path, pool, &mut current).await {
            warn_pending(&error);
        }
    }
    Ok(())
}

/// 启动发布全局 pool 后使用传入的池补写；与 save 共享锁。
/// 返回错误时 pending 仍在磁盘，调用方可告警并继续启动。
pub async fn flush_pending(pool: &SqlitePool) -> Result<(), KeelError> {
    flush_pending_at(&config::config_path()?, pool).await
}

pub async fn flush_pending_at(path: &Path, pool: &SqlitePool) -> Result<(), KeelError> {
    let _guard = SETTINGS_LOCK.lock().await;
    let mut config = config::load(path)?;
    flush_locked(path, pool, &mut config).await
}

/// 仅在持有 SETTINGS_LOCK 时调用，避免再次获取同一把锁。
async fn flush_locked(
    path: &Path,
    pool: &SqlitePool,
    config: &mut AppConfig,
) -> Result<(), KeelError> {
    if config.pending_audit_len() == 0 {
        return Ok(());
    }
    for event in &config.pending_settings_audit {
        event.validate()?;
        // validate 已保证只含白名单字段且无重复；固定顺序兼容旧审计摘要。
        let fields: Vec<_> = config::SETTINGS_FIELDS
            .iter()
            .copied()
            .filter(|field| {
                event
                    .changed_fields
                    .iter()
                    .any(|changed| changed.as_str() == *field)
            })
            .collect();
        let result = format!("changed: {}", fields.join(","));
        data::audit::insert_settings_change(pool, event.at, &event.actor, &result, &event.id)
            .await?;
    }
    for event in &config.pending_settings_import_audit {
        event.validate()?;
        data::audit::insert_settings_import(pool, event.at, &event.actor, &event.result, &event.id)
            .await?;
    }
    // 部分插入失败/任务取消时不改磁盘队列；下次单条 SQL 去重。
    // 清理保存失败也保留磁盘原队列，已落库事件可安全重放。
    let mut cleared = config.clone();
    cleared.pending_settings_audit.clear();
    cleared.pending_settings_import_audit.clear();
    config::save(path, &cleared)?;
    *config = cleared;
    Ok(())
}

#[cfg(test)]
mod import_cache_tests {
    use super::*;
    use crate::domain::permissions::Role;

    #[tokio::test]
    async fn import_replay_retains_disk_outbox_when_cleanup_save_fails() {
        let _guard = SETTINGS_LOCK.lock().await;
        let dir = std::env::temp_dir().join(format!("keel-import-cleanup-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.json");
        let parked = dir.join("parked.json");
        let event = PendingSettingsImportAudit {
            id: event_id(),
            at: 123,
            actor: "original-owner".into(),
            result: "failed:KEEL-IMPORT".into(),
        };
        let mut config = AppConfig {
            language: Some("en".into()),
            pending_settings_import_audit: vec![event.clone()],
            ..AppConfig::default()
        };
        config::save(&path, &config).unwrap();
        let snapshot = std::fs::read(&path).unwrap();
        let pool = data::open(&dir.join("audit.db")).await.unwrap();
        // 在 load 与 cleanup-save 间把目标换成目录，真实触发文件系统错误，
        // 不依赖 chmod（root 可能绕过）、定时器或生产故障注入开关。
        std::fs::rename(&path, &parked).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(flush_locked(&path, &pool, &mut config).await.is_err());
        assert_eq!(
            config.pending_settings_import_audit,
            std::slice::from_ref(&event)
        );
        assert_eq!(std::fs::read(&parked).unwrap(), snapshot);
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_log WHERE action = 'settings.import' AND correlation_id = ?1",
        ).bind(&event.id).fetch_one(&pool).await.unwrap();
        assert_eq!(count, 1, "DB 已提交，配置清理实际失败");
        std::fs::remove_dir(&path).unwrap();
        std::fs::rename(&parked, &path).unwrap();
        let mut reloaded = config::load(&path).unwrap();
        flush_locked(&path, &pool, &mut reloaded).await.unwrap();
        let row: data::audit::AuditRow = sqlx::query_as(
            "SELECT id, at, actor, action, target, result, correlation_id FROM audit_log \
             WHERE action = 'settings.import' AND correlation_id = ?1",
        )
        .bind(&event.id)
        .fetch_one(&pool)
        .await
        .unwrap();
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 1);
        assert_eq!(row.at, event.at);
        assert_eq!(row.actor, event.actor);
        assert_eq!(row.result, event.result);
        assert_eq!(config::load(&path).unwrap().pending_audit_len(), 0);
        pool.close().await;
        for _ in 0..40 {
            match std::fs::remove_dir_all(&dir) {
                Ok(()) => break,
                Err(error) if error.raw_os_error() == Some(32) => {
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(error) => panic!("remove test dir failed: {error}"),
            }
        }
    }

    fn owner(name: &str, role: Role) -> access::CurrentUser {
        access::CurrentUser {
            name: name.into(),
            role,
        }
    }

    fn item(id: &str, created: Instant) -> PreparedExternalConfig {
        let input = br#"{"version":3,"language":"en"}"#.to_vec();
        PreparedExternalConfig {
            id: id.into(),
            owner: owner("admin", Role::Admin),
            created,
            screened: import_screen::screen_bytes(&input).unwrap(),
            input,
        }
    }

    #[test]
    fn expires_at_exact_ttl_without_sleeping() {
        let now = Instant::now();
        let admin = owner("admin", Role::Admin);
        let mut cache = ImportCache::default();
        cache.insert(item("before", now), now);
        assert!(cache
            .take(
                "before",
                &admin,
                now + IMPORT_CACHE_TTL - Duration::from_nanos(1)
            )
            .is_ok());
        cache.insert(item("expired", now), now);
        let error = cache
            .take("expired", &admin, now + IMPORT_CACHE_TTL)
            .err()
            .unwrap();
        assert_eq!(error.code(), "KEEL-IMPORT");
        assert!(cache.items.is_empty());
    }

    #[test]
    fn capacity_evicts_oldest_and_prunes_expired_before_insert() {
        let now = Instant::now();
        let admin = owner("admin", Role::Admin);
        let mut cache = ImportCache::default();
        for index in 0..=IMPORT_CACHE_CAPACITY {
            cache.insert(item(&index.to_string(), now), now);
        }
        assert_eq!(cache.items.len(), IMPORT_CACHE_CAPACITY);
        assert_eq!(
            cache.take("0", &admin, now).err().unwrap().code(),
            "KEEL-IMPORT"
        );
        assert!(cache.take("1", &admin, now).is_ok());
        let later = now + IMPORT_CACHE_TTL;
        cache.insert(item("fresh", later), later);
        assert_eq!(cache.items.len(), 1);
        assert!(cache.take("fresh", &admin, later).is_ok());
    }

    #[test]
    fn full_identity_required_and_success_consumes_snapshot_once() {
        let now = Instant::now();
        let mut cache = ImportCache::default();
        cache.insert(item("snapshot", now), now);
        for other in [owner("other", Role::Admin), owner("admin", Role::Operator)] {
            assert_eq!(
                cache.take("snapshot", &other, now).err().unwrap().code(),
                "KEEL-PERMISSION"
            );
            assert_eq!(cache.items.len(), 1);
        }
        let admin = owner("admin", Role::Admin);
        let snapshot = cache.take("snapshot", &admin, now).unwrap();
        assert_eq!(snapshot.input, br#"{"version":3,"language":"en"}"#);
        assert_eq!(
            cache.take("snapshot", &admin, now).err().unwrap().code(),
            "KEEL-IMPORT"
        );
    }
}
