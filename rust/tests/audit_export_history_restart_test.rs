//! Independent processes exercise durable recovery; no CSV/task replay is implied.
use rust_lib_keel::data;
use rust_lib_keel::diagnostics::correlation::new_correlation_id;
use rust_lib_keel::services::{access, audit, audit_export, audit_export_history};
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

fn run_child(db: &Path, stage: &str) {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "history_restart_child", "--nocapture"])
        .env("KEEL_HISTORY_RESTART_DB", db)
        .env("KEEL_HISTORY_RESTART_STAGE", stage)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(40);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "history child {stage} failed: {status}");
            return;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("history child {stage} timed out");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn history_survives_process_exit_without_recreating_action_handles() {
    let dir = std::env::temp_dir().join(format!("keel-restart-{}", new_correlation_id()));
    std::fs::create_dir(&dir).unwrap();
    let db = dir.join("main.db");
    run_child(&db, "seed");
    run_child(&db, "recover");
    // A third process must preserve the original interruption timestamp.
    run_child(&db, "recover");
    remove_test_dir(&dir);
}

/// Windows 上子进程退出后文件句柄可能被杀毒扫描短暂占用，重试清理避免误报。
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
async fn history_restart_child() {
    let Some(db) = std::env::var_os("KEEL_HISTORY_RESTART_DB") else {
        return;
    };
    let db = std::path::PathBuf::from(db);
    let pool = data::open(&db).await.unwrap();
    let stage = std::env::var("KEEL_HISTORY_RESTART_STAGE").unwrap();
    if stage == "seed" {
        access::init(&pool).await.unwrap();
        let owner = data::user::find_by_name(&pool, access::DEFAULT_USER)
            .await
            .unwrap()
            .unwrap()
            .id;
        sqlx::query(
            "INSERT INTO audit_export_history \
             (task_id, owner_id, created_at_ms, phase, completed_rows, total_rows) \
             VALUES ('restart-example', ?1, ?2, 'running', 2, 10)",
        )
        .bind(owner)
        .bind(audit::now_ms())
        .execute(&pool)
        .await
        .unwrap();
        let finished = audit::now_ms();
        sqlx::query(
            "INSERT INTO audit_export_history \
             (task_id, owner_id, created_at_ms, finished_at_ms, phase, \
              completed_rows, total_rows, result_name) \
             VALUES ('completed-example', ?1, ?2, ?2, 'completed', 3, 3, \
                     'audit-completed-example.csv')",
        )
        .bind(owner)
        .bind(finished)
        .execute(&pool)
        .await
        .unwrap();
        let exports = db.parent().unwrap().join("exports");
        std::fs::create_dir(&exports).unwrap();
        // File presence must never be interpreted as successful completion.
        std::fs::write(exports.join("audit-restart-example.csv"), b"partial\n").unwrap();
    } else {
        assert_eq!(stage, "recover");
        let previous: Option<i64> = sqlx::query_scalar(
            "SELECT finished_at_ms FROM audit_export_history WHERE task_id = 'restart-example'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        audit_export_history::recover_on_startup(&pool)
            .await
            .unwrap();
        access::init(&pool).await.unwrap();
        let page = audit_export_history::list(&pool, 1, 100).await.unwrap();
        assert_eq!(page.entries.len(), 2);
        let completed = page
            .entries
            .iter()
            .find(|entry| entry.task_id == "completed-example")
            .unwrap();
        assert_eq!(completed.phase, "completed");
        assert_eq!(completed.finished_at_ms, Some(completed.created_at_ms));
        assert_eq!(completed.completed_rows, 3);
        assert_eq!(completed.total_rows, 3);
        assert_eq!(
            completed.result_name.as_deref(),
            Some("audit-completed-example.csv")
        );
        assert!(completed.error_code.is_none());
        let entry = page
            .entries
            .iter()
            .find(|entry| entry.task_id == "restart-example")
            .unwrap();
        assert_eq!(entry.task_id, "restart-example");
        assert_eq!(entry.phase, "interrupted");
        assert_eq!(entry.completed_rows, 2);
        assert_eq!(entry.total_rows, 10);
        assert_eq!(entry.result_name, None);
        assert_eq!(entry.error_code.as_deref(), Some("KEEL-INTERNAL"));
        assert!(entry.finished_at_ms.is_some());
        if let Some(previous) = previous {
            assert_eq!(entry.finished_at_ms, Some(previous));
        }
        assert!(audit_export::status(&pool, "restart-example")
            .await
            .is_err());
        assert!(audit_export::list(&pool).await.unwrap().is_empty());
        let exports = db.parent().unwrap().join("exports");
        assert_eq!(std::fs::read_dir(&exports).unwrap().count(), 1);
        assert_eq!(
            std::fs::read(exports.join("audit-restart-example.csv")).unwrap(),
            b"partial\n",
        );
    }
    pool.close().await;
}
