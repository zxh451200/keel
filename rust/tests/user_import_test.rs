//! One test owns process-global identity; all failure cases use real SQLite.
use rust_lib_keel::data;
use rust_lib_keel::diagnostics::correlation::new_correlation_id;
use rust_lib_keel::errors::KeelError;
use rust_lib_keel::services::{access, user_import};
use std::sync::atomic::AtomicBool;

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

async fn snapshot(pool: &sqlx::SqlitePool) -> (i64, i64) {
    let users = sqlx::query_scalar("SELECT COUNT(*) FROM app_user")
        .fetch_one(pool)
        .await
        .unwrap();
    let audit = sqlx::query_scalar("SELECT COUNT(*) FROM audit_log")
        .fetch_one(pool)
        .await
        .unwrap();
    (users, audit)
}

#[tokio::test]
async fn batch_import_commits_users_and_audits_or_rolls_back_both() {
    let dir = std::env::temp_dir().join(format!("keel-user-import-{}", new_correlation_id()));
    std::fs::create_dir(&dir).unwrap();
    let pool = data::open(&dir.join("main.db")).await.unwrap();
    access::init(&pool).await.unwrap();
    let cancelled = AtomicBool::new(false);
    let before = snapshot(&pool).await;
    let count = user_import::import_jsonl(
        &pool,
        b"{\"name\":\" alice \",\"role\":\"viewer\"}\r\n{\"name\":\"bob\",\"role\":\"operator\"}\n",
        &cancelled,
    )
    .await
    .unwrap();
    assert_eq!(count, 2);
    assert_eq!(snapshot(&pool).await, (before.0 + 2, before.1 + 3));
    let rows: Vec<(String, String, String)> =
        sqlx::query_as("SELECT action, target, correlation_id FROM audit_log ORDER BY id")
            .fetch_all(&pool)
            .await
            .unwrap();
    let batch = &rows[rows.len() - 3..];
    assert_eq!((&batch[0].0[..], &batch[0].1[..]), ("user.create", "alice"));
    assert_eq!((&batch[1].0[..], &batch[1].1[..]), ("user.create", "bob"));
    assert_eq!(
        (&batch[2].0[..], &batch[2].1[..]),
        ("users.import", "app_user")
    );
    assert!(!batch[0].2.is_empty());
    assert!(batch.iter().all(|row| row.2 == batch[0].2));

    for input in [
        "{\"name\":\"new\",\"role\":\"viewer\"}\ninvalid",
        "{\"name\":\"new\",\"role\":\"viewer\"}\n{\"name\":\" new \",\"role\":\"viewer\"}",
        "{\"name\":\"new\",\"role\":\"viewer\"}\n{\"name\":\"alice\",\"role\":\"viewer\"}",
        "{\"name\":\"new\",\"role\":\"viewer\"}\n{\"name\":\"admin2\",\"role\":\"admin\"}",
        "{\"name\":\"new\",\"role\":\"viewer\"}\n\n",
    ] {
        let before = snapshot(&pool).await;
        assert!(
            user_import::import_jsonl(&pool, input.as_bytes(), &cancelled)
                .await
                .is_err()
        );
        assert_eq!(snapshot(&pool).await, before, "{input}");
    }

    // A trigger silently ignoring a write must fail the entire import.
    // DDL probes stay on one held connection: rapid create/drop cycling across
    // pool connections can observe a stale schema view through sqlx.
    let mut ddl = pool.acquire().await.unwrap();
    for (table, condition) in [
        ("app_user", "NEW.name = 'ignored'"),
        ("audit_log", "NEW.action = 'users.import'"),
    ] {
        // table / condition 都是测试内固定字面量，不含用户输入。
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "CREATE TRIGGER reject_import BEFORE INSERT ON {table} \
             WHEN {condition} BEGIN SELECT RAISE(IGNORE); END"
        )))
        .execute(&mut *ddl)
        .await
        .unwrap();
        let before = snapshot(&pool).await;
        assert!(user_import::import_jsonl(
            &pool,
            b"{\"name\":\"ignored\",\"role\":\"viewer\"}",
            &cancelled,
        )
        .await
        .is_err());
        assert_eq!(snapshot(&pool).await, before);
        sqlx::query("DROP TRIGGER reject_import")
            .execute(&mut *ddl)
            .await
            .unwrap();
    }
    drop(ddl);
    let before = snapshot(&pool).await;
    assert!(matches!(
        user_import::import_jsonl(&pool, b"{}", &AtomicBool::new(true)).await,
        Err(KeelError::Cancelled),
    ));
    assert_eq!(snapshot(&pool).await, before);
    let ticket = user_import::prepare(&pool).await.unwrap();
    assert_eq!(user_import::progress(&ticket).unwrap(), Some((0, 0)));
    assert_eq!(
        user_import::run_prepared(&pool, &ticket, b"{\"name\":\"carol\",\"role\":\"viewer\"}",)
            .await
            .unwrap(),
        1,
    );
    assert_eq!(user_import::progress(&ticket).unwrap(), None);
    let before = snapshot(&pool).await;
    assert!(matches!(
        user_import::run_prepared(&pool, &ticket, b"{}").await,
        Err(KeelError::NotFound),
    ));
    let ticket = user_import::prepare(&pool).await.unwrap();
    user_import::cancel(&ticket).unwrap();
    assert!(matches!(
        user_import::run_prepared(&pool, &ticket, b"{}").await,
        Err(KeelError::NotFound),
    ));
    assert_eq!(snapshot(&pool).await, before);
    // A visible processed count is provisional: cancellation still rolls back
    // every user and audit row, and releasing the ticket erases its snapshot.
    let ticket = user_import::prepare(&pool).await.unwrap();
    let input = (0..100)
        .map(|i| format!("{{\"name\":\"progress{i}\",\"role\":\"viewer\"}}\n"))
        .collect::<String>();
    let observe = async {
        loop {
            let (processed, total) = user_import::progress(&ticket).unwrap().unwrap();
            if processed > 0 {
                assert_eq!(total, 100);
                assert!(processed <= total);
                user_import::cancel(&ticket).unwrap();
                break;
            }
            tokio::task::yield_now().await;
        }
    };
    let (result, ()) = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        tokio::join!(
            user_import::run_prepared(&pool, &ticket, input.as_bytes()),
            observe
        )
    })
    .await
    .unwrap();
    assert!(matches!(result, Err(KeelError::Cancelled)));
    assert_eq!(snapshot(&pool).await, before);
    assert_eq!(user_import::progress(&ticket).unwrap(), None);
    let ticket = user_import::prepare(&pool).await.unwrap();
    assert!(user_import::run_prepared(&pool, &ticket, b"{}")
        .await
        .is_err());
    assert!(matches!(
        user_import::run_prepared(&pool, &ticket, b"{}").await,
        Err(KeelError::NotFound),
    ));
    assert_eq!(snapshot(&pool).await, before);
    let ticket = user_import::prepare(&pool).await.unwrap();
    access::switch_user(&pool, "bob").await.unwrap();
    access::switch_user(&pool, access::DEFAULT_USER)
        .await
        .unwrap();
    let before = snapshot(&pool).await;
    assert!(matches!(
        user_import::run_prepared(&pool, &ticket, b"{}").await,
        Err(KeelError::PermissionDenied(_)),
    ));
    assert!(matches!(
        user_import::cancel(&ticket),
        Err(KeelError::PermissionDenied(_))
    ));
    assert!(matches!(
        user_import::progress(&ticket),
        Err(KeelError::PermissionDenied(_))
    ));
    assert_eq!(snapshot(&pool).await, before);
    access::switch_user(&pool, "alice").await.unwrap();
    let before = snapshot(&pool).await;
    assert!(matches!(
        user_import::import_jsonl(&pool, b"{}", &cancelled).await,
        Err(KeelError::PermissionDenied(_)),
    ));
    // Preserve the established permission.denied policy, with no user writes.
    assert_eq!(snapshot(&pool).await, (before.0, before.1 + 1));
    pool.close().await;
    remove_test_dir(&dir);
}
