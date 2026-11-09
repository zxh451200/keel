//! One test per process: current identity is deliberately process-global.
use rust_lib_keel::api::grid_preferences::{GridPreferences, SaveGridPreferences};
use rust_lib_keel::services::{access, grid_preferences};
use rust_lib_keel::{data, diagnostics::correlation::new_correlation_id};

fn request(layout: &GridPreferences) -> SaveGridPreferences {
    SaveGridPreferences {
        list_id: layout.list_id.clone(),
        expected_owner_id: layout.owner_id.clone(),
        expected_session: layout.session.clone(),
        expected_revision: layout.revision,
        columns: layout.columns.clone(),
    }
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

#[tokio::test]
async fn isolated_owners_revisions_restart_and_stale_identity() {
    let dir = std::env::temp_dir().join(format!("keel-layout-{}", new_correlation_id()));
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("main.db");
    let pool = data::open(&path).await.unwrap();
    access::init(&pool).await.unwrap();
    access::create_user(&pool, "reader", "viewer")
        .await
        .unwrap();
    let first = grid_preferences::load(&pool, "audit_log").await.unwrap();
    assert_eq!(first.columns[0].id, "at");
    let mut change = request(&first);
    change.columns[0].width = 240;
    change.columns[0].frozen = "start".into();
    let saved = grid_preferences::save(&pool, change).await.unwrap();
    assert_eq!(saved.revision, 1);
    assert!(grid_preferences::save(&pool, request(&first))
        .await
        .is_err());

    access::switch_user(&pool, "reader").await.unwrap();
    let reader = grid_preferences::load(&pool, "audit_log").await.unwrap();
    assert_ne!(reader.owner_id, saved.owner_id);
    assert_eq!(reader.revision, 0);
    assert_eq!(reader.columns[0].width, 160);
    assert!(grid_preferences::save(&pool, request(&saved))
        .await
        .is_err());
    grid_preferences::save(&pool, request(&reader))
        .await
        .unwrap();

    access::switch_user(&pool, access::DEFAULT_USER)
        .await
        .unwrap();
    // A→B→A cannot revive an old preview even when its DB revision still matches.
    assert!(grid_preferences::save(&pool, request(&saved))
        .await
        .is_err());
    let fresh = grid_preferences::load(&pool, "audit_log").await.unwrap();
    assert_eq!(fresh.columns[0].width, 240);
    let (one, two) = tokio::join!(
        grid_preferences::save(&pool, request(&fresh)),
        grid_preferences::save(&pool, request(&fresh)),
    );
    assert_ne!(one.is_ok(), two.is_ok());

    pool.close().await;
    let pool = data::open(&path).await.unwrap();
    access::init(&pool).await.unwrap();
    let reopened = grid_preferences::load(&pool, "audit_log").await.unwrap();
    assert_eq!(reopened.columns[0].width, 240);
    assert_eq!(reopened.revision, 2);

    // Future layout schemas must be preserved, even with a guessed valid revision.
    let owner: i64 = reopened.owner_id.parse().unwrap();
    sqlx::query("UPDATE grid_preferences SET layout_json = '{\"schema\":99,\"columns\":[]}' WHERE owner_id = ?1")
        .bind(owner).execute(&pool).await.unwrap();
    assert!(grid_preferences::load(&pool, "audit_log").await.is_err());
    assert!(grid_preferences::save(&pool, request(&reopened))
        .await
        .is_err());
    let json: String = sqlx::query_scalar(
        "SELECT layout_json FROM grid_preferences WHERE owner_id = ?1 AND list_id = 'audit_log'",
    )
    .bind(owner)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(json.contains("99"));
    pool.close().await;
    remove_test_dir(&dir);
}
