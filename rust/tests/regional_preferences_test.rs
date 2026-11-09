use rust_lib_keel::config::{self, RegionalPreferences, CURRENT_VERSION};
use rust_lib_keel::data;
use rust_lib_keel::diagnostics::correlation::new_correlation_id;
use rust_lib_keel::services::settings;

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

#[tokio::test]
async fn migration_independent_saves_validation_and_replay() {
    let dir = std::env::temp_dir().join(format!("keel-regional-{}", new_correlation_id()));
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("config.json");
    for version in 1..=4 {
        let original = serde_json::to_vec(&serde_json::json!({
            "version": version, "language": "en", "format_locale": "zh_CN",
            "time_zone": "UTC", "currency": "JPY",
        }))
        .unwrap();
        std::fs::write(&path, &original).unwrap();
        let migrated = config::load(&path).unwrap();
        assert_eq!(migrated.version, CURRENT_VERSION);
        assert_eq!(migrated.time_zone, None);
        assert_eq!(migrated.currency, None);
        assert_eq!(std::fs::read(&path).unwrap(), original);
    }
    settings::save_regional_at(
        &path,
        RegionalPreferences {
            time_zone: Some("UTC".into()),
            currency: Some("JPY".into()),
        },
        None,
    )
    .await
    .unwrap();
    settings::save_at(
        &path,
        Some("zh".into()),
        Some("dark".into()),
        Some("en_GB".into()),
        None,
    )
    .await
    .unwrap();
    let current = config::load(&path).unwrap();
    assert_eq!(current.time_zone.as_deref(), Some("UTC"));
    assert_eq!(current.currency.as_deref(), Some("JPY"));
    assert_eq!(current.language.as_deref(), Some("zh"));
    assert!(current
        .pending_settings_audit
        .iter()
        .any(|event| event.changed_fields == vec!["time_zone".to_owned(), "currency".to_owned()]));
    for preferences in [
        RegionalPreferences {
            time_zone: Some("Europe/London".into()),
            currency: None,
        },
        RegionalPreferences {
            time_zone: None,
            currency: Some("usd".into()),
        },
    ] {
        let before = std::fs::read(&path).unwrap();
        assert!(settings::save_regional_at(&path, preferences, None)
            .await
            .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), before);
    }
    let pool = data::open(&dir.join("main.db")).await.unwrap();
    rust_lib_keel::services::access::init(&pool).await.unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log")
        .fetch_one(&pool)
        .await
        .unwrap();
    settings::flush_pending_at(&path, &pool).await.unwrap();
    let replay_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, replay_count);
    assert!(config::load(&path)
        .unwrap()
        .pending_settings_audit
        .is_empty());
    settings::save_regional_at(&path, RegionalPreferences::default(), Some(&pool))
        .await
        .unwrap();
    let cleared = config::load(&path).unwrap();
    assert_eq!(cleared.time_zone, None);
    assert_eq!(cleared.currency, None);
    assert_eq!(cleared.language.as_deref(), Some("zh"));
    assert_eq!(cleared.format_locale.as_deref(), Some("en_GB"));
    settings::import_external_config_at_with_pool(
        &path,
        br#"{"version":5,"language":"en","time_zone":"UTC","currency":"EUR"}"#,
        Some(&pool),
    )
    .await
    .unwrap();
    let imported = config::load(&path).unwrap();
    assert_eq!(imported.time_zone.as_deref(), Some("UTC"));
    assert_eq!(imported.currency.as_deref(), Some("EUR"));
    assert_eq!(imported.language.as_deref(), Some("en"));
    assert!(settings::import_external_config_at_with_pool(
        &path,
        br#"{"version":5,"time_zone":"Europe/London","currency":"EUR"}"#,
        Some(&pool),
    )
    .await
    .is_err());
    let rejected = config::load(&path).unwrap();
    assert_eq!(rejected.time_zone, imported.time_zone);
    assert_eq!(rejected.currency, imported.currency);
    pool.close().await;
    remove_test_dir(&dir);
}
