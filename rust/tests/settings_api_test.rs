//! 设置 API 端到端：用 KEEL_DATA_DIR 把数据目录指到临时目录。
//! 环境变量是进程级的，所以所有断言放在同一个测试里顺序执行。

use rust_lib_keel::api::settings::{
    import_prepared_external_config, load_settings, load_workspace_navigation_preferences,
    prepare_external_config, prepare_external_config_file, save_settings,
    save_workspace_navigation_preferences, Settings, WorkspaceNavigationPreferences,
};
use rust_lib_keel::config::{self, MAX_CONFIG_BYTES};
use rust_lib_keel::diagnostics::events::{self, Level};
use rust_lib_keel::domain::permissions::Role;
use rust_lib_keel::services::access::{self, CurrentUser};

#[tokio::test]
async fn settings_round_trip_and_error_mapping() {
    access::set_current(CurrentUser {
        name: "settings-api-admin".into(),
        role: Role::Admin,
    });
    let dir = std::env::temp_dir().join(format!("keel-settings-api-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let previous_dir = std::env::var_os("KEEL_DATA_DIR");
    std::env::set_var("KEEL_DATA_DIR", &dir);

    // 没有文件：默认值。
    let initial = load_settings().unwrap();
    assert_eq!(initial.language, None);
    assert_eq!(initial.theme, None);
    assert_eq!(initial.format_locale, None);
    let initial_navigation = load_workspace_navigation_preferences().unwrap();
    assert!(initial_navigation.recent_kinds.is_empty());
    assert!(initial_navigation.favorite_kinds.is_empty());
    assert!(!initial_navigation.nav_collapsed);
    save_workspace_navigation_preferences(initial_navigation)
        .await
        .unwrap();
    assert!(!dir.join("config.json").exists());

    // 保存后能读回来，文件落在数据目录下。
    save_settings(Settings {
        language: Some("en".into()),
        theme: Some("dark".into()),
        format_locale: Some("en_GB".into()),
    })
    .await
    .unwrap();
    assert!(dir.join("config.json").is_file());
    let loaded = load_settings().unwrap();
    assert_eq!(loaded.language.as_deref(), Some("en"));
    assert_eq!(loaded.theme.as_deref(), Some("dark"));
    assert_eq!(loaded.format_locale.as_deref(), Some("en_GB"));

    let navigation = WorkspaceNavigationPreferences {
        recent_kinds: vec!["users".into(), "audit".into()],
        favorite_kinds: vec!["audit".into()],
        nav_collapsed: true,
    };
    save_workspace_navigation_preferences(navigation.clone())
        .await
        .unwrap();
    assert_eq!(load_workspace_navigation_preferences().unwrap(), navigation);
    let persisted: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.join("config.json")).unwrap()).unwrap();
    assert_eq!(persisted["workspace_navigation"]["nav_collapsed"], true);
    let loaded = load_settings().unwrap();
    assert_eq!(loaded.language.as_deref(), Some("en"));
    assert_eq!(loaded.theme.as_deref(), Some("dark"));
    assert_eq!(loaded.format_locale.as_deref(), Some("en_GB"));
    let unchanged = std::fs::read(dir.join("config.json")).unwrap();
    save_workspace_navigation_preferences(navigation.clone())
        .await
        .unwrap();
    assert_eq!(std::fs::read(dir.join("config.json")).unwrap(), unchanged);
    let error = save_workspace_navigation_preferences(WorkspaceNavigationPreferences {
        recent_kinds: vec!["bad/path".into()],
        favorite_kinds: vec![],
        nav_collapsed: false,
    })
    .await
    .unwrap_err();
    assert_eq!(error.code, "KEEL-VALIDATION");
    assert!(!error.correlation_id.is_empty());
    assert_eq!(std::fs::read(dir.join("config.json")).unwrap(), unchanged);

    // 非法取值：返回稳定错误码，且不改动已有文件。
    let before = std::fs::read_to_string(dir.join("config.json")).unwrap();
    let err = save_settings(Settings {
        language: Some("fr".into()),
        theme: None,
        format_locale: None,
    })
    .await
    .unwrap_err();
    assert_eq!(err.code, "KEEL-VALIDATION");
    assert!(!err.correlation_id.is_empty());
    assert_eq!(
        std::fs::read_to_string(dir.join("config.json")).unwrap(),
        before
    );

    for locale in ["", "en-US", "en_us", "fr_FR", " en_GB", "zh_CN\n"] {
        let error = save_settings(Settings {
            language: Some("en".into()),
            theme: Some("dark".into()),
            format_locale: Some(locale.into()),
        })
        .await
        .unwrap_err();
        assert_eq!(error.code, "KEEL-VALIDATION");
        assert!(!error.correlation_id.is_empty());
        assert_eq!(
            std::fs::read_to_string(dir.join("config.json")).unwrap(),
            before
        );
    }

    // 损坏和未来版本：读、写都必须拒绝，原文件逐字节保留。
    for original in ["{ broken", r#"{"version":99,"language":"en"}"#] {
        std::fs::write(dir.join("config.json"), original).unwrap();
        assert_eq!(load_settings().unwrap_err().code, "KEEL-VALIDATION");
        assert_eq!(
            load_workspace_navigation_preferences().unwrap_err().code,
            "KEEL-VALIDATION"
        );
        let error = save_workspace_navigation_preferences(navigation.clone())
            .await
            .unwrap_err();
        assert_eq!(error.code, "KEEL-VALIDATION");
        assert!(!error.correlation_id.is_empty());
        let err = save_settings(Settings {
            language: Some("zh".into()),
            theme: Some("light".into()),
            format_locale: None,
        })
        .await
        .unwrap_err();
        assert_eq!(err.code, "KEEL-VALIDATION");
        assert!(!err.correlation_id.is_empty());
        assert_eq!(
            std::fs::read(dir.join("config.json")).unwrap(),
            original.as_bytes()
        );
    }

    // 外部配置只合并允许的偏好，不能伪造或清空本机待写审计队列。
    let external = br#"{
        "version": 4,
        "language": "zh",
        "theme": "light",
        "format_locale": "zh_CN",
        "pending_settings_audit": [],
        "pending_settings_import_audit": [],
        "workspace_navigation": {
            "recent_kinds": ["diagnostics"],
            "favorite_kinds": ["users"],
            "nav_collapsed": false
        }
    }"#;
    std::fs::write(
        dir.join("config.json"),
        r#"{
            "version": 3,
            "language": "en",
            "theme": "dark",
            "pending_settings_audit": [{
                "id": "S00000000000000000000000000000000",
                "at": 1,
                "actor": "admin",
                "changed_fields": ["theme"]
            }]
        }"#,
    )
    .unwrap();
    let before_preview = std::fs::read(dir.join("config.json")).unwrap();
    let preview = prepare_external_config(external.to_vec()).unwrap();
    assert!(!preview.preview_id.is_empty());
    assert_eq!(
        std::fs::read(dir.join("config.json")).unwrap(),
        before_preview
    );
    import_prepared_external_config(preview.preview_id.clone())
        .await
        .unwrap();
    let imported: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.join("config.json")).unwrap()).unwrap();
    assert_eq!(imported["language"], "zh");
    assert_eq!(imported["theme"], "light");
    assert_eq!(imported["format_locale"], "zh_CN");
    assert_eq!(
        load_settings().unwrap().format_locale.as_deref(),
        Some("zh_CN")
    );
    assert_eq!(
        imported["workspace_navigation"]["recent_kinds"][0],
        "diagnostics"
    );
    assert_eq!(
        imported["pending_settings_audit"].as_array().unwrap().len(),
        1
    );
    let saved = std::fs::read(dir.join("config.json")).unwrap();
    let error = import_prepared_external_config(preview.preview_id)
        .await
        .unwrap_err();
    assert_eq!(error.code, "KEEL-IMPORT");
    assert_import_failure_recorded(&dir.join("config.json"), &saved);
    let error = prepare_external_config(br#"{"version":3,"command":"run"}"#.to_vec()).unwrap_err();
    assert_eq!(error.code, "KEEL-IMPORT");

    // 确认期间目标配置损坏：保护原文件，失败的句柄也不能再次使用。
    let retry_preview = prepare_external_config(external.to_vec()).unwrap();
    std::fs::write(dir.join("config.json"), b"{ broken target").unwrap();
    let error = import_prepared_external_config(retry_preview.preview_id.clone())
        .await
        .unwrap_err();
    assert_eq!(error.code, "KEEL-VALIDATION");
    assert_eq!(
        std::fs::read(dir.join("config.json")).unwrap(),
        b"{ broken target"
    );
    std::fs::write(dir.join("config.json"), &saved).unwrap();
    let error = import_prepared_external_config(retry_preview.preview_id)
        .await
        .unwrap_err();
    assert_eq!(error.code, "KEEL-IMPORT");
    assert_import_failure_recorded(&dir.join("config.json"), &saved);
    let saved = std::fs::read(dir.join("config.json")).unwrap();

    // 文件 prepare 只读，确认导入同一次字节快照，源文件之后改变/删除均不影响。
    let source = dir.join("PRIVATE_SOURCE.json");
    std::fs::write(&source, external).unwrap();
    let source_path = source.to_str().unwrap().to_string();
    let original_permissions = std::fs::metadata(&source).unwrap().permissions();
    let mut readonly_permissions = original_permissions.clone();
    readonly_permissions.set_readonly(true);
    std::fs::set_permissions(&source, readonly_permissions).unwrap();
    let file_preview = prepare_external_config_file(source_path.clone()).unwrap();
    assert_eq!(std::fs::read(dir.join("config.json")).unwrap(), saved);
    assert_eq!(std::fs::read(&source).unwrap(), external);
    assert!(std::fs::metadata(&source).unwrap().permissions().readonly());
    std::fs::set_permissions(&source, original_permissions).unwrap();
    std::fs::write(&source, br#"{"version":4,"language":"en"}"#).unwrap();
    import_prepared_external_config(file_preview.preview_id.clone())
        .await
        .unwrap();
    assert_eq!(load_settings().unwrap().language.as_deref(), Some("zh"));
    assert_eq!(
        import_prepared_external_config(file_preview.preview_id)
            .await
            .unwrap_err()
            .code,
        "KEEL-IMPORT"
    );
    let file_preview = prepare_external_config_file(source_path.clone()).unwrap();
    std::fs::remove_file(&source).unwrap();
    import_prepared_external_config(file_preview.preview_id)
        .await
        .unwrap();
    assert_eq!(load_settings().unwrap().language.as_deref(), Some("en"));
    let untouched = std::fs::read(dir.join("config.json")).unwrap();
    // 恰好 1 MiB 的合法源走完 prepare + confirm；外部空白和队列不落本地。
    let mut at_limit = external.to_vec();
    at_limit.resize(MAX_CONFIG_BYTES as usize, b' ');
    assert_eq!(at_limit.len() as u64, MAX_CONFIG_BYTES);
    let local_path = dir.join("config.json");
    let before_limit = config::load(&local_path).unwrap();
    std::fs::write(&source, &at_limit).unwrap();
    let limit_preview = prepare_external_config_file(source_path.clone()).unwrap();
    assert!(!limit_preview.preview_id.is_empty());
    assert!(limit_preview.preview.chars().count() <= 16_000);
    assert_eq!(std::fs::read(&source).unwrap(), at_limit);
    assert_eq!(std::fs::read(dir.join("config.json")).unwrap(), untouched);
    assert!(
        rust_lib_keel::state::pool().is_err(),
        "本用例要求无全局池以验证成功事件落盘"
    );
    let started = rust_lib_keel::services::audit::now_ms();
    import_prepared_external_config(limit_preview.preview_id)
        .await
        .unwrap();
    let finished = rust_lib_keel::services::audit::now_ms();
    let output = std::fs::read(&local_path).unwrap();
    assert!(output.len() as u64 <= MAX_CONFIG_BYTES);
    assert!(
        output.len() < at_limit.len() / 2,
        "外部填充空白不得复制到本机配置"
    );
    assert!(!output
        .windows(128)
        .any(|window| window.iter().all(|byte| *byte == b' ')));
    assert_eq!(std::fs::read(&source).unwrap(), at_limit, "确认不改源文件");
    let mut after_limit = config::load(&local_path).unwrap();
    assert_eq!(
        after_limit.pending_settings_audit,
        before_limit.pending_settings_audit
    );
    assert_eq!(
        after_limit.pending_settings_import_audit.len(),
        before_limit.pending_settings_import_audit.len() + 1
    );
    assert!(after_limit
        .pending_settings_import_audit
        .starts_with(&before_limit.pending_settings_import_audit));
    // 本 API 测试不发布全局池，成功事件必须留在磁盘供启动补写。
    let event = after_limit.pending_settings_import_audit.pop().unwrap();
    event.validate().unwrap();
    assert_eq!(event.result, "ok");
    assert_eq!(event.actor, "settings-api-admin");
    assert!((started..=finished).contains(&event.at));
    assert!(!before_limit
        .pending_settings_import_audit
        .iter()
        .any(|old| old.id == event.id));
    let imported_preferences: config::AppConfig = serde_json::from_slice(external).unwrap();
    let mut expected = before_limit;
    expected.language = imported_preferences.language;
    expected.theme = imported_preferences.theme;
    expected.format_locale = imported_preferences.format_locale;
    expected.workspace_navigation = imported_preferences.workspace_navigation;
    assert_eq!(
        after_limit, expected,
        "只能合并允许的偏好并追加本机成功事件"
    );
    assert_eq!(load_settings().unwrap().language.as_deref(), Some("zh"));
    assert_eq!(
        load_settings().unwrap().format_locale.as_deref(),
        Some("zh_CN")
    );
    let untouched = output;
    std::fs::remove_file(&source).unwrap();
    #[cfg(target_os = "linux")]
    {
        let target = dir.join("link-target.json");
        let link = dir.join("link.json");
        std::fs::write(&target, external).unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert_eq!(
            prepare_external_config_file(link.to_str().unwrap().to_string())
                .unwrap_err()
                .code,
            "KEEL-IMPORT"
        );
        assert_eq!(std::fs::read(dir.join("config.json")).unwrap(), untouched);
        std::fs::remove_file(link).unwrap();
        std::fs::remove_file(target).unwrap();
    }

    for invalid_path in [
        "relative.json".to_string(),
        dir.to_str().unwrap().to_string(),
        source_path.clone(), // 不存在
        r"\\server\share\config.json".to_string(),
        r"\\.\NUL".to_string(),
        r"\\?\UNC\server\share\config.json".to_string(),
    ] {
        let error = prepare_external_config_file(invalid_path).unwrap_err();
        assert_eq!(error.code, "KEEL-IMPORT");
        assert!(!error.correlation_id.is_empty());
        assert!(!error.message.contains("PRIVATE_SOURCE"));
    }
    for invalid in [
        vec![b'x'; 1024 * 1024 + 1],
        vec![0xff, 0xfe],
        b"{ PRIVATE_INPUT".to_vec(),
        br#"{"version":99}"#.to_vec(),
        br#"{"version":4,"unknown":"PRIVATE_INPUT"}"#.to_vec(),
    ] {
        std::fs::write(&source, invalid).unwrap();
        let error = prepare_external_config_file(source_path.clone()).unwrap_err();
        assert_eq!(error.code, "KEEL-IMPORT");
        assert!(!error.message.contains("PRIVATE_INPUT"));
        assert!(!error.message.contains("PRIVATE_SOURCE"));
        // API 错误转换同时写诊断缓冲；不能只检查返回给 UI 的 message。
        let recorded = events::recent(500, Level::Error);
        let event = recorded
            .iter()
            .find(|event| event.correlation_id == error.correlation_id)
            .unwrap();
        assert!(!event.summary.contains("PRIVATE_INPUT"));
        assert!(!event.summary.contains("PRIVATE_SOURCE"));
        assert!(!event.summary.contains(source.to_string_lossy().as_ref()));
        assert_eq!(std::fs::read(dir.join("config.json")).unwrap(), untouched);
    }
    std::fs::write(&source, external).unwrap();
    let owned = prepare_external_config_file(source_path.clone()).unwrap();
    for (name, role) in [
        ("other-admin", Role::Admin),
        ("settings-api-admin", Role::Operator),
        ("settings-api-admin", Role::Viewer),
    ] {
        access::set_current(CurrentUser {
            name: name.into(),
            role,
        });
        let before = std::fs::read(dir.join("config.json")).unwrap();
        assert_eq!(
            import_prepared_external_config(owned.preview_id.clone())
                .await
                .unwrap_err()
                .code,
            "KEEL-PERMISSION"
        );
        assert_import_failure_recorded(&dir.join("config.json"), &before);
    }
    // 无权限且源文件不存在时仍返回权限错误，读取路径前即拒绝。
    std::fs::remove_file(&source).unwrap();
    assert_eq!(
        prepare_external_config_file(source_path).unwrap_err().code,
        "KEEL-PERMISSION"
    );
    access::set_current(CurrentUser {
        name: "settings-api-admin".into(),
        role: Role::Admin,
    });
    import_prepared_external_config(owned.preview_id)
        .await
        .unwrap();
    assert_eq!(load_settings().unwrap().language.as_deref(), Some("zh"));

    // 相对路径的数据目录被拒绝。
    std::env::set_var("KEEL_DATA_DIR", "relative/dir");
    assert_eq!(load_settings().unwrap_err().code, "KEEL-VALIDATION");
    assert_eq!(
        load_workspace_navigation_preferences().unwrap_err().code,
        "KEEL-VALIDATION"
    );
    assert_eq!(
        save_workspace_navigation_preferences(navigation)
            .await
            .unwrap_err()
            .code,
        "KEEL-VALIDATION"
    );
    assert_eq!(
        save_settings(Settings {
            language: None,
            theme: None,
            format_locale: None
        })
        .await
        .unwrap_err()
        .code,
        "KEEL-VALIDATION"
    );

    match previous_dir {
        Some(value) => std::env::set_var("KEEL_DATA_DIR", value),
        None => std::env::remove_var("KEEL_DATA_DIR"),
    }
    remove_test_dir(&dir);
}

fn assert_import_failure_recorded(path: &std::path::Path, before: &[u8]) {
    use rust_lib_keel::config::{self, AppConfig};
    let mut old: AppConfig = serde_json::from_slice(before).unwrap();
    let mut new = config::load(path).unwrap();
    assert_eq!(
        new.pending_settings_import_audit.len(),
        old.pending_settings_import_audit.len() + 1
    );
    assert!(new
        .pending_settings_import_audit
        .starts_with(&old.pending_settings_import_audit));
    assert!(new
        .pending_settings_import_audit
        .last()
        .unwrap()
        .result
        .starts_with("failed:"));
    old.pending_settings_import_audit.clear();
    new.pending_settings_import_audit.clear();
    assert_eq!(new, old, "失败结果不能改变偏好或本机 settings.change 队列");
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
