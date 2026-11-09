//! 单独测试进程：验证准备失败不发布状态，修复后并发重试只初始化一次。

use rust_lib_keel::{api::app, data, services::access, state};

#[tokio::test]
async fn failed_start_can_retry_without_publishing_a_partial_pool() {
    let none = app::StartupRestoreStatus {
        outcome: "none".into(),
        error_code: None,
        correlation_id: None,
    };
    assert_eq!(app::startup_restore_status(), none);
    assert_eq!(app::startup_restore_status(), none);
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("keel-startup-{}-{nonce}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    // SAFETY: 本集成测试二进制只跑这一个测试，写入发生在启动连接池/其他线程之前。
    unsafe { std::env::set_var("KEEL_DATA_DIR", &dir) };
    let path = dir.join("keel.db");
    let pool = data::open(&path).await.unwrap();
    sqlx::query(
        "CREATE TRIGGER fail_start BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'app.start' \
         BEGIN SELECT RAISE(ABORT, 'simulated startup write failure'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    pool.close().await;

    assert!(app::init_database().await.is_err());
    assert!(!app::app_status().database_ready);
    assert!(state::pool().is_err());
    assert!(access::current().is_err());
    assert_eq!(app::startup_restore_status(), none);

    let pool = data::open(&path).await.unwrap();
    sqlx::query("DROP TRIGGER fail_start")
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
    let (first, second) = tokio::join!(app::init_database(), app::init_database());
    first.unwrap();
    second.unwrap();
    assert!(app::app_status().database_ready);
    assert_eq!(access::current().unwrap().name, "local");
    let starts: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM audit_log WHERE action = 'app.start'")
            .fetch_one(state::pool().unwrap())
            .await
            .unwrap();
    assert_eq!(starts, 1);
    assert_eq!(app::startup_restore_status(), none);
    assert_eq!(app::startup_restore_status(), none);
    state::pool().unwrap().close().await;
    // SAFETY: 池已关闭，测试即将结束，无其他线程读取该环境变量。
    unsafe { std::env::remove_var("KEEL_DATA_DIR") };
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
