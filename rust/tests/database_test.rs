//! 数据库打开与迁移：新库建表、重复打开安全、有待执行迁移时先备份。

use rust_lib_keel::data;
use std::path::PathBuf;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("keel-db-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn pre_migration_files(dir: &std::path::Path) -> Vec<String> {
    std::fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|name| name.contains(".pre-migration-"))
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_open_of_the_same_new_database_is_serialized_and_valid() {
    let dir = temp_dir("concurrent-open");
    let db = dir.join("main.db");
    let mut tasks = Vec::new();
    for _ in 0..8 {
        let db = db.clone();
        tasks.push(tokio::spawn(async move { data::open(&db).await }));
    }

    for task in tasks {
        let pool = task.await.unwrap().unwrap();
        let tables: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('audit_log', 'app_user')",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(tables, 2);
        pool.close().await;
    }
    assert!(pre_migration_files(&dir).is_empty());
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn new_database_gets_its_tables_and_no_backup() {
    let dir = temp_dir("fresh");
    let pool = data::open(&dir.join("main.db")).await.unwrap();

    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
    assert!(
        pre_migration_files(&dir).is_empty(),
        "新库没有旧数据，不需要备份"
    );
    let _ = std::fs::remove_dir_all(dir.as_path());
}

#[tokio::test]
async fn reopening_an_up_to_date_database_keeps_data_and_makes_no_backup() {
    let dir = temp_dir("reopen");
    let db = dir.join("main.db");

    let pool = data::open(&db).await.unwrap();
    data::audit::insert(&pool, 1, "alice", "demo", "x", "ok", "")
        .await
        .unwrap();
    pool.close().await;

    let pool = data::open(&db).await.unwrap();
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 1);
    assert!(pre_migration_files(&dir).is_empty());
    let _ = std::fs::remove_dir_all(dir.as_path());
}

#[tokio::test]
async fn pending_migration_triggers_a_backup_that_still_has_the_old_data() {
    let dir = temp_dir("pending");
    let db = dir.join("main.db");

    // 造一个“升级前”的库：有数据，但迁移记录被清掉，程序会认为迁移还没执行。
    let pool = data::open(&db).await.unwrap();
    data::audit::insert(&pool, 1, "alice", "old.row", "x", "ok", "")
        .await
        .unwrap();
    sqlx::query("DELETE FROM _sqlx_migrations")
        .execute(&pool)
        .await
        .unwrap();
    // Drop migration-created child tables before dropping app_user.
    sqlx::query("DROP TABLE app_security")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DROP TABLE customer")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DROP TABLE audit_export_history")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DROP TABLE grid_preferences")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DROP TABLE app_user")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DROP INDEX idx_audit_log_at")
        .execute(&pool)
        .await
        .unwrap();
    // 把表改名，让迁移脚本里的 CREATE TABLE 可以重新执行。
    sqlx::query("ALTER TABLE audit_log RENAME TO audit_log_old")
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;

    let pool = data::open(&db).await.unwrap();
    pool.close().await;

    let backups = pre_migration_files(&dir);
    assert_eq!(backups.len(), 1, "应有一份迁移前备份：{backups:?}");

    // 备份里是升级前的状态：有旧表和旧数据。
    let copy = sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(sqlx::sqlite::SqliteConnectOptions::new().filename(dir.join(&backups[0])))
        .await
        .unwrap();
    let old_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log_old")
        .fetch_one(&copy)
        .await
        .unwrap();
    assert_eq!(old_rows, 1);
    let _ = std::fs::remove_dir_all(dir.as_path());
}
