//! 真 SQLite + 真实配置文件。所有 CURRENT 操作在一个顺序测试中完成；
//! 不发布全局 pool，不依赖用户表或 settings 之外的权限。

use rust_lib_keel::config::{
    self, PendingSettingsAudit, WorkspaceNavigation, MAX_PENDING_SETTINGS_AUDIT,
};
use rust_lib_keel::data::{self, audit::AuditRow};
use rust_lib_keel::diagnostics::events::{self, Level};
use rust_lib_keel::domain::permissions::Role;
use rust_lib_keel::services::{access, audit, settings};
use std::collections::HashSet;
use std::io::Write;
use std::path::Path;
use std::sync::{Arc, Mutex};

fn identity(name: &str, role: Role) {
    access::set_current(access::CurrentUser {
        name: name.into(),
        role,
    });
}

async fn save(
    path: &Path,
    language: Option<&str>,
    theme: Option<&str>,
    pool: Option<&sqlx::SqlitePool>,
) {
    settings::save_at(
        path,
        language.map(str::to_owned),
        theme.map(str::to_owned),
        None,
        pool,
    )
    .await
    .unwrap();
}

async fn rows(pool: &sqlx::SqlitePool) -> Vec<AuditRow> {
    sqlx::query_as(
        "SELECT id, at, actor, action, target, result, correlation_id \
         FROM audit_log WHERE action = 'settings.change' ORDER BY id",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

fn assert_event(row: &AuditRow, event: &PendingSettingsAudit, result: &str) {
    assert_eq!(row.at, event.at);
    assert_eq!(row.actor, event.actor);
    assert_eq!(row.correlation_id, event.id);
    assert_eq!(row.action, "settings.change");
    assert_eq!(row.target, "application");
    assert_eq!(row.result, result);
}

#[derive(Clone)]
struct LogBytes(Arc<Mutex<Vec<u8>>>);

impl Write for LogBytes {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[tokio::test]
async fn settings_audit_persistence_recovery_capacity_and_concurrency() {
    let dir = std::env::temp_dir().join(format!("keel-settings-audit-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let pool = data::open(&dir.join("audit.db")).await.unwrap();
    assert!(data::user::list(&pool).await.unwrap().is_empty());

    // 离线保存：同一个已提交文件同时含偏好和仅有字段名的事件。
    let path = dir.join("offline.json");
    identity("原操作者", Role::Viewer);
    let before_time = audit::now_ms();
    save(&path, Some("en"), Some("dark"), None).await;
    let after_time = audit::now_ms();
    let bytes = std::fs::read(&path).unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(json["language"], "en");
    assert_eq!(json["theme"], "dark");
    let pending_json = json["pending_settings_audit"].as_array().unwrap();
    assert_eq!(pending_json.len(), 1);
    let event_json = pending_json[0].as_object().unwrap();
    assert_eq!(
        event_json
            .keys()
            .map(String::as_str)
            .collect::<HashSet<_>>(),
        HashSet::from(["id", "at", "actor", "changed_fields"])
    );
    assert_eq!(
        event_json["changed_fields"],
        serde_json::json!(["language", "theme"])
    );
    let first = config::load(&path)
        .unwrap()
        .pending_settings_audit
        .remove(0);
    assert!((before_time..=after_time).contains(&first.at));
    assert_eq!(first.actor, "原操作者");
    assert!(rows(&pool).await.is_empty());
    save(&path, Some("en"), Some("dark"), None).await;
    assert_eq!(std::fs::read(&path).unwrap(), bytes, "无变化不追加、不重写");

    // 同名切换角色、再切换身份：离线事件仍属于原操作者与原时间。
    identity("原操作者", Role::Operator);
    save(&path, Some("zh"), Some("dark"), None).await;
    let second = config::load(&path).unwrap().pending_settings_audit[1].clone();
    assert_eq!(second.changed_fields, ["language"]);
    identity("重放操作者", Role::Viewer);
    settings::flush_pending_at(&path, &pool).await.unwrap();
    let replayed = rows(&pool).await;
    assert_eq!(replayed.len(), 2);
    assert_event(&replayed[0], &first, "changed: language,theme");
    assert_event(&replayed[1], &second, "changed: language");
    assert!(config::load(&path)
        .unwrap()
        .pending_settings_audit
        .is_empty());

    // 在线立即入库并清队列；viewer 无需管理权限或真实用户记录。
    save(&path, Some("zh"), Some("light"), Some(&pool)).await;
    let online = rows(&pool).await;
    assert_eq!(online.len(), 3);
    assert_eq!(online[2].actor, "重放操作者");
    assert_eq!(online[2].result, "changed: theme");
    assert!(config::load(&path)
        .unwrap()
        .pending_settings_audit
        .is_empty());
    save(&path, Some("zh"), Some("light"), Some(&pool)).await;
    assert_eq!(rows(&pool).await.len(), 3);

    // SQLite trigger 的私有错误只导致补写延后；save 仍成功且日志不泄漏。
    sqlx::query(
        "CREATE TRIGGER reject_settings BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.change' BEGIN \
         SELECT RAISE(FAIL, 'PRIVATE_DB_DETAIL /private/customer/account.db'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    let log = LogBytes(Arc::new(Mutex::new(Vec::new())));
    let writer = log.clone();
    let subscriber = tracing_subscriber::fmt()
        .with_ansi(false)
        .without_time()
        .with_writer(move || writer.clone())
        .finish();
    // 本测试使用 current-thread runtime，guard 跨 await 保持当前线程日志捕获。
    let guard = tracing::subscriber::set_default(subscriber);
    save(&path, Some("en"), Some("light"), Some(&pool)).await;
    drop(guard);
    let failed_config = config::load(&path).unwrap();
    assert_eq!(failed_config.language.as_deref(), Some("en"));
    assert_eq!(failed_config.pending_settings_audit.len(), 1);
    assert_eq!(rows(&pool).await.len(), 3);
    let warnings = events::recent(10, Level::Warn);
    let warning = warnings
        .iter()
        .find(|event| event.area == "settings")
        .unwrap();
    assert_eq!(warning.level, Level::Warn);
    assert_eq!(warning.code, "KEEL-DB");
    assert!(!warning.correlation_id.is_empty());
    let trace = String::from_utf8(log.0.lock().unwrap().clone()).unwrap();
    assert!(trace.contains("WARN"));
    assert!(trace.contains("KEEL-DB"));
    for text in [&trace, &warning.summary] {
        for private in [
            "PRIVATE_DB_DETAIL",
            "/private/customer",
            "重放操作者",
            "light",
        ] {
            assert!(!text.contains(private), "{text}");
        }
        assert!(!text.contains(path.to_str().unwrap()));
    }
    sqlx::query("DROP TRIGGER reject_settings")
        .execute(&pool)
        .await
        .unwrap();
    // 相同偏好保存也能重试既有 pending，且不制造新事件。
    save(&path, Some("en"), Some("light"), Some(&pool)).await;
    let retried = rows(&pool).await;
    assert_eq!(retried.len(), 4);
    assert_event(
        &retried[3],
        &failed_config.pending_settings_audit[0],
        "changed: language",
    );

    // 部分已入库：用独立 SQL 模拟首次补写在首条之后中断。
    let partial = dir.join("partial.json");
    save(&partial, Some("en"), None, None).await;
    save(&partial, Some("en"), Some("dark"), None).await;
    let snapshot = std::fs::read(&partial).unwrap();
    let pending = config::load(&partial).unwrap().pending_settings_audit;
    sqlx::query(
        "INSERT INTO audit_log (at, actor, action, target, result, correlation_id) \
         VALUES (?1, ?2, 'settings.change', 'application', 'changed: language', ?3)",
    )
    .bind(pending[0].at)
    .bind(&pending[0].actor)
    .bind(&pending[0].id)
    .execute(&pool)
    .await
    .unwrap();
    let count = rows(&pool).await.len();
    // 第二条确实写失败时，完整磁盘队列仍应保留，首条不重复写入。
    sqlx::query(
        "CREATE TRIGGER reject_second_settings BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.change' AND NEW.result = 'changed: theme' \
         BEGIN SELECT RAISE(FAIL, 'second event rejected'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    assert_eq!(
        settings::flush_pending_at(&partial, &pool)
            .await
            .unwrap_err()
            .code(),
        "KEEL-DB"
    );
    assert_eq!(rows(&pool).await.len(), count);
    assert_eq!(std::fs::read(&partial).unwrap(), snapshot);
    sqlx::query("DROP TRIGGER reject_second_settings")
        .execute(&pool)
        .await
        .unwrap();
    settings::flush_pending_at(&partial, &pool).await.unwrap();
    assert_eq!(rows(&pool).await.len(), count + 1);
    assert!(config::load(&partial)
        .unwrap()
        .pending_settings_audit
        .is_empty());

    // 模拟 DB 全部提交但磁盘清队列失败/崩溃后的状态。
    // SQLite trigger 无法注入文件系统失败，因此恢复先前已提交的磁盘快照；
    // 此处只验证该故障状态的恢复契约，不声称实际触发了磁盘 I/O 错误。
    std::fs::write(&partial, &snapshot).unwrap();
    identity("后来用户", Role::Admin);
    settings::flush_pending_at(&partial, &pool).await.unwrap();
    settings::flush_pending_at(&partial, &pool).await.unwrap();
    let replayed = rows(&pool).await;
    assert_eq!(replayed.len(), count + 1);
    for (event, result) in pending.iter().zip(["changed: language", "changed: theme"]) {
        let matches: Vec<_> = replayed
            .iter()
            .filter(|row| row.correlation_id == event.id)
            .collect();
        assert_eq!(matches.len(), 1);
        assert_event(matches[0], event, result);
    }
    assert!(config::load(&partial)
        .unwrap()
        .pending_settings_audit
        .is_empty());

    concurrent_save_and_flush(&dir, &pool).await;
    full_queue(&dir, &pool).await;
    navigation_preserves_settings_and_audit(&dir, &pool).await;
    format_locale_audit(&dir, &pool).await;
    pool.close().await;
    remove_test_dir(&dir);
}

async fn navigation_preserves_settings_and_audit(dir: &Path, pool: &sqlx::SqlitePool) {
    let path = dir.join("navigation.json");
    let count = rows(pool).await.len();
    save(&path, Some("en"), Some("dark"), None).await;
    let before = config::load(&path).unwrap();
    let navigation = WorkspaceNavigation {
        recent_kinds: vec!["users".into(), "audit".into()],
        favorite_kinds: vec!["audit".into(), "backup".into()],
        nav_collapsed: true,
    };
    settings::save_navigation_at(&path, navigation.clone())
        .await
        .unwrap();
    let after = config::load(&path).unwrap();
    assert_eq!(after.language, before.language);
    assert_eq!(after.theme, before.theme);
    assert_eq!(after.pending_settings_audit, before.pending_settings_audit);
    assert_eq!(rows(pool).await.len(), count, "导航不写入设置审计");
    let bytes = std::fs::read(&path).unwrap();
    settings::save_navigation_at(&path, navigation.clone())
        .await
        .unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), bytes);

    save(&path, Some("zh"), Some("light"), None).await;
    let changed = config::load(&path).unwrap();
    assert_eq!(changed.workspace_navigation, navigation);
    assert_eq!(changed.pending_settings_audit.len(), 2);
    assert_eq!(
        changed.pending_settings_audit[0],
        before.pending_settings_audit[0]
    );
    settings::flush_pending_at(&path, pool).await.unwrap();
    assert_eq!(settings::load_navigation_at(&path).unwrap(), navigation);
    assert_eq!(rows(pool).await.len(), count + 2);

    // 各轮导航/主题均变化，使用屏障同时发起，并让 SQLite 补写与导航争用同一把锁。
    for wave in 0..12 {
        let next = WorkspaceNavigation {
            recent_kinds: vec![format!("page-{wave}")],
            favorite_kinds: vec!["audit".into()],
            nav_collapsed: wave % 2 == 0,
        };
        let theme = if wave % 2 == 0 { "dark" } else { "light" };
        let barrier = Arc::new(tokio::sync::Barrier::new(2));
        let mut tasks = tokio::task::JoinSet::new();
        let nav_path = path.clone();
        let nav_barrier = barrier.clone();
        let nav = next.clone();
        tasks.spawn(async move {
            nav_barrier.wait().await;
            settings::save_navigation_at(&nav_path, nav).await.unwrap();
        });
        let settings_path = path.clone();
        let settings_pool = pool.clone();
        tasks.spawn(async move {
            barrier.wait().await;
            settings::save_at(
                &settings_path,
                Some("zh".into()),
                Some(theme.into()),
                None,
                Some(&settings_pool),
            )
            .await
            .unwrap();
        });
        while let Some(result) = tasks.join_next().await {
            result.unwrap();
        }
        let saved = config::load(&path).unwrap();
        assert_eq!(saved.workspace_navigation, next);
        assert_eq!(saved.language.as_deref(), Some("zh"));
        assert_eq!(saved.theme.as_deref(), Some(theme));
        assert!(saved.pending_settings_audit.is_empty());
    }
    let all = rows(pool).await;
    assert_eq!(all.len(), count + 14);
    assert!(all[count + 2..]
        .iter()
        .all(|row| row.result == "changed: theme"));
}

async fn concurrent_save_and_flush(dir: &Path, pool: &sqlx::SqlitePool) {
    let path = dir.join("concurrent.json");
    identity("并发用户", Role::Viewer);
    let count = rows(pool).await.len();
    // 每轮所有保存请求相同，轮间偏好必定变化，因此真实变化数与调度顺序无关。
    for wave in 0..12 {
        let mut tasks = tokio::task::JoinSet::new();
        let barrier = Arc::new(tokio::sync::Barrier::new(9));
        for _ in 0..8 {
            let path = path.clone();
            let pool = pool.clone();
            let barrier = barrier.clone();
            tasks.spawn(async move {
                barrier.wait().await;
                settings::save_at(
                    &path,
                    Some(if wave % 2 == 0 { "en" } else { "zh" }.into()),
                    None,
                    None,
                    Some(&pool),
                )
                .await
                .unwrap();
                // 在其它 save/flush 仍可能进行时读取，不能看到半个 JSON。
                let json: serde_json::Value =
                    serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
                assert!(json.is_object());
            });
        }
        let flush_path = path.clone();
        let flush_pool = pool.clone();
        tasks.spawn(async move {
            barrier.wait().await;
            settings::flush_pending_at(&flush_path, &flush_pool)
                .await
                .unwrap();
        });
        while let Some(result) = tasks.join_next().await {
            result.unwrap();
        }
        assert_eq!(rows(pool).await.len(), count + wave + 1);
    }
    settings::flush_pending_at(&path, pool).await.unwrap();
    let all = rows(pool).await;
    let changed = &all[count..];
    assert_eq!(changed.len(), 12);
    assert_eq!(
        changed
            .iter()
            .map(|row| &row.correlation_id)
            .collect::<HashSet<_>>()
            .len(),
        12
    );
    assert!(changed
        .iter()
        .all(|row| row.actor == "并发用户" && row.result == "changed: language"));
    let saved = config::load(&path).unwrap();
    assert_eq!(saved.language.as_deref(), Some("zh"));
    assert!(saved.pending_settings_audit.is_empty());
}

async fn full_queue(dir: &Path, pool: &sqlx::SqlitePool) {
    let path = dir.join("full.json");
    identity("满队列用户", Role::Viewer);
    // 通过服务产生真实事件，避免手工构造队列掩盖丢事件。
    for index in 0..MAX_PENDING_SETTINGS_AUDIT {
        save(
            &path,
            Some(if index % 2 == 0 { "en" } else { "zh" }),
            None,
            None,
        )
        .await;
    }
    let original = std::fs::read(&path).unwrap();
    let full = config::load(&path).unwrap();
    assert_eq!(full.pending_settings_audit.len(), 200);
    let error = settings::save_at(&path, Some("en".into()), None, None, None)
        .await
        .unwrap_err();
    assert_eq!(error.code(), "KEEL-VALIDATION");
    assert_eq!(std::fs::read(&path).unwrap(), original);
    let error = settings::save_at(
        &path,
        full.language.clone(),
        full.theme.clone(),
        Some("en_GB".into()),
        None,
    )
    .await
    .unwrap_err();
    assert_eq!(error.code(), "KEEL-VALIDATION");
    assert_eq!(std::fs::read(&path).unwrap(), original);
    let count = rows(pool).await.len();
    // 目标契约：DB 可用时，单次保存先排空满队列再接受真实变化。
    // 不在测试里提前 flush；此断言由主代理的满队列行为修复支持。
    save(&path, Some("en"), None, Some(pool)).await;
    let saved = config::load(&path).unwrap();
    assert_eq!(saved.language.as_deref(), Some("en"));
    assert!(saved.pending_settings_audit.is_empty());
    let all = rows(pool).await;
    assert_eq!(all.len(), count + 201);
    for event in &full.pending_settings_audit {
        let matching: Vec<_> = all
            .iter()
            .filter(|row| row.correlation_id == event.id)
            .collect();
        assert_eq!(matching.len(), 1);
        assert_event(matching[0], event, "changed: language");
    }
    assert_eq!(all.last().unwrap().actor, "满队列用户");
    assert_eq!(all.last().unwrap().result, "changed: language");
}

async fn format_locale_audit(dir: &Path, pool: &sqlx::SqlitePool) {
    identity("区域用户", Role::Viewer);
    // 覆盖三字段的全部非空组合；保留旧摘要格式，新增字段排在最后。
    for mask in 1..8 {
        let path = dir.join(format!("format-{mask}.json"));
        let language = (mask & 1 != 0).then(|| "zh".to_string());
        let theme = (mask & 2 != 0).then(|| "dark".to_string());
        let locale = (mask & 4 != 0).then(|| "en_GB".to_string());
        let count = rows(pool).await.len();
        settings::save_at(&path, language.clone(), theme.clone(), locale.clone(), None)
            .await
            .unwrap();
        let saved = config::load(&path).unwrap();
        assert_eq!(saved.format_locale, locale);
        let event = &saved.pending_settings_audit[0];
        let expected: Vec<_> = ["language", "theme", "format_locale"]
            .into_iter()
            .enumerate()
            .filter(|(bit, _)| mask & (1 << *bit) != 0)
            .map(|(_, field)| field.to_string())
            .collect();
        assert_eq!(event.changed_fields, expected);
        let bytes = std::fs::read(&path).unwrap();
        settings::save_at(&path, language.clone(), theme.clone(), locale.clone(), None)
            .await
            .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        settings::flush_pending_at(&path, pool).await.unwrap();
        settings::flush_pending_at(&path, pool).await.unwrap();
        let all = rows(pool).await;
        assert_eq!(all.len(), count + 1);
        assert_event(
            &all[count],
            event,
            &format!("changed: {}", expected.join(",")),
        );
        assert!(!all[count].result.contains("en_GB"));

        if locale.is_some() {
            let navigation = WorkspaceNavigation {
                recent_kinds: vec!["audit".into()],
                ..Default::default()
            };
            settings::save_navigation_at(&path, navigation.clone())
                .await
                .unwrap();
            assert_eq!(config::load(&path).unwrap().format_locale, locale);
            let original = std::fs::read(&path).unwrap();
            for invalid in ["", "en-US", "EN_GB", "fr_FR", " en_US", "zh_CN\n"] {
                let error = settings::save_at(
                    &path,
                    language.clone(),
                    theme.clone(),
                    Some(invalid.into()),
                    Some(pool),
                )
                .await
                .unwrap_err();
                assert_eq!(error.code(), "KEEL-VALIDATION");
                assert_eq!(std::fs::read(&path).unwrap(), original);
            }
            assert_eq!(rows(pool).await.len(), count + 1);
            settings::save_at(&path, language, theme, None, Some(pool))
                .await
                .unwrap();
            let reset = config::load(&path).unwrap();
            assert_eq!(reset.format_locale, None);
            assert_eq!(reset.workspace_navigation, navigation);
            assert!(reset.pending_settings_audit.is_empty());
            let all = rows(pool).await;
            assert_eq!(all.len(), count + 2);
            assert_eq!(all.last().unwrap().result, "changed: format_locale");
        }
    }
}

/// Windows 关闭池后文件句柄可能延迟释放，重试清理避免误报。
fn remove_test_dir(path: &std::path::Path) {
    for _ in 0..40 {
        match std::fs::remove_dir_all(path) {
            Ok(()) => return,
            Err(error)
                if error.raw_os_error() == Some(32)
                    || error.kind() == std::io::ErrorKind::PermissionDenied =>
            {
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(error) => panic!("remove test dir failed: {error}"),
        }
    }
    std::fs::remove_dir_all(path).unwrap();
}
