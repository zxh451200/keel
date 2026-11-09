//! 独立 SQLite 服务回归；所有 CurrentUser 修改放在单个顺序测试中。
use rust_lib_keel::config::{self, AppConfig};
use rust_lib_keel::data::{self, audit::AuditRow};
use rust_lib_keel::diagnostics::events::{self, Level};
use rust_lib_keel::domain::permissions::Role;
use rust_lib_keel::services::{access, settings};
use std::path::Path;

const INPUT: &[u8] = br#"{"version":3,"language":"zh","theme":"light"}"#;

// 当前用户是进程级共享状态；同文件的 tokio 测试并行执行会互相覆盖身份，
// 让权限断言偶发拿到别人的用户。整个文件串行，避免把全局状态当成隔离夹具。
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn serial() -> tokio::sync::MutexGuard<'static, ()> {
    SERIAL.lock().await
}

fn identity(role: Role) {
    access::set_current(access::CurrentUser {
        name: "import-actor".into(),
        role,
    });
}

async fn rows(pool: &sqlx::SqlitePool) -> Vec<AuditRow> {
    sqlx::query_as(
        "SELECT id, at, actor, action, target, result, correlation_id \
         FROM audit_log WHERE action = 'settings.import' ORDER BY id",
    )
    .fetch_all(pool)
    .await
    .unwrap()
}

async fn import(mode: u8, path: &Path, source: &Path, pool: Option<&sqlx::SqlitePool>) {
    match mode {
        0 => settings::import_external_config_at_with_pool(path, INPUT, pool).await,
        1 => settings::import_external_config_file_at_with_pool(path, source, pool).await,
        _ => {
            let (id, _) = settings::prepare_external_config(INPUT.to_vec()).unwrap();
            settings::import_prepared_external_config_at_with_pool(path, &id, pool).await
        }
    }
    .unwrap();
}

