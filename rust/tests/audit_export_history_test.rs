//! Durable history and action handles are separate contracts.
use rust_lib_keel::api::audit::AuditQuery;
use rust_lib_keel::data;
use rust_lib_keel::diagnostics::correlation::new_correlation_id;
use rust_lib_keel::services::{access, audit, audit_export, audit_export_history};
use std::time::Duration;

fn query() -> AuditQuery {
    AuditQuery {
        keyword: String::new(),
        start_at_ms: None,
        end_at_ms_exclusive: None,
        sort: Vec::new(),
        page: 1,
        page_size: 50,
    }
}

#[tokio::test]
async fn durable_history_is_scoped_conservative_and_registration_is_required() {
    let dir = std::env::temp_dir().join(format!("keel-history-{}", new_correlation_id()));
    std::fs::create_dir(&dir).unwrap();
    let db = dir.join("main.db");
    let pool = data::open(&db).await.unwrap();
    access::init(&pool).await.unwrap();
    access::create_user(&pool, "other", "admin").await.unwrap();
    let owner = data::user::find_by_name(&pool, access::DEFAULT_USER)
        .await
        .unwrap()
        .unwrap()
        .id;
    let now = audit::now_ms();
    sqlx::query(
        "INSERT INTO audit_export_history(task_id, owner_id, created_at_ms, phase) \
         VALUES ('interrupted-example', ?1, ?2, 'running')",
    )
    .bind(owner)
    .bind(now)
    .execute(&pool)
    .await
    .unwrap();
    audit_export_history::recover_on_startup(&pool)
        .await
        .unwrap();
    let history = audit_export_history::list(&pool, 1, 100).await.unwrap();
    assert_eq!(history.entries.len(), 1);
    assert_eq!(history.entries[0].phase, "interrupted");
    assert!(history.entries[0].result_name.is_none());
    assert!(audit_export::status(&pool, "interrupted-example")
        .await
        .is_err());
    access::switch_user(&pool, "other").await.unwrap();
    assert!(audit_export_history::list(&pool, 1, 100)
        .await
        .unwrap()
        .entries
        .is_empty());
    access::switch_user(&pool, access::DEFAULT_USER)
        .await
        .unwrap();

    // Neither ignored nor aborted registrations may start a worker. The DDL probes
    // stay on one held connection: rapid create/drop cycling across pool connections
    // can observe a stale schema view through sqlx's deferred connection state.
    let mut ddl = pool.acquire().await.unwrap();
    for behavior in ["IGNORE", "ABORT, 'test registration rejected'"] {
        // behavior 是测试内固定字面量，不含用户输入。
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "CREATE TRIGGER reject_history BEFORE INSERT ON audit_export_history \
             BEGIN SELECT RAISE({behavior}); END"
        )))
        .execute(&mut *ddl)
        .await
        .unwrap();
        assert!(audit_export::start(&pool, &db, query()).await.is_err());
        assert!(!dir.join("exports").exists());
        sqlx::query("DROP TRIGGER reject_history")
            .execute(&mut *ddl)
            .await
            .unwrap();
    }
    drop(ddl);

    let started = audit_export::start(&pool, &db, query()).await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let phase: String =
                sqlx::query_scalar("SELECT phase FROM audit_export_history WHERE task_id = ?1")
                    .bind(&started.task_id)
                    .fetch_one(&pool)
                    .await
                    .unwrap();
            if phase != "running" {
                assert_eq!(phase, "completed");
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    let status = audit_export::status(&pool, &started.task_id).await.unwrap();
    let output = std::path::PathBuf::from(status.output_path.unwrap());
    assert!(output.is_file());
    let history = audit_export_history::list(&pool, 1, 100).await.unwrap();
    let entry = history
        .entries
        .iter()
        .find(|row| row.task_id == started.task_id)
        .unwrap();
    assert_eq!(
        entry.result_name.as_deref(),
        output.file_name().unwrap().to_str()
    );
    assert!(audit_export_history::list(&pool, 0, 100).await.is_err());
    assert!(audit_export_history::list(&pool, 1, 101).await.is_err());

    pool.close().await;
    let pool = data::open(&db).await.unwrap();
    audit_export_history::recover_on_startup(&pool)
        .await
        .unwrap();
    access::init(&pool).await.unwrap();
    let history = audit_export_history::list(&pool, 1, 100).await.unwrap();
    assert!(history
        .entries
        .iter()
        .any(|entry| entry.task_id == started.task_id && entry.phase == "completed"));
    assert!(output.is_file());
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
