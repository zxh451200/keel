//! 配置持久化边界测试，不使用环境变量或进程级身份。

use rust_lib_keel::config::{
    self, AppConfig, PendingSettingsAudit, PendingSettingsImportAudit, WorkspaceNavigation,
    CURRENT_VERSION, MAX_CONFIG_BYTES, MAX_PENDING_SETTINGS_AUDIT,
};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

struct TestDir(PathBuf);

impl TestDir {
    fn new(name: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("keel-config-audit-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn event() -> PendingSettingsAudit {
    PendingSettingsAudit {
        id: "S0123456789abcdef0123456789abcdef".into(),
        at: 1_700_000_000_123,
        actor: "配置用户".into(),
        changed_fields: vec!["language".into()],
    }
}

fn with_pending() -> AppConfig {
    AppConfig {
        language: Some("en".into()),
        pending_settings_audit: vec![event()],
        ..AppConfig::default()
    }
}

#[test]
fn import_outbox_is_defaulted_bounded_and_validated_without_version_bump() {
    let dir = TestDir::new("import-outbox");
    let path = dir.0.join("config.json");
    for version in 1..=CURRENT_VERSION {
        std::fs::write(
            &path,
            serde_json::to_vec(&json!({"version": version})).unwrap(),
        )
        .unwrap();
        assert!(config::load(&path)
            .unwrap()
            .pending_settings_import_audit
            .is_empty());
    }
    let import = PendingSettingsImportAudit {
        id: "I0123456789abcdef0123456789abcdef".into(),
        at: 123,
        actor: "original".into(),
        result: "failed:KEEL-IMPORT".into(),
    };
    let mut saved = with_pending();
    saved.pending_settings_import_audit.push(import.clone());
    config::save(&path, &saved).unwrap();
    assert_eq!(config::load(&path).unwrap(), saved);
    let good = std::fs::read(&path).unwrap();
    let mut cases = Vec::new();
    for result in [
        "",
        "failed:PRIVATE_INPUT",
        "changed: language",
        "failed:KEEL-IMPORT\n",
    ] {
        let mut bad = saved.clone();
        bad.pending_settings_import_audit[0].result = result.into();
        cases.push(serde_json::to_value(bad).unwrap());
    }
    let mut duplicate = saved.clone();
    duplicate.pending_settings_import_audit[0].id = event().id;
    cases.push(serde_json::to_value(duplicate).unwrap());
    let mut full = saved.clone();
    full.pending_settings_import_audit = (0..MAX_PENDING_SETTINGS_AUDIT)
        .map(|index| PendingSettingsImportAudit {
            id: format!("I{index:032x}"),
            ..import.clone()
        })
        .collect();
    // 单个队列未超限，但与一条 change 合计超限。
    cases.push(serde_json::to_value(full).unwrap());
    for field in ["id", "at", "actor", "result"] {
        let mut missing = serde_json::to_value(&saved).unwrap();
        missing["pending_settings_import_audit"][0]
            .as_object_mut()
            .unwrap()
            .remove(field);
        cases.push(missing);
    }
    let mut unknown = serde_json::to_value(&saved).unwrap();
    unknown["pending_settings_import_audit"][0]["input"] = json!("PRIVATE_INPUT");
    cases.push(unknown);
    for bad in cases {
        let bytes = serde_json::to_vec(&bad).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        assert_eq!(config::load(&path).unwrap_err().code(), "KEEL-VALIDATION");
        assert!(config::save(&path, &saved).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        std::fs::write(&path, &good).unwrap();
    }
    let mut at_capacity = saved.clone();
    at_capacity.pending_settings_import_audit = (1..MAX_PENDING_SETTINGS_AUDIT)
        .map(|index| PendingSettingsImportAudit {
            id: format!("I{index:032x}"),
            ..import.clone()
        })
        .collect();
    config::save(&path, &at_capacity).unwrap();
    assert_eq!(
        config::load(&path).unwrap().pending_audit_len(),
        MAX_PENDING_SETTINGS_AUDIT
    );
    assert_only_config(&dir.0);
}

fn assert_only_config(dir: &Path) {
    // 枚举整个目录，覆盖 config.json.<随机后缀>.tmp，而非只查旧固定 tmp。
    let names: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert_eq!(names, [std::ffi::OsString::from("config.json")]);
}

#[test]
fn v1_migrates_without_inventing_pending_and_atomic_saves_leave_no_random_tmp() {
    let dir = TestDir::new("migration");
    let path = dir.0.join("config.json");
    let original = br#"{"version":1,"language":"zh","theme":"dark"}"#;
    std::fs::write(&path, original).unwrap();
    let migrated = config::load(&path).unwrap();
    assert_eq!(CURRENT_VERSION, 5);
    assert_eq!(migrated.version, CURRENT_VERSION);
    assert_eq!(migrated.language.as_deref(), Some("zh"));
    assert_eq!(migrated.theme.as_deref(), Some("dark"));
    assert!(migrated.pending_settings_audit.is_empty());
    assert_eq!(
        migrated.workspace_navigation,
        WorkspaceNavigation::default()
    );
    assert_eq!(std::fs::read(&path).unwrap(), original);
    config::save(&path, &migrated).unwrap();
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(saved["version"], CURRENT_VERSION);
    assert_eq!(config::load(&path).unwrap(), migrated);
    assert_only_config(&dir.0);

    for saved in [with_pending(), AppConfig::default(), with_pending()] {
        config::save(&path, &saved).unwrap();
        assert_eq!(config::load(&path).unwrap(), saved);
        let _: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_only_config(&dir.0);
    }
}

#[tokio::test]
async fn legacy_navigation_migration_only_writes_on_actual_change() {
    use rust_lib_keel::services::settings;

    let dir = TestDir::new("navigation-migration");
    let path = dir.0.join("config.json");
    for version in [1, 2, 3] {
        let mut original = json!({"version": version, "language": "en", "theme": "dark"});
        if version >= 2 {
            original["pending_settings_audit"] = json!([event()]);
        }
        let bytes = serde_json::to_vec(&original).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        let migrated = config::load(&path).unwrap();
        assert_eq!(migrated.version, CURRENT_VERSION);
        assert_eq!(migrated.format_locale, None);
        assert_eq!(
            migrated.workspace_navigation,
            WorkspaceNavigation::default()
        );
        assert!(!migrated.workspace_navigation.nav_collapsed);
        settings::save_navigation_at(&path, WorkspaceNavigation::default())
            .await
            .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), bytes);

        let navigation = WorkspaceNavigation {
            recent_kinds: vec!["audit".into()],
            favorite_kinds: vec!["audit".into(), "future-page_1".into()],
            nav_collapsed: true,
        };
        settings::save_navigation_at(&path, navigation.clone())
            .await
            .unwrap();
        let saved = config::load(&path).unwrap();
        assert_eq!(saved.workspace_navigation, navigation);
        assert_eq!(saved.language, migrated.language);
        assert_eq!(saved.theme, migrated.theme);
        assert_eq!(
            saved.pending_settings_audit,
            migrated.pending_settings_audit
        );
        let json: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(json["version"], CURRENT_VERSION);
        assert_eq!(json["workspace_navigation"]["nav_collapsed"], true);
        assert_only_config(&dir.0);
    }
}

#[tokio::test]
async fn legacy_navigation_defaults_expanded_and_collapsed_only_changes_round_trip() {
    use rust_lib_keel::services::settings;

    let dir = TestDir::new("navigation-collapsed");
    let path = dir.0.join("config.json");
    let original = br#"{"version":3,"workspace_navigation":{"recent_kinds":["audit"],"favorite_kinds":["users"]}}"#;
    std::fs::write(&path, original).unwrap();
    let mut navigation = settings::load_navigation_at(&path).unwrap();
    assert!(!navigation.nav_collapsed);
    assert_eq!(navigation.recent_kinds, ["audit"]);
    assert_eq!(navigation.favorite_kinds, ["users"]);
    settings::save_navigation_at(&path, navigation.clone())
        .await
        .unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), original);

    for collapsed in [true, false] {
        navigation.nav_collapsed = collapsed;
        settings::save_navigation_at(&path, navigation.clone())
            .await
            .unwrap();
        assert_eq!(settings::load_navigation_at(&path).unwrap(), navigation);
        let saved = config::load(&path).unwrap();
        assert_eq!(saved.version, CURRENT_VERSION);
        assert!(saved.pending_settings_audit.is_empty());
        let json: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(json["workspace_navigation"]["nav_collapsed"], collapsed);
        assert_only_config(&dir.0);
    }
}