#[tokio::test]
async fn persistent_import_audit_success_failure_permission_and_unavailable_audit() {
    let _serial = serial().await;
    let dir =
        std::env::temp_dir().join(format!("keel-settings-import-audit-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    let source = dir.join("PRIVATE_SOURCE.json");
    let pool = data::open(&dir.join("audit.db")).await.unwrap();
    data::user::insert(&pool, "preserved-user", "viewer", 123)
        .await
        .unwrap();
    let users_before: Vec<(i64, String, String, i64)> =
        sqlx::query_as("SELECT id, name, role, created_at FROM app_user ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    identity(Role::Admin);
    config::save(&path, &AppConfig::default()).unwrap();
    std::fs::write(&source, INPUT).unwrap();

    // 三条成功路径，每次持久提交后立即补写，只产生一条结果。
    for mode in 0..3 {
        import(mode, &path, &source, Some(&pool)).await;
    }
    let success = rows(&pool).await;
    assert_eq!(success.len(), 3);
    assert!(success.iter().all(|row| row.result == "ok"));
    assert_eq!(config::load(&path).unwrap().language.as_deref(), Some("zh"));
    assert!(config::load(&path)
        .unwrap()
        .pending_settings_audit
        .is_empty());

    // 在线补写后偏好语义不变；健康配置允许因失败审计而规范化重写。
    let original = config::load(&path).unwrap();
    let invalid = b"{ PRIVATE_INPUT";
    let error = settings::import_external_config_at_with_pool(&path, invalid, Some(&pool))
        .await
        .unwrap_err();
    assert_eq!(error.code(), "KEEL-IMPORT");
    std::fs::write(&source, invalid).unwrap();
    let error = settings::import_external_config_file_at_with_pool(&path, &source, Some(&pool))
        .await
        .unwrap_err();
    assert_eq!(error.code(), "KEEL-IMPORT");
    // prepared 的失效/重复消费句柄在同一个审计边界内。
    let (id, _) = settings::prepare_external_config(INPUT.to_vec()).unwrap();
    settings::import_prepared_external_config_at_with_pool(&path, &id, Some(&pool))
        .await
        .unwrap();
    let error = settings::import_prepared_external_config_at_with_pool(&path, &id, Some(&pool))
        .await
        .unwrap_err();
    assert_eq!(error.code(), "KEEL-IMPORT");
    assert_eq!(config::load(&path).unwrap(), original);
    let failed = rows(&pool).await;
    assert_eq!(failed.len(), 7);
    for index in [3, 4, 6] {
        assert_eq!(failed[index].result, "failed:KEEL-IMPORT");
    }

    // 同名用户角色变化也不能使用原预览。
    let (id, _) = settings::prepare_external_config(INPUT.to_vec()).unwrap();
    identity(Role::Viewer);
    let error = settings::import_external_config_at_with_pool(&path, INPUT, Some(&pool))
        .await
        .unwrap_err();
    assert_eq!(error.code(), "KEEL-PERMISSION");
    // 源文件不存在仍返回权限错误，证明文件读取前已拒绝。
    let error = settings::import_external_config_file_at_with_pool(
        &path,
        &dir.join("missing.json"),
        Some(&pool),
    )
    .await
    .unwrap_err();
    assert_eq!(error.code(), "KEEL-PERMISSION");
    let error = settings::import_prepared_external_config_at_with_pool(&path, &id, Some(&pool))
        .await
        .unwrap_err();
    assert_eq!(error.code(), "KEEL-PERMISSION");
    assert_eq!(config::load(&path).unwrap(), original);
    let denied = rows(&pool).await;
    assert_eq!(denied.len(), 10);
    assert!(denied[7..]
        .iter()
        .all(|row| row.result == "failed:KEEL-PERMISSION"));
    for row in &denied {
        assert_eq!(row.actor, "import-actor");
        assert_eq!(row.action, "settings.import");
        assert_eq!(row.target, "application");
        assert!(!row.correlation_id.is_empty());
        assert!(!row.result.contains("PRIVATE"));
    }
    let ids: std::collections::HashSet<_> = denied.iter().map(|row| &row.correlation_id).collect();
    assert_eq!(ids.len(), denied.len());

    // operator 也有导入权限，仍不得消费同名 admin 的预览；拒绝不消费句柄。
    identity(Role::Operator);
    let error = settings::import_prepared_external_config_at_with_pool(&path, &id, Some(&pool))
        .await
        .unwrap_err();
    assert_eq!(error.code(), "KEEL-PERMISSION");
    assert_eq!(config::load(&path).unwrap(), original);
    identity(Role::Admin);
    settings::import_prepared_external_config_at_with_pool(&path, &id, Some(&pool))
        .await
        .unwrap();
    let ownership = rows(&pool).await;
    assert_eq!(ownership.len(), 12);
    assert_eq!(ownership[10].result, "failed:KEEL-PERMISSION");
    assert_eq!(ownership[11].result, "ok");

    // 审计触发器失败仍应保存成功；固定诊断不能包含底层错误或源路径。
    identity(Role::Admin);
    std::fs::write(&source, INPUT).unwrap();
    sqlx::query(
        "CREATE TRIGGER reject_import BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.import' BEGIN \
         SELECT RAISE(FAIL, 'PRIVATE_DB_DETAIL /private/account.db'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    for mode in 0..3 {
        import(mode, &path, &source, Some(&pool)).await;
        let saved = config::load(&path).unwrap();
        assert_eq!(saved.language.as_deref(), Some("zh"));
        assert!(saved.pending_settings_audit.is_empty());
        assert_eq!(saved.pending_settings_import_audit.len(), mode as usize + 1);
    }
    assert_eq!(rows(&pool).await.len(), 12);
    let warnings = events::recent(50, Level::Warn);
    let warning = warnings
        .iter()
        .find(|event| event.summary == "Settings audit replay deferred; pending events retained.")
        .unwrap();
    assert_eq!(warning.code, "KEEL-DB");
    assert!(!warning.correlation_id.is_empty());
    assert!(!warning.summary.contains("PRIVATE"));
    assert!(!warning.summary.contains("import-actor"));
    sqlx::query("DROP TRIGGER reject_import")
        .execute(&pool)
        .await
        .unwrap();

    // 显式 None 无池：成功/失败均持久保留，连同此前 DB 故障的三条补写。
    import(0, &path, &source, None).await;
    assert_eq!(
        settings::import_external_config_at_with_pool(&path, invalid, None)
            .await
            .unwrap_err()
            .code(),
        "KEEL-IMPORT"
    );
    settings::flush_pending_at(&path, &pool).await.unwrap();
    assert_eq!(rows(&pool).await.len(), 17);
    assert!(config::load(&path)
        .unwrap()
        .pending_settings_import_audit
        .is_empty());
    format_locale_import(&path, &source, &pool).await;
    recovery_and_capacity(&dir, &pool).await;
    failed_import_migrates_healthy_v3(&dir).await;
    change_heavy_import_capacity(&dir, &pool).await;
    // Settings import/replay must neither mutate real users nor initialize POC tables.
    let users_after: Vec<(i64, String, String, i64)> =
        sqlx::query_as("SELECT id, name, role, created_at FROM app_user ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(users_after, users_before);
    let fixture_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master \
         WHERE type = 'table' AND name = 'grid_poc_fixture'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(fixture_count, 0);
    pool.close().await;
    remove_test_dir(&dir);
}

async fn format_locale_import(path: &Path, source: &Path, pool: &sqlx::SqlitePool) {
    identity(Role::Admin);
    // 三条导入路径均合并区域偏好，并逐字保留本机 pending，不接纳外部事件。
    for mode in 0..3 {
        settings::save_at(path, Some("en".into()), Some("dark".into()), None, None)
            .await
            .unwrap();
        let pending = config::load(path).unwrap().pending_settings_audit;
        assert!(!pending.is_empty());
        settings::import_external_config_at_with_pool(path, b"{ invalid", None)
            .await
            .unwrap_err();
        let local_imports = config::load(path).unwrap().pending_settings_import_audit;
        let input = serde_json::to_vec(&serde_json::json!({
            "version": 4, "language": "zh", "theme": "light", "format_locale": "en_GB",
            "pending_settings_audit": [{
                "id": "S11111111111111111111111111111111", "at": 1,
                "actor": "external", "changed_fields": ["format_locale"]
            }],
            "pending_settings_import_audit": [{
                "id": "S22222222222222222222222222222222", "at": 2,
                "actor": "external", "result": "ok"
            }]
        }))
        .unwrap();
        let count = rows(pool).await.len();
        match mode {
            0 => settings::import_external_config_at_with_pool(path, &input, None).await,
            1 => {
                std::fs::write(source, &input).unwrap();
                settings::import_external_config_file_at_with_pool(path, source, None).await
            }
            _ => {
                let (id, _) = settings::prepare_external_config(input).unwrap();
                settings::import_prepared_external_config_at_with_pool(path, &id, None).await
            }
        }
        .unwrap();
        let imported = config::load(path).unwrap();
        assert_eq!(imported.format_locale.as_deref(), Some("en_GB"));
        assert_eq!(imported.language.as_deref(), Some("zh"));
        assert_eq!(imported.pending_settings_audit, pending);
        assert_eq!(imported.pending_settings_import_audit.len(), 2);
        assert!(imported
            .pending_settings_import_audit
            .starts_with(&local_imports));
        assert_eq!(
            imported.pending_settings_import_audit[1].actor,
            "import-actor"
        );
        settings::flush_pending_at(path, pool).await.unwrap();
        let all = rows(pool).await;
        assert_eq!(all.len(), count + 2);
        assert_eq!(all.last().unwrap().result, "ok");
    }
    for value in [
        serde_json::json!("en-US"),
        serde_json::json!(""),
        serde_json::json!("fr_FR"),
        serde_json::json!(42),
        serde_json::json!(true),
        serde_json::json!([]),
        serde_json::json!({}),
    ] {
        let input = serde_json::to_vec(&serde_json::json!({
            "version": 4, "format_locale": value
        }))
        .unwrap();
        let original = config::load(path).unwrap();
        let count = rows(pool).await.len();
        let error = settings::import_external_config_at_with_pool(path, &input, Some(pool))
            .await
            .unwrap_err();
        assert_eq!(error.code(), "KEEL-IMPORT");
        assert_eq!(config::load(path).unwrap(), original);
        std::fs::write(source, &input).unwrap();
        assert_eq!(
            settings::import_external_config_file_at_with_pool(path, source, Some(pool))
                .await
                .unwrap_err()
                .code(),
            "KEEL-IMPORT"
        );
        assert!(settings::prepare_external_config(input).is_err());
        assert_eq!(config::load(path).unwrap(), original);
        let all = rows(pool).await;
        assert_eq!(all.len(), count + 2);
        assert!(all[count..]
            .iter()
            .all(|row| row.result == "failed:KEEL-IMPORT"));
    }
    // 旧配置导入恢复跟随系统，但不清空本机审计。
    for version in 1..=3 {
        settings::save_at(
            path,
            Some("zh".into()),
            Some("light".into()),
            Some("zh_CN".into()),
            None,
        )
        .await
        .unwrap();
        let before = config::load(path).unwrap().pending_settings_audit;
        let input = serde_json::to_vec(&serde_json::json!({
            "version": version, "language": "en"
        }))
        .unwrap();
        settings::import_external_config_at_with_pool(path, &input, None)
            .await
            .unwrap();
        let imported = config::load(path).unwrap();
        assert_eq!(imported.format_locale, None);
        assert_eq!(imported.pending_settings_audit, before);
        settings::flush_pending_at(path, pool).await.unwrap();
    }
}

async fn failed_import_migrates_healthy_v3(dir: &Path) {
    identity(Role::Admin);
    let path = dir.join("noncanonical-v3.json");
    let source = dir.join("invalid-v3-source.json");
    // 特意使用紧凑/乱序字段和首尾空白；两种既有队列均非空。
    let original = br#"  {"theme":"dark","version":3,"language":"en",
      "workspace_navigation":{"nav_collapsed":true,"favorite_kinds":["users"],"recent_kinds":["audit"]},
      "pending_settings_import_audit":[
        {"result":"ok","actor":"old-import-owner","at":11,"id":"I00000000000000000000000000000001"},
        {"result":"failed:KEEL-IMPORT","actor":"old-import-owner","at":12,"id":"I00000000000000000000000000000002"}],
      "pending_settings_audit":[
        {"changed_fields":["language"],"actor":"old-change-owner","at":21,"id":"S00000000000000000000000000000001"},
        {"changed_fields":["theme"],"actor":"old-change-owner","at":22,"id":"S00000000000000000000000000000002"}]
    }  "#;
    std::fs::write(&source, b"{ PRIVATE_INPUT").unwrap();
    for mode in 0..3 {
        std::fs::write(&path, original).unwrap();
        let before = config::load(&path).unwrap();
        assert_eq!(before.version, config::CURRENT_VERSION);
        assert_eq!(before.language.as_deref(), Some("en"));
        assert_eq!(before.theme.as_deref(), Some("dark"));
        assert_eq!(before.format_locale, None);
        assert_eq!(before.pending_settings_audit.len(), 2);
        assert_eq!(before.pending_settings_import_audit.len(), 2);
        assert_eq!(
            std::fs::read(&path).unwrap(),
            original,
            "读取迁移不能提前改文件"
        );
        let started = rust_lib_keel::services::audit::now_ms();
        let error = match mode {
            0 => {
                settings::import_external_config_at_with_pool(&path, b"{ PRIVATE_INPUT", None).await
            }
            1 => settings::import_external_config_file_at_with_pool(&path, &source, None).await,
            _ => {
                settings::import_prepared_external_config_at_with_pool(
                    &path,
                    "nonexistent-preview",
                    None,
                )
                .await
            }
        }
        .unwrap_err();
        let finished = rust_lib_keel::services::audit::now_ms();
        assert_eq!(error.code(), "KEEL-IMPORT");
        let persisted = std::fs::read(&path).unwrap();
        assert_ne!(persisted, original, "失败结果持久化允许规范化迁移健康文件");
        let json: serde_json::Value = serde_json::from_slice(&persisted).unwrap();
        assert_eq!(json["version"], config::CURRENT_VERSION);
        let mut after = config::load(&path).unwrap();
        assert_eq!(after.pending_settings_audit, before.pending_settings_audit);
        assert!(after
            .pending_settings_import_audit
            .starts_with(&before.pending_settings_import_audit));
        assert_eq!(
            after.pending_settings_import_audit.len(),
            before.pending_settings_import_audit.len() + 1
        );
        let event = after.pending_settings_import_audit.pop().unwrap();
        event.validate().unwrap();
        assert_eq!(event.result, "failed:KEEL-IMPORT");
        assert_eq!(event.actor, "import-actor");
        assert!((started..=finished).contains(&event.at));
        assert!(!before
            .pending_settings_audit
            .iter()
            .any(|old| old.id == event.id));
        assert!(!before
            .pending_settings_import_audit
            .iter()
            .any(|old| old.id == event.id));
        assert_eq!(
            after, before,
            "除版本规范化和追加失败事件外，偏好/两队列原事件均不变"
        );
        assert!(!String::from_utf8(persisted)
            .unwrap()
            .contains("PRIVATE_INPUT"));
    }
}

async fn change_heavy_import_capacity(dir: &Path, pool: &sqlx::SqlitePool) {
    use rust_lib_keel::config::MAX_PENDING_SETTINGS_AUDIT;

    let path = dir.join("change-heavy-capacity.json");
    access::set_current(access::CurrentUser {
        name: "change-owner".into(),
        role: Role::Admin,
    });
    // 用真实离线保存产生 199 个 change，不能将 199 + 新事件误判成超限。
    for index in 0..MAX_PENDING_SETTINGS_AUDIT - 1 {
        settings::save_at(
            &path,
            Some(if index % 2 == 0 { "en" } else { "zh" }.into()),
            None,
            None,
            None,
        )
        .await
        .unwrap();
    }
    let before = config::load(&path).unwrap();
    assert_eq!(before.pending_settings_audit.len(), 199);
    assert!(before.pending_settings_import_audit.is_empty());
    identity(Role::Admin);
    let import_count = rows(pool).await.len();
    let change_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM audit_log WHERE action = 'settings.change'")
            .fetch_one(pool)
            .await
            .unwrap();
    settings::import_external_config_at_with_pool(&path, INPUT, None)
        .await
        .unwrap();
    let full = config::load(&path).unwrap();
    assert_eq!(full.pending_settings_audit, before.pending_settings_audit);
    assert_eq!(full.pending_settings_import_audit.len(), 1);
    assert_eq!(full.pending_audit_len(), MAX_PENDING_SETTINGS_AUDIT);
    assert_eq!(full.language.as_deref(), Some("zh"));
    assert_eq!(full.theme.as_deref(), Some("light"));
    let first_import = &full.pending_settings_import_audit[0];
    assert_eq!(first_import.actor, "import-actor");
    assert_eq!(first_import.result, "ok");
    assert_eq!(rows(pool).await.len(), import_count, "无池应留存成功事件");
    let bytes = std::fs::read(&path).unwrap();
    let next = br#"{"version":4,"language":"en","theme":"dark","format_locale":"en_GB"}"#;
    // 满 200 后拒绝成功候选及失败尝试，均不得为失败审计改写原文件。
    for input in [next.as_slice(), b"{ invalid".as_slice()] {
        assert_eq!(
            settings::import_external_config_at_with_pool(&path, input, None)
                .await
                .unwrap_err()
                .code(),
            "KEEL-IMPORT"
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
    // 不在测试中提前 flush；同一次调用必须先排空 200 条再导入新偏好。
    let started = rust_lib_keel::services::audit::now_ms();
    settings::import_external_config_at_with_pool(&path, next, Some(pool))
        .await
        .unwrap();
    let finished = rust_lib_keel::services::audit::now_ms();
    let saved = config::load(&path).unwrap();
    // v4 输入可读；保存按当前版本（v5）写回，time_zone/currency 保留默认空。
    let mut expected: AppConfig = serde_json::from_slice(next).unwrap();
    expected.version = config::CURRENT_VERSION;
    assert_eq!(saved, expected, "新偏好已合并，补写后两队列均空");
    let imports = rows(pool).await;
    assert_eq!(imports.len(), import_count + 2);
    let first: Vec<_> = imports
        .iter()
        .filter(|row| row.correlation_id == first_import.id)
        .collect();
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].at, first_import.at);
    assert_eq!(first[0].actor, first_import.actor);
    assert_eq!(first[0].result, first_import.result);
    assert_eq!(first[0].target, "application");
    let latest = imports.last().unwrap();
    assert_ne!(latest.correlation_id, first_import.id);
    assert!(!latest.correlation_id.is_empty());
    assert_eq!(latest.actor, "import-actor");
    assert_eq!(latest.result, "ok");
    assert_eq!(latest.target, "application");
    assert!((started..=finished).contains(&latest.at));
    let changes: Vec<AuditRow> = sqlx::query_as(
        "SELECT id, at, actor, action, target, result, correlation_id \
         FROM audit_log WHERE action = 'settings.change'",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    assert_eq!(changes.len() as i64, change_count + 199);
    for event in &before.pending_settings_audit {
        let matching: Vec<_> = changes
            .iter()
            .filter(|row| row.correlation_id == event.id)
            .collect();
        assert_eq!(matching.len(), 1);
        assert_eq!(matching[0].at, event.at);
        assert_eq!(matching[0].actor, event.actor);
        assert_eq!(matching[0].result, "changed: language");
        assert_eq!(matching[0].target, "application");
    }
    settings::flush_pending_at(&path, pool).await.unwrap();
    assert_eq!(
        rows(pool).await.len(),
        import_count + 2,
        "后续 flush 不重复导入审计"
    );
    let replay_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM audit_log WHERE action = 'settings.change'")
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(replay_count, change_count + 199);
}

// 子进程独立初始化全局状态，验证实际启动链路，不只在原进程手动 flush。
#[tokio::test]
async fn startup_replays_import_outbox_child() {
    let _serial = serial().await;
    if std::env::var_os("KEEL_IMPORT_REPLAY_CHILD").is_none() {
        return;
    }
    rust_lib_keel::services::startup::initialize()
        .await
        .unwrap();
    assert_eq!(
        config::load(&config::config_path().unwrap())
            .unwrap()
            .pending_audit_len(),
        0
    );
}

async fn recovery_and_capacity(dir: &Path, pool: &sqlx::SqlitePool) {
    use rust_lib_keel::config::MAX_PENDING_SETTINGS_AUDIT;

    identity(Role::Admin);
    let path = dir.join("recovery.json");
    settings::save_at(&path, Some("en".into()), None, None, None)
        .await
        .unwrap();
    let change = config::load(&path).unwrap().pending_settings_audit[0].clone();
    let start = rust_lib_keel::services::audit::now_ms();
    settings::import_external_config_at_with_pool(&path, INPUT, None)
        .await
        .unwrap();
    settings::import_external_config_at_with_pool(&path, b"{ PRIVATE_INPUT", None)
        .await
        .unwrap_err();
    let pending = config::load(&path).unwrap();
    assert_eq!(
        pending.pending_settings_audit,
        std::slice::from_ref(&change)
    );
    assert_eq!(pending.pending_settings_import_audit.len(), 2);
    assert_eq!(pending.pending_settings_import_audit[0].result, "ok");
    assert_eq!(
        pending.pending_settings_import_audit[1].result,
        "failed:KEEL-IMPORT"
    );
    let end = rust_lib_keel::services::audit::now_ms();
    for event in &pending.pending_settings_import_audit {
        assert!((start..=end).contains(&event.at));
        assert_eq!(event.actor, "import-actor");
    }
    let snapshot = std::fs::read(&path).unwrap();

    // 首条成功、第二条被触发器拒绝：完整磁盘队列保留，重放首条不得再次触发 INSERT。
    sqlx::query(
        "CREATE TRIGGER reject_failed_import BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.import' AND NEW.result != 'ok' \
         BEGIN SELECT RAISE(FAIL, 'PRIVATE_DB_DETAIL'); END",
    )
    .execute(pool)
    .await
    .unwrap();
    let count = rows(pool).await.len();
    assert_eq!(
        settings::flush_pending_at(&path, pool)
            .await
            .unwrap_err()
            .code(),
        "KEEL-DB"
    );
    assert_eq!(rows(pool).await.len(), count + 1);
    assert_eq!(std::fs::read(&path).unwrap(), snapshot);
    sqlx::query("DROP TRIGGER reject_failed_import")
        .execute(pool)
        .await
        .unwrap();
    sqlx::query(
        "CREATE TRIGGER reject_duplicate_import BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.import' AND EXISTS(SELECT 1 FROM audit_log \
         WHERE action = NEW.action AND correlation_id = NEW.correlation_id) \
         BEGIN SELECT RAISE(FAIL, 'duplicate insert attempted'); END",
    )
    .execute(pool)
    .await
    .unwrap();
    identity(Role::Viewer);
    settings::flush_pending_at(&path, pool).await.unwrap();
    // 模拟 DB 已提交、配置尚未清队列的崩溃快照；实际清理 I/O 故障另有单测。
    std::fs::write(&path, &snapshot).unwrap();
    settings::flush_pending_at(&path, pool).await.unwrap();
    settings::flush_pending_at(&path, pool).await.unwrap();
    let all = rows(pool).await;
    assert_eq!(all.len(), count + 2);
    for event in &pending.pending_settings_import_audit {
        let matching: Vec<_> = all
            .iter()
            .filter(|row| row.correlation_id == event.id)
            .collect();
        assert_eq!(matching.len(), 1);
        assert_eq!(matching[0].actor, event.actor);
        assert_eq!(matching[0].at, event.at);
        assert_eq!(matching[0].result, event.result);
        assert_eq!(matching[0].target, "application");
    }
    let change_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM audit_log WHERE action = 'settings.change' AND correlation_id = ?1",
    )
    .bind(&change.id)
    .fetch_one(pool)
    .await
    .unwrap();
    assert_eq!(change_count, 1);
    sqlx::query("DROP TRIGGER reject_duplicate_import")
        .execute(pool)
        .await
        .unwrap();

    // IGNORE 没有 SQL 错误但也没有写入，不能清 outbox。
    sqlx::query(
        "CREATE TRIGGER ignore_import BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.import' BEGIN SELECT RAISE(IGNORE); END",
    )
    .execute(pool)
    .await
    .unwrap();
    std::fs::remove_file(&path).unwrap();
    identity(Role::Admin);
    settings::import_external_config_at_with_pool(&path, INPUT, Some(pool))
        .await
        .unwrap();
    let ignored = std::fs::read(&path).unwrap();
    assert_eq!(
        config::load(&path)
            .unwrap()
            .pending_settings_import_audit
            .len(),
        1
    );
    assert!(settings::flush_pending_at(&path, pool).await.is_err());
    assert_eq!(std::fs::read(&path).unwrap(), ignored);
    sqlx::query("DROP TRIGGER ignore_import")
        .execute(pool)
        .await
        .unwrap();
    settings::flush_pending_at(&path, pool).await.unwrap();

    // 混合总容量恰为 200：199 个成功导入与一个普通变更。
    std::fs::remove_file(&path).unwrap();
    settings::save_at(&path, Some("en".into()), None, None, None)
        .await
        .unwrap();
    for _ in 1..MAX_PENDING_SETTINGS_AUDIT {
        settings::import_external_config_at_with_pool(&path, INPUT, None)
            .await
            .unwrap();
    }
    let full = std::fs::read(&path).unwrap();
    assert_eq!(
        config::load(&path).unwrap().pending_audit_len(),
        MAX_PENDING_SETTINGS_AUDIT
    );
    assert_eq!(
        settings::import_external_config_at_with_pool(&path, INPUT, None)
            .await
            .unwrap_err()
            .code(),
        "KEEL-IMPORT"
    );
    assert_eq!(std::fs::read(&path).unwrap(), full);
    assert!(
        settings::save_at(&path, Some("en".into()), None, None, None)
            .await
            .is_err()
    );
    assert_eq!(std::fs::read(&path).unwrap(), full);
    sqlx::query(
        "CREATE TRIGGER reject_full_import BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.import' BEGIN SELECT RAISE(FAIL, 'blocked'); END",
    )
    .execute(pool)
    .await
    .unwrap();
    assert!(
        settings::import_external_config_at_with_pool(&path, INPUT, Some(pool))
            .await
            .is_err()
    );
    assert_eq!(std::fs::read(&path).unwrap(), full);
    sqlx::query("DROP TRIGGER reject_full_import")
        .execute(pool)
        .await
        .unwrap();
    let count = rows(pool).await.len();
    settings::import_external_config_at_with_pool(&path, INPUT, Some(pool))
        .await
        .unwrap();
    assert_eq!(config::load(&path).unwrap().pending_audit_len(), 0);
    assert_eq!(rows(pool).await.len(), count + MAX_PENDING_SETTINGS_AUDIT);

    // 坏配置/未来版本不得为了记录失败而覆盖；只留下固定安全诊断。
    for bytes in [b"{ broken".as_slice(), br#"{"version":99}"#.as_slice()] {
        std::fs::write(&path, bytes).unwrap();
        assert!(
            settings::import_external_config_at_with_pool(&path, INPUT, None)
                .await
                .is_err()
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
    assert!(events::recent(50, Level::Warn).iter().any(|event| {
        event.summary
            == "Settings import outcome not persisted; replay unavailable for this attempt."
    }));
    // 不可写目标不能记录失败，也不能覆盖阻塞路径中的普通文件。
    let blocker = dir.join("not-a-directory");
    std::fs::write(&blocker, b"PRIVATE_LOCAL_FILE").unwrap();
    assert!(settings::import_external_config_at_with_pool(
        &blocker.join("config.json"),
        INPUT,
        None,
    )
    .await
    .is_err());
    assert_eq!(std::fs::read(&blocker).unwrap(), b"PRIVATE_LOCAL_FILE");

    let restart_dir = dir.join("restart");
    std::fs::create_dir(&restart_dir).unwrap();
    let restart_path = restart_dir.join("config.json");
    settings::import_external_config_at_with_pool(&restart_path, INPUT, None)
        .await
        .unwrap();
    settings::import_external_config_at_with_pool(&restart_path, b"{ invalid", None)
        .await
        .unwrap_err();
    let before_restart = config::load(&restart_path).unwrap();
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "startup_replays_import_outbox_child",
            "--nocapture",
        ])
        .env("KEEL_IMPORT_REPLAY_CHILD", "1")
        .env(config::DATA_DIR_ENV, &restart_dir)
        .status()
        .unwrap();
    assert!(status.success());
    let reopened = data::open(&restart_dir.join("keel.db")).await.unwrap();
    let replayed = rows(&reopened).await;
    assert_eq!(replayed.len(), 2);
    for (row, event) in replayed
        .iter()
        .zip(&before_restart.pending_settings_import_audit)
    {
        assert_eq!(row.correlation_id, event.id);
        assert_eq!(row.actor, event.actor);
        assert_eq!(row.at, event.at);
        assert_eq!(row.result, event.result);
    }
    assert_eq!(config::load(&restart_path).unwrap().pending_audit_len(), 0);
    reopened.close().await;
}

#[tokio::test]
async fn import_success_preserves_pending_change_when_import_audit_is_temporarily_rejected() {
    let _serial = serial().await;
    let dir = std::env::temp_dir().join(format!("keel-import-mixed-save-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    let pool = data::open(&dir.join("audit.db")).await.unwrap();
    identity(Role::Admin);
    config::save(&path, &AppConfig::default()).unwrap();

    settings::save_at(&path, Some("en".into()), None, None, None)
        .await
        .unwrap();
    let change = config::load(&path).unwrap().pending_settings_audit[0].clone();

    sqlx::query(
        "CREATE TRIGGER reject_import_mixed_save BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.import' BEGIN \
         SELECT RAISE(FAIL, 'temporary import audit failure'); END",
    )
    .execute(&pool)
    .await
    .unwrap();

    settings::import_external_config_at_with_pool(
        &path,
        br#"{"version":4,"language":"zh","theme":"dark"}"#,
        Some(&pool),
    )
    .await
    .unwrap();

    let saved = config::load(&path).unwrap();
    assert_eq!(saved.language.as_deref(), Some("zh"));
    assert_eq!(saved.theme.as_deref(), Some("dark"));
    assert_eq!(saved.pending_settings_audit, std::slice::from_ref(&change));
    assert_eq!(saved.pending_settings_import_audit.len(), 1);
    assert_eq!(saved.pending_settings_import_audit[0].result, "ok");
    assert_eq!(saved.pending_settings_import_audit[0].actor, "import-actor");
    assert_eq!(rows(&pool).await.len(), 0);

    sqlx::query("DROP TRIGGER reject_import_mixed_save")
        .execute(&pool)
        .await
        .unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();

    let changes: Vec<AuditRow> = sqlx::query_as(
        "SELECT id, at, actor, action, target, result, correlation_id \
         FROM audit_log WHERE action = 'settings.change'",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(changes.len(), 1);
    assert_eq!(changes[0].correlation_id, change.id);
    assert_eq!(changes[0].actor, change.actor);
    assert_eq!(rows(&pool).await.len(), 1);
    assert_eq!(config::load(&path).unwrap().pending_audit_len(), 0);

    pool.close().await;
    remove_test_dir(&dir);
}

// 不修改全局身份/池；直接保存合法的混合 outbox，隔离重放故障本身。
#[tokio::test]
async fn ignored_change_keeps_both_outboxes_until_replay_recovers() {
    let _serial = serial().await;
    use rust_lib_keel::config::{PendingSettingsAudit, PendingSettingsImportAudit};

    let dir = std::env::temp_dir().join(format!("keel-mixed-ignore-change-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    let pool = data::open(&dir.join("audit.db")).await.unwrap();
    let pending = AppConfig {
        language: Some("en".into()),
        pending_settings_audit: vec![PendingSettingsAudit {
            id: "S11111111111111111111111111111111".into(),
            at: 123,
            actor: "original-change-owner".into(),
            changed_fields: vec!["language".into()],
        }],
        pending_settings_import_audit: vec![PendingSettingsImportAudit {
            id: "I22222222222222222222222222222222".into(),
            at: 456,
            actor: "original-import-owner".into(),
            result: "failed:KEEL-IMPORT".into(),
        }],
        ..AppConfig::default()
    };
    config::save(&path, &pending).unwrap();
    let snapshot = std::fs::read(&path).unwrap();
    sqlx::query(
        "CREATE TRIGGER ignore_change BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.change' BEGIN SELECT RAISE(IGNORE); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    for _ in 0..2 {
        assert_eq!(
            settings::flush_pending_at(&path, &pool)
                .await
                .unwrap_err()
                .code(),
            "KEEL-INTERNAL"
        );
        assert_eq!(std::fs::read(&path).unwrap(), snapshot);
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 0, "change 未确认时不能继续导入事件并清理混合队列");
    }
    sqlx::query("DROP TRIGGER ignore_change")
        .execute(&pool)
        .await
        .unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    let replayed: Vec<AuditRow> = sqlx::query_as(
        "SELECT id, at, actor, action, target, result, correlation_id FROM audit_log ORDER BY id",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(replayed.len(), 2);
    assert_eq!(replayed[0].action, "settings.change");
    assert_eq!(
        replayed[0].correlation_id,
        pending.pending_settings_audit[0].id
    );
    assert_eq!(replayed[0].at, 123);
    assert_eq!(replayed[0].actor, "original-change-owner");
    assert_eq!(replayed[0].result, "changed: language");
    assert_eq!(replayed[1].action, "settings.import");
    assert_eq!(
        replayed[1].correlation_id,
        pending.pending_settings_import_audit[0].id
    );
    assert_eq!(replayed[1].at, 456);
    assert_eq!(replayed[1].actor, "original-import-owner");
    assert_eq!(replayed[1].result, "failed:KEEL-IMPORT");
    assert!(replayed.iter().all(|row| row.target == "application"));
    let saved = config::load(&path).unwrap();
    assert_eq!(saved.pending_audit_len(), 0);
    assert_eq!(saved.language, pending.language);
    pool.close().await;
    remove_test_dir(&dir);
}

#[tokio::test]
async fn failed_first_import_after_change_keeps_mixed_outbox_until_replay_recovers() {
    let _serial = serial().await;
    use rust_lib_keel::config::{PendingSettingsAudit, PendingSettingsImportAudit};

    let dir = std::env::temp_dir().join(format!(
        "keel-mixed-failed-first-import-{}",
        rust_lib_keel::diagnostics::correlation::new_correlation_id(),
    ));
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("config.json");
    let database = dir.join("audit.db");
    let pool = data::open(&database).await.unwrap();
    let change = PendingSettingsAudit {
        id: "S77777777777777777777777777777777".into(),
        at: 111,
        actor: "change-owner".into(),
        changed_fields: vec!["language".into()],
    };
    let import = PendingSettingsImportAudit {
        id: "I88888888888888888888888888888888".into(),
        at: 222,
        actor: "import-owner".into(),
        result: "failed:KEEL-IMPORT".into(),
    };
    let pending = AppConfig {
        language: Some("en".into()),
        pending_settings_audit: vec![change.clone()],
        pending_settings_import_audit: vec![import.clone()],
        ..AppConfig::default()
    };
    config::save(&path, &pending).unwrap();
    let snapshot = std::fs::read(&path).unwrap();
    sqlx::query(
        "CREATE TRIGGER reject_first_import BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.import' BEGIN \
         SELECT RAISE(FAIL, 'temporary import SQL failure'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    for _ in 0..2 {
        assert_eq!(
            settings::flush_pending_at(&path, &pool)
                .await
                .unwrap_err()
                .code(),
            "KEEL-DB",
        );
        assert_eq!(std::fs::read(&path).unwrap(), snapshot);
        let written: Vec<AuditRow> = sqlx::query_as(
            "SELECT id, at, actor, action, target, result, correlation_id \
             FROM audit_log ORDER BY id",
        )
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(written.len(), 1);
        assert_eq!(written[0].action, "settings.change");
        assert_eq!(written[0].correlation_id, change.id);
        assert_eq!(written[0].at, change.at);
        assert_eq!(written[0].actor, change.actor);
        assert_eq!(written[0].result, "changed: language");
    }
    pool.close().await;
    let pool = data::open(&database).await.unwrap();
    sqlx::query("DROP TRIGGER reject_first_import")
        .execute(&pool)
        .await
        .unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    let replayed: Vec<AuditRow> = sqlx::query_as(
        "SELECT id, at, actor, action, target, result, correlation_id \
         FROM audit_log ORDER BY id",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(replayed.len(), 2);
    assert_eq!(replayed[0].correlation_id, change.id);
    assert_eq!(replayed[1].action, "settings.import");
    assert_eq!(replayed[1].correlation_id, import.id);
    assert_eq!(replayed[1].at, import.at);
    assert_eq!(replayed[1].actor, import.actor);
    assert_eq!(replayed[1].result, import.result);
    assert!(replayed.iter().all(|row| row.target == "application"));
    let mut expected = pending;
    expected.pending_settings_audit.clear();
    expected.pending_settings_import_audit.clear();
    assert_eq!(config::load(&path).unwrap(), expected);
    pool.close().await;
    remove_test_dir(&dir);
}

#[tokio::test]
async fn ignored_import_after_partial_replay_keeps_mixed_outbox_until_exact_records_exist() {
    let _serial = serial().await;
    use rust_lib_keel::config::{PendingSettingsAudit, PendingSettingsImportAudit};

    let dir = std::env::temp_dir().join(format!("keel-mixed-ignore-import-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    let pool = data::open(&dir.join("audit.db")).await.unwrap();
    let change = PendingSettingsAudit {
        id: "S44444444444444444444444444444444".into(),
        at: 101,
        actor: "change-owner".into(),
        changed_fields: vec!["theme".into()],
    };
    let first_import = PendingSettingsImportAudit {
        id: "I55555555555555555555555555555555".into(),
        at: 202,
        actor: "first-import-owner".into(),
        result: "ok".into(),
    };
    let ignored_import = PendingSettingsImportAudit {
        id: "I66666666666666666666666666666666".into(),
        at: 303,
        actor: "ignored-import-owner".into(),
        result: "failed:KEEL-IMPORT".into(),
    };
    let pending = AppConfig {
        theme: Some("dark".into()),
        pending_settings_audit: vec![change.clone()],
        pending_settings_import_audit: vec![first_import.clone(), ignored_import.clone()],
        ..AppConfig::default()
    };
    config::save(&path, &pending).unwrap();
    let snapshot = std::fs::read(&path).unwrap();

    sqlx::query(
        "CREATE TRIGGER ignore_second_import BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'settings.import' \
         AND NEW.result = 'failed:KEEL-IMPORT' BEGIN SELECT RAISE(IGNORE); END",
    )
    .execute(&pool)
    .await
    .unwrap();

    // change 与 first_import 已写入，后一个 import 被静默忽略；
    // 因此整个混合队列必须保留，不能只按 SQL 成功返回清空。
    assert_eq!(
        settings::flush_pending_at(&path, &pool)
            .await
            .unwrap_err()
            .code(),
        "KEEL-INTERNAL"
    );
    let rows: Vec<AuditRow> = sqlx::query_as(
        "SELECT id, at, actor, action, target, result, correlation_id \
         FROM audit_log ORDER BY id",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].action, "settings.change");
    assert_eq!(rows[0].at, change.at);
    assert_eq!(rows[0].actor, change.actor);
    assert_eq!(rows[0].target, "application");
    assert_eq!(rows[0].result, "changed: theme");
    assert_eq!(rows[0].correlation_id, change.id);
    assert_eq!(rows[1].action, "settings.import");
    assert_eq!(rows[1].at, first_import.at);
    assert_eq!(rows[1].actor, first_import.actor);
    assert_eq!(rows[1].target, "application");
    assert_eq!(rows[1].result, first_import.result);
    assert_eq!(rows[1].correlation_id, first_import.id);
    let committed_ids = [rows[0].id, rows[1].id];
    assert_eq!(
        settings::flush_pending_at(&path, &pool)
            .await
            .unwrap_err()
            .code(),
        "KEEL-INTERNAL"
    );
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 2, "重复补写仍不能把被忽略的事件当作已入库");
    assert_eq!(config::load(&path).unwrap(), pending);
    assert_eq!(std::fs::read(&path).unwrap(), snapshot);

    sqlx::query("DROP TRIGGER ignore_second_import")
        .execute(&pool)
        .await
        .unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    // 第二次补写经过 NOT EXISTS，已确认的前两条不会重复。
    settings::flush_pending_at(&path, &pool).await.unwrap();

    let rows: Vec<AuditRow> = sqlx::query_as(
        "SELECT id, at, actor, action, target, result, correlation_id \
         FROM audit_log ORDER BY id",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(rows.len(), 3);
    assert_eq!([rows[0].id, rows[1].id], committed_ids);
    let restored = rows
        .iter()
        .find(|row| row.correlation_id == ignored_import.id)
        .unwrap();
    assert_eq!(restored.at, ignored_import.at);
    assert_eq!(restored.actor, ignored_import.actor);
    assert_eq!(restored.action, "settings.import");
    assert_eq!(restored.target, "application");
    assert_eq!(restored.result, ignored_import.result);
    let mut expected = pending;
    expected.pending_settings_audit.clear();
    expected.pending_settings_import_audit.clear();
    assert_eq!(config::load(&path).unwrap(), expected);

    pool.close().await;
    remove_test_dir(&dir);
}

#[tokio::test]
async fn conflicting_import_record_retains_outbox_until_exact_record_is_restored() {
    let _serial = serial().await;
    use rust_lib_keel::config::PendingSettingsImportAudit;

    let dir = std::env::temp_dir().join(format!(
        "keel-import-record-conflict-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("config.json");
    let pool = data::open(&dir.join("audit.db")).await.unwrap();
    let event = PendingSettingsImportAudit {
        id: "I33333333333333333333333333333333".into(),
        at: 123,
        actor: "original-owner".into(),
        result: "failed:KEEL-IMPORT".into(),
    };
    let pending = AppConfig {
        theme: Some("dark".into()),
        pending_settings_import_audit: vec![event.clone()],
        ..AppConfig::default()
    };
    config::save(&path, &pending).unwrap();
    let snapshot = std::fs::read(&path).unwrap();
    // 每轮只让一个字段不符，避免其他字段掩盖缺少的校验。
    for (at, actor, target, result) in [
        (
            124_i64,
            "original-owner",
            "application",
            "failed:KEEL-IMPORT",
        ),
        (123, "different-owner", "application", "failed:KEEL-IMPORT"),
        (
            123,
            "original-owner",
            "different-target",
            "failed:KEEL-IMPORT",
        ),
        (123, "original-owner", "application", "ok"),
    ] {
        sqlx::query("DELETE FROM audit_log")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO audit_log (at, actor, action, target, result, correlation_id) \
             VALUES (?1, ?2, 'settings.import', ?3, ?4, ?5)",
        )
        .bind(at)
        .bind(actor)
        .bind(target)
        .bind(result)
        .bind(&event.id)
        .execute(&pool)
        .await
        .unwrap();
        for _ in 0..2 {
            assert_eq!(
                settings::flush_pending_at(&path, &pool)
                    .await
                    .unwrap_err()
                    .code(),
                "KEEL-INTERNAL"
            );
            assert_eq!(std::fs::read(&path).unwrap(), snapshot);
            let existing = rows(&pool).await;
            assert_eq!(existing.len(), 1, "冲突不能通过重复插入或覆盖记录来消除");
            assert_eq!(existing[0].at, at);
            assert_eq!(existing[0].actor, actor);
            assert_eq!(existing[0].target, target);
            assert_eq!(existing[0].result, result);
            assert_eq!(existing[0].correlation_id, event.id);
        }
    }
    sqlx::query(
        "UPDATE audit_log SET at = ?1, actor = ?2, target = 'application', result = ?3 \
         WHERE action = 'settings.import' AND correlation_id = ?4",
    )
    .bind(event.at)
    .bind(&event.actor)
    .bind(&event.result)
    .bind(&event.id)
    .execute(&pool)
    .await
    .unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    let replayed = rows(&pool).await;
    assert_eq!(replayed.len(), 1);
    assert_eq!(replayed[0].at, event.at);
    assert_eq!(replayed[0].actor, event.actor);
    assert_eq!(replayed[0].result, event.result);
    assert_eq!(replayed[0].target, "application");
    let saved = config::load(&path).unwrap();
    assert_eq!(saved.pending_audit_len(), 0);
    assert_eq!(saved.theme, pending.theme);
    pool.close().await;
    remove_test_dir(&dir);
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
    remove_test_dir(path);
}
