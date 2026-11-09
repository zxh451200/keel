//! 独立进程：真实 SQLite 恢复后，数据库打开/用户准备/启动审计失败均保留恢复结论。

use rust_lib_keel::{
    api::app,
    data,
    services::{access, backup},
    state,
};

#[tokio::test]
async fn restored_status_survives_preparation_failures_and_retries() {
    assert_eq!(app::startup_restore_status().outcome, "none");
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "keel-restore-success-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    std::env::set_var("KEEL_DATA_DIR", &dir);
    let path = dir.join("keel.db");
    let backup_dir = backup::backups_dir(&path);
    std::fs::create_dir_all(&backup_dir).unwrap();
    let name = "keel-1730000000000.db";
    // 备份中包含故障触发器；无需发布全局池/用户就能准备真实恢复样本。
    let pool = data::open(&backup_dir.join(name)).await.unwrap();
    let checksum: Vec<u8> =
        sqlx::query_scalar("SELECT checksum FROM _sqlx_migrations WHERE version = 1")
            .fetch_one(&pool)
            .await
            .unwrap();
    // 首先令 data::open 的迁移检查失败，验证恢复结论在打开数据库前已记录。
    sqlx::query("UPDATE _sqlx_migrations SET checksum = X'00' WHERE version = 1")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "CREATE TRIGGER fail_user BEFORE INSERT ON app_user \
         BEGIN SELECT RAISE(ABORT, 'simulated user preparation failure'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        "CREATE TRIGGER fail_start BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'app.start' \
         BEGIN SELECT RAISE(ABORT, 'simulated startup write failure'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
    std::fs::write(backup::marker_path(&path), name).unwrap();

    assert_eq!(
        app::init_database().await.unwrap_err().code,
        "KEEL-DB-MIGRATION"
    );
    assert!(state::pool().is_err());
    assert!(access::current().is_err());
    assert!(!backup::marker_path(&path).exists());
    let restored = app::StartupRestoreStatus {
        outcome: "restored".into(),
        error_code: None,
        correlation_id: None,
    };
    assert_eq!(app::startup_restore_status(), restored);
    assert_eq!(app::startup_restore_status(), restored);

    // 绕过应用迁移入口修复测试故障，保持真实数据库与其恢复数据不变。
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(sqlx::sqlite::SqliteConnectOptions::new().filename(&path))
        .await
        .unwrap();
    sqlx::query("UPDATE _sqlx_migrations SET checksum = ?1 WHERE version = 1")
        .bind(checksum)
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
    assert_eq!(app::init_database().await.unwrap_err().code, "KEEL-DB");
    assert!(state::pool().is_err());
    assert!(access::current().is_err());
    assert_eq!(app::startup_restore_status(), restored);

    let pool = data::open(&path).await.unwrap();
    sqlx::query("DROP TRIGGER fail_user")
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
    // 此次 apply_pending 返回 Ok(None)，随后启动审计失败。
    assert_eq!(app::init_database().await.unwrap_err().code, "KEEL-DB");
    assert!(state::pool().is_err());
    assert!(access::current().is_err());
    assert_eq!(app::startup_restore_status(), restored);

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
    assert_eq!(app::startup_restore_status(), restored);
    assert_eq!(app::startup_restore_status(), restored);
    let starts: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM audit_log WHERE action = 'app.start'")
            .fetch_one(state::pool().unwrap())
            .await
            .unwrap();
    assert_eq!(starts, 1);
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