#[tokio::test]
async fn navigation_validation_boundaries_and_protected_files() {
    use rust_lib_keel::services::settings;

    let dir = TestDir::new("navigation-validation");
    let path = dir.0.join("config.json");
    // 两个列表分别去重，允许交集；接受未知但合法的 kind 并保留顺序。
    let good = WorkspaceNavigation {
        recent_kinds: (0..10).map(|i| format!("{i:064}")).collect(),
        favorite_kinds: (0..50).map(|i| format!("{i:064}")).collect(),
        ..Default::default()
    };
    settings::save_navigation_at(&path, good.clone())
        .await
        .unwrap();
    assert_eq!(settings::load_navigation_at(&path).unwrap(), good);
    let bytes = std::fs::read(&path).unwrap();
    let mut invalid = Vec::new();
    for bad_kind in ["", " ", "a/b", "a.b", "a\n", "中文", "é"] {
        invalid.push(vec![bad_kind.to_string()]);
    }
    invalid.push(vec!["x".repeat(65)]);
    invalid.push(vec!["duplicate".into(), "duplicate".into()]);
    for kinds in invalid {
        for favorites in [false, true] {
            let bad = if favorites {
                WorkspaceNavigation {
                    favorite_kinds: kinds.clone(),
                    ..Default::default()
                }
            } else {
                WorkspaceNavigation {
                    recent_kinds: kinds.clone(),
                    ..Default::default()
                }
            };
            assert_eq!(
                settings::save_navigation_at(&path, bad.clone())
                    .await
                    .unwrap_err()
                    .code(),
                "KEEL-VALIDATION"
            );
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            let raw = serde_json::to_vec(&json!({
                "version": 3, "workspace_navigation": bad
            }))
            .unwrap();
            std::fs::write(&path, &raw).unwrap();
            assert!(config::load(&path).is_err());
            assert!(settings::save_navigation_at(&path, good.clone())
                .await
                .is_err());
            assert_eq!(std::fs::read(&path).unwrap(), raw);
            std::fs::write(&path, &bytes).unwrap();
        }
    }
    for (recent, favorite) in [(11, 0), (0, 51)] {
        let bad = WorkspaceNavigation {
            recent_kinds: (0..recent).map(|i| format!("recent-{i}")).collect(),
            favorite_kinds: (0..favorite).map(|i| format!("favorite_{i}")).collect(),
            ..Default::default()
        };
        assert!(settings::save_navigation_at(&path, bad).await.is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
    // 合法的最短 kind、大小写与连接符都不做归一化。
    let short = WorkspaceNavigation {
        recent_kinds: vec!["A".into(), "a".into(), "-".into(), "_".into()],
        favorite_kinds: vec![],
        ..Default::default()
    };
    settings::save_navigation_at(&path, short.clone())
        .await
        .unwrap();
    assert_eq!(settings::load_navigation_at(&path).unwrap(), short);
    for original in [
        b"{ broken".to_vec(),
        serde_json::to_vec(&json!({"version": CURRENT_VERSION + 1})).unwrap(),
        br#"{"version":0}"#.to_vec(),
        br#"{"version":3,"workspace_navigation":null}"#.to_vec(),
        br#"{"version":3,"workspace_navigation":{"recent_kinds":"audit"}}"#.to_vec(),
        serde_json::to_vec(&json!({"version":3, "padding":"x".repeat(MAX_CONFIG_BYTES as usize)}))
            .unwrap(),
    ] {
        std::fs::write(&path, &original).unwrap();
        assert!(settings::load_navigation_at(&path).is_err());
        assert_eq!(
            settings::save_navigation_at(&path, good.clone())
                .await
                .unwrap_err()
                .code(),
            "KEEL-VALIDATION"
        );
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert_only_config(&dir.0);
    }
    let missing = dir.0.join("missing.json");
    settings::save_navigation_at(&missing, WorkspaceNavigation::default())
        .await
        .unwrap();
    assert!(!missing.exists(), "默认导航无变化时不创建文件");
}

#[test]
fn malformed_or_unknown_pending_fields_reject_read_and_overwrite() {
    let dir = TestDir::new("malformed");
    let path = dir.0.join("config.json");
    let valid = serde_json::to_value(with_pending()).unwrap();
    let mut cases = vec![
        json!({"version":2,"pending_settings_audit":null}),
        json!({"version":2,"pending_settings_audit":{}}),
        json!({"version":2,"pending_settings_audit":[{}]}),
    ];
    for field in ["id", "at", "actor", "changed_fields"] {
        let mut missing = valid.clone();
        missing["pending_settings_audit"][0]
            .as_object_mut()
            .unwrap()
            .remove(field);
        cases.push(missing);
    }
    for (field, value) in [
        ("at", json!("yesterday")),
        ("actor", json!(123)),
        ("changed_fields", json!("language")),
        ("values", json!({"language":"en"})),
        ("private_snapshot", json!("PRIVATE_CONFIG_CONTENT")),
    ] {
        let mut bad = valid.clone();
        bad["pending_settings_audit"][0][field] = value;
        cases.push(bad);
    }
    for bad in cases {
        let original = serde_json::to_vec(&bad).unwrap();
        std::fs::write(&path, &original).unwrap();
        assert_eq!(config::load(&path).unwrap_err().code(), "KEEL-VALIDATION");
        assert_eq!(
            config::save(&path, &AppConfig::default())
                .unwrap_err()
                .code(),
            "KEEL-VALIDATION"
        );
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert_only_config(&dir.0);
    }
}

#[test]
fn invalid_pending_is_rejected_on_read_and_save_without_touching_good_file() {
    let dir = TestDir::new("invalid");
    let path = dir.0.join("config.json");
    let mut invalid = Vec::new();
    for actor in [
        "".to_string(),
        "   ".into(),
        "x\nname".into(),
        "用".repeat(33),
    ] {
        let mut bad = with_pending();
        bad.pending_settings_audit[0].actor = actor;
        invalid.push(bad);
    }
    for id in [
        "short".into(),
        "x".repeat(129),
        format!("{}!", "x".repeat(32)),
    ] {
        let mut bad = with_pending();
        bad.pending_settings_audit[0].id = id;
        invalid.push(bad);
    }
    for fields in [
        vec![],
        vec!["password"],
        vec!["language", "language"],
        vec!["theme", "theme"],
        vec!["language", "theme", "language"],
        vec!["format_locale", "format_locale"],
        vec!["language", "format_locale", "format_locale"],
        vec!["language", "theme", "format_locale", "language"],
    ] {
        let mut bad = with_pending();
        bad.pending_settings_audit[0].changed_fields =
            fields.into_iter().map(str::to_owned).collect();
        invalid.push(bad);
    }
    let mut negative_time = with_pending();
    negative_time.pending_settings_audit[0].at = -1;
    invalid.push(negative_time);
    let mut duplicate = with_pending();
    duplicate.pending_settings_audit.push(event());
    invalid.push(duplicate);
    let mut over_capacity = with_pending();
    over_capacity.pending_settings_audit = (0..201)
        .map(|index| PendingSettingsAudit {
            id: format!("S{index:032x}"),
            ..event()
        })
        .collect();
    invalid.push(over_capacity);

    let good = serde_json::to_vec(&AppConfig::default()).unwrap();
    for bad in invalid {
        std::fs::write(&path, &good).unwrap();
        assert_eq!(
            config::save(&path, &bad).unwrap_err().code(),
            "KEEL-VALIDATION"
        );
        assert_eq!(std::fs::read(&path).unwrap(), good);
        let original = serde_json::to_vec(&bad).unwrap();
        std::fs::write(&path, &original).unwrap();
        assert_eq!(config::load(&path).unwrap_err().code(), "KEEL-VALIDATION");
        assert_eq!(
            config::save(&path, &AppConfig::default())
                .unwrap_err()
                .code(),
            "KEEL-VALIDATION"
        );
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert_only_config(&dir.0);
    }
}

#[test]
fn oversized_json_cannot_be_read_or_overwritten() {
    let dir = TestDir::new("oversized");
    let path = dir.0.join("config.json");
    // 合法 JSON + 顶层兼容字段；拒绝原因应当是体积，不是语法错误。
    let original = serde_json::to_vec(&json!({
        "version": CURRENT_VERSION, "padding": "x".repeat(MAX_CONFIG_BYTES as usize)
    }))
    .unwrap();
    assert!(original.len() as u64 > MAX_CONFIG_BYTES);
    std::fs::write(&path, &original).unwrap();
    assert_eq!(config::load(&path).unwrap_err().code(), "KEEL-VALIDATION");
    assert_eq!(
        config::save(&path, &with_pending()).unwrap_err().code(),
        "KEEL-VALIDATION"
    );
    assert_eq!(std::fs::read(&path).unwrap(), original);
    assert_only_config(&dir.0);
}

#[test]
fn legacy_format_locale_migration_preserves_preferences_pending_and_source() {
    let dir = TestDir::new("format-migration");
    let path = dir.0.join("config.json");
    for version in 1..=3 {
        let mut source = json!({
            "version": version, "language": "zh", "theme": "dark",
            "pending_settings_audit": [event()],
            "workspace_navigation": {
                "recent_kinds": ["audit"], "favorite_kinds": ["users"],
                "nav_collapsed": true
            }
        });
        // 即使旧版含未知的新字段，也不能把它当作独立区域偏好。
        for locale in [None, Some("en_GB")] {
            if let Some(locale) = locale {
                source["format_locale"] = json!(locale);
            }
            let bytes = serde_json::to_vec(&source).unwrap();
            std::fs::write(&path, &bytes).unwrap();
            let migrated = config::load(&path).unwrap();
            assert_eq!(migrated.version, CURRENT_VERSION);
            assert_eq!(migrated.format_locale, None);
            assert_eq!(migrated.language.as_deref(), Some("zh"));
            assert_eq!(migrated.theme.as_deref(), Some("dark"));
            assert_eq!(migrated.pending_settings_audit, [event()]);
            assert_eq!(migrated.workspace_navigation.recent_kinds, ["audit"]);
            assert_eq!(migrated.workspace_navigation.favorite_kinds, ["users"]);
            assert!(migrated.workspace_navigation.nav_collapsed);
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
            config::save(&path, &migrated).unwrap();
            assert_eq!(config::load(&path).unwrap(), migrated);
        }
    }
}

#[test]
fn v4_format_locale_round_trip_and_invalid_values_protect_existing_config() {
    let dir = TestDir::new("format-values");
    let path = dir.0.join("config.json");
    for locale in [None, Some("en_US"), Some("en_GB"), Some("zh_CN")] {
        let mut saved = with_pending();
        saved.format_locale = locale.map(str::to_owned);
        saved.pending_settings_audit[0].changed_fields =
            vec!["language".into(), "theme".into(), "format_locale".into()];
        config::save(&path, &saved).unwrap();
        assert_eq!(config::load(&path).unwrap(), saved);
        let json: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(json["version"], CURRENT_VERSION);
        assert_eq!(json["format_locale"], json!(locale));
    }
    let original = std::fs::read(&path).unwrap();
    for value in [
        json!(""),
        json!("en"),
        json!("en-US"),
        json!("en_us"),
        json!("fr_FR"),
        json!(" en_GB"),
        json!("zh_CN\n"),
        json!(42),
        json!(true),
        json!([]),
        json!({}),
    ] {
        let mut bad = serde_json::from_slice::<Value>(&original).unwrap();
        bad["format_locale"] = value;
        let bytes = serde_json::to_vec(&bad).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        assert_eq!(config::load(&path).unwrap_err().code(), "KEEL-VALIDATION");
        assert_eq!(
            config::save(&path, &AppConfig::default())
                .unwrap_err()
                .code(),
            "KEEL-VALIDATION"
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
    }
    std::fs::write(&path, &original).unwrap();
    let bad = AppConfig {
        format_locale: Some("en-US".into()),
        ..AppConfig::default()
    };
    assert_eq!(
        config::save(&path, &bad).unwrap_err().code(),
        "KEEL-VALIDATION"
    );
    assert_eq!(std::fs::read(&path).unwrap(), original);
    let future = serde_json::to_vec(&json!({"version": CURRENT_VERSION + 1})).unwrap();
    std::fs::write(&path, &future).unwrap();
    assert!(config::save(&path, &AppConfig::default()).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), future);
}
