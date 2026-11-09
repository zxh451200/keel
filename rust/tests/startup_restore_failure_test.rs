//! 独立进程：恢复失败后仍启动原 SQLite，公开结果与诊断事件共享定位信息。

use rust_lib_keel::{
    api::app,
    data,
    diagnostics::events::{self, Level},
    services::{access, backup},
    state,
};

#[tokio::test]
async fn failed_restore_keeps_original_database_and_event_identity() {
    assert_eq!(app::startup_restore_status().outcome, "none");
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "keel-restore-failure-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::env::set_var("KEEL_DATA_DIR", &dir);
    let path = dir.join("keel.db");
    let pool = data::open(&path).await.unwrap();
    data::audit::insert(&pool, 1, "local", "test.original", "keel", "ok", "")
        .await
        .unwrap();
    pool.close().await;
    let name = "keel-1730000000001.db";
    // 合法名字但文件不存在：真实恢复分支失败，原数据库应仍能正常启动。
    std::fs::write(backup::marker_path(&path), name).unwrap();
    app::init_database().await.unwrap();
    assert!(app::app_status().database_ready);
    assert_eq!(access::current().unwrap().name, "local");
    assert!(!backup::marker_path(&path).exists());
    let failed = app::startup_restore_status();
    assert_eq!(failed.outcome, "failed");
    assert_eq!(failed.error_code.as_deref(), Some("KEEL-NOT-FOUND"));
    assert!(!failed.correlation_id.as_ref().unwrap().is_empty());
    let events = events::recent(events::CAPACITY, Level::Error);
    let startup_events: Vec<_> = events
        .iter()
        .filter(|event| event.area == "startup")
        .collect();
    assert_eq!(startup_events.len(), 1);
    let event = startup_events[0];
    assert_eq!(failed.error_code.as_deref(), Some(event.code.as_str()));
    assert_eq!(
        failed.correlation_id.as_deref(),
        Some(event.correlation_id.as_str()),
    );
    let public = format!("{failed:?}");
    assert!(!public.contains(name));
    assert!(!public.contains(dir.to_string_lossy().as_ref()));
    assert!(!public.contains(&event.summary));
    assert_eq!(app::startup_restore_status(), failed);
    app::init_database().await.unwrap();
    assert_eq!(app::startup_restore_status(), failed);
    let originals: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM audit_log WHERE action = 'test.original'")
            .fetch_one(state::pool().unwrap())
            .await
            .unwrap();
    assert_eq!(originals, 1);
    state::pool().unwrap().close().await;
    std::env::remove_var("KEEL_DATA_DIR");
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
