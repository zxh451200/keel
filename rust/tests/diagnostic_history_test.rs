//! Separate process: the environment and CURRENT are not shared with other test binaries.
use rust_lib_keel::api::diagnostics::{search_diagnostic_history, DiagnosticHistoryQuery};
use rust_lib_keel::domain::permissions::Role;
use rust_lib_keel::services::access::{self, CurrentUser};
use rust_lib_keel::{data, state};

#[tokio::test]
async fn real_api_uses_only_app_logs_and_existing_diagnostic_permission() {
    let dir = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("keel-history-api-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("logs")).unwrap();
    let previous = std::env::var_os("KEEL_DATA_DIR");
    std::env::set_var("KEEL_DATA_DIR", &dir);
    let db = dir.join("main.db");
    let pool = data::open(&db).await.unwrap();
    state::set_db_path(&db);
    state::set_pool(pool.clone());
    let log = dir.join("logs/keel.log.2026-11-02");
    std::fs::write(&log, "INFO history password=api-secret K-history\n").unwrap();
    // A lookalike outside logs is never selected.
    std::fs::write(dir.join("keel.log.2026-11-03"), "outside-marker\n").unwrap();
    for role in [Role::Admin, Role::Operator] {
        access::set_current(CurrentUser {
            name: "owner".into(),
            role,
        });
        let page = search_diagnostic_history(DiagnosticHistoryQuery {
            text: "K-history".into(),
        })
        .await
        .unwrap();
        assert_eq!(page.lines, ["INFO history password=*** K-history"]);
        assert_eq!(page.scanned_files, 1);
        assert!(!page.truncated);
        assert!(search_diagnostic_history(DiagnosticHistoryQuery {
            text: "api-secret".into()
        })
        .await
        .unwrap()
        .lines
        .is_empty());
    }
    access::set_current(CurrentUser {
        name: "reader".into(),
        role: Role::Viewer,
    });
    // Break the directory: permission denial must happen before touching files.
    std::fs::remove_file(&log).unwrap();
    std::fs::remove_dir(dir.join("logs")).unwrap();
    std::fs::write(dir.join("logs"), "not a directory").unwrap();
    assert_eq!(
        search_diagnostic_history(DiagnosticHistoryQuery {
            text: String::new()
        })
        .await
        .unwrap_err()
        .code,
        "KEEL-PERMISSION"
    );
    if let Some(value) = previous {
        std::env::set_var("KEEL_DATA_DIR", value);
    } else {
        std::env::remove_var("KEEL_DATA_DIR");
    }
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
    std::fs::remove_dir_all(path).unwrap();
}
