//! 审计日志列表（真 SQLite）：分页、排序白名单、关键字过滤与通配符转义。

use rust_lib_keel::data;
use rust_lib_keel::data::audit::{self, ListParams, SortKey};
use rust_lib_keel::errors::KeelError;
use rust_lib_keel::services;
use std::path::PathBuf;

async fn new_pool(name: &str) -> (sqlx::SqlitePool, PathBuf) {
    let dir = std::env::temp_dir().join(format!("keel-audit-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    (data::open(&dir.join("main.db")).await.unwrap(), dir)
}

async fn seed(pool: &sqlx::SqlitePool, count: i64) {
    for i in 0..count {
        let actor = if i % 2 == 0 { "alice" } else { "bob" };
        audit::insert(
            pool,
            1_000 + i,
            actor,
            "demo.action",
            &format!("item-{i}"),
            "ok",
            "",
        )
        .await
        .unwrap();
    }
}

async fn list(
    pool: &sqlx::SqlitePool,
    keyword: &str,
    sort_by: &str,
    descending: bool,
    page: u32,
    page_size: u32,
) -> Result<(Vec<audit::AuditRow>, i64), KeelError> {
    services::audit::list(
        pool,
        keyword.into(),
        sort_by.into(),
        descending,
        page,
        page_size,
    )
    .await
}

#[tokio::test]
async fn paging_returns_a_page_and_the_full_total() {
    let (pool, dir) = new_pool("paging").await;
    seed(&pool, 25).await;

    let (rows, total) = list(&pool, "", "at", true, 1, 10).await.unwrap();
    assert_eq!(total, 25);
    assert_eq!(rows.len(), 10);
    assert_eq!(rows[0].at, 1_024, "按时间倒序，最新的在前");

    let (last, _) = list(&pool, "", "at", true, 3, 10).await.unwrap();
    assert_eq!(last.len(), 5);

    let (ascending, _) = list(&pool, "", "at", false, 1, 3).await.unwrap();
    assert_eq!(
        ascending.iter().map(|r| r.at).collect::<Vec<_>>(),
        [1_000, 1_001, 1_002]
    );
    let _ = std::fs::remove_dir_all(dir.as_path());
}

#[tokio::test]
async fn keyword_filters_by_actor_action_or_target() {
    let (pool, dir) = new_pool("keyword").await;
    seed(&pool, 10).await;

    assert_eq!(list(&pool, "alice", "at", true, 1, 50).await.unwrap().1, 5);
    assert_eq!(list(&pool, "item-7", "at", true, 1, 50).await.unwrap().1, 1);
    assert_eq!(
        list(&pool, "demo.act", "at", true, 1, 50).await.unwrap().1,
        10
    );
    assert_eq!(
        list(&pool, "nothing-like-this", "at", true, 1, 50)
            .await
            .unwrap()
            .1,
        0
    );
    let _ = std::fs::remove_dir_all(dir.as_path());
}

#[tokio::test]
async fn like_wildcards_in_the_keyword_match_literally() {
    let (pool, dir) = new_pool("wildcard").await;
    audit::insert(&pool, 1, "alice", "export", "100%_done", "ok", "")
        .await
        .unwrap();
    audit::insert(&pool, 2, "alice", "export", "100xxdone", "ok", "")
        .await
        .unwrap();

    // 如果 % 和 _ 没被转义，"100%_done" 会同时匹配两行。
    assert_eq!(
        list(&pool, "100%_done", "at", true, 1, 50).await.unwrap().1,
        1
    );
    assert_eq!(list(&pool, "%", "at", true, 1, 50).await.unwrap().1, 1);
    let _ = std::fs::remove_dir_all(dir.as_path());
}

#[tokio::test]
async fn sort_column_and_paging_limits_are_validated() {
    let (pool, dir) = new_pool("validate").await;

    for bad in ["id; DROP TABLE audit_log", "", "target"] {
        let err = list(&pool, "", bad, true, 1, 10).await.unwrap_err();
        assert!(matches!(err, KeelError::Validation(_)), "{bad}");
    }
    assert!(list(&pool, "", "at", true, 0, 10).await.is_err());
    assert!(list(&pool, "", "at", true, 1, 0).await.is_err());
    assert!(list(&pool, "", "at", true, 1, 201).await.is_err());

    // 注入文本没有破坏表。
    assert!(list(&pool, "", "at", true, 1, 10).await.is_ok());
    let _ = std::fs::remove_dir_all(dir.as_path());
}

#[tokio::test]
async fn date_bounds_list_count_and_export_snapshot_agree() {
    use rust_lib_keel::data::audit::ExportSnapshot;
    let (pool, dir) = new_pool("dates").await;
    for at in [i64::MIN, -1, 0, 1, 2, i64::MAX] {
        audit::insert(&pool, at, "actor", "date", "100%_target", "ok", "")
            .await
            .unwrap();
    }
    // Keyword must remain ANDed with the entire half-open time condition.
    audit::insert(&pool, 0, "other", "date", "100xx_target", "ok", "")
        .await
        .unwrap();
    let cases = [
        (None, None, vec![i64::MIN, -1, 0, 1, 2, i64::MAX]),
        (Some(0), None, vec![0, 1, 2, i64::MAX]),
        (None, Some(0), vec![i64::MIN, -1]),
        (Some(0), Some(2), vec![0, 1]),
        (Some(3), Some(4), vec![]),
        (Some(i64::MIN), Some(i64::MAX), vec![i64::MIN, -1, 0, 1, 2]),
        (Some(i64::MAX), None, vec![i64::MAX]),
        (None, Some(i64::MIN), vec![]),
    ];
    for (start, end, expected) in cases {
        for descending in [false, true] {
            let mut expected = expected.clone();
            if descending {
                expected.reverse();
            }
            let mut params = ListParams {
                keyword: "%_".into(),
                start_at_ms: start,
                end_at_ms_exclusive: end,
                sort: vec![SortKey {
                    field: "at".into(),
                    descending,
                }],
                page: 1,
                page_size: 1,
            };
            let mut actual = Vec::new();
            loop {
                let (rows, total) = services::audit::list_filtered(&pool, &params)
                    .await
                    .unwrap();
                assert_eq!(total, expected.len() as i64);
                if rows.is_empty() {
                    break;
                }
                actual.extend(rows.iter().map(|row| row.at));
                params.page += 1;
            }
            assert_eq!(actual, expected);
            let mut snapshot = ExportSnapshot::begin(&pool, params).await.unwrap();
            assert_eq!(snapshot.total, expected.len() as i64);
            // actor + action + target + result: 5 + 4 + 11 + 2 UTF-8 bytes.
            assert_eq!(snapshot.raw_bytes, expected.len() as i64 * 22);
            let mut exported = Vec::new();
            loop {
                let rows = snapshot.next_batch().await.unwrap();
                if rows.is_empty() {
                    break;
                }
                exported.extend(rows.iter().map(|row| row.at));
            }
            assert_eq!(exported, expected);
        }
    }
    pool.close().await;
    remove_test_dir(&dir);
}

#[tokio::test]
async fn invalid_date_ranges_are_validation_errors_before_database_access() {
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect_lazy("sqlite::memory:")
        .unwrap();
    pool.close().await;
    for (start, end) in [(0, 0), (1, 0), (i64::MAX, i64::MIN)] {
        let params = ListParams {
            keyword: String::new(),
            start_at_ms: Some(start),
            end_at_ms_exclusive: Some(end),
            sort: vec![SortKey {
                field: "at".into(),
                descending: false,
            }],
            page: 1,
            page_size: 50,
        };
        let error = services::audit::list_filtered(&pool, &params)
            .await
            .unwrap_err();
        assert!(matches!(error, KeelError::Validation(_)));
        assert_eq!(error.code(), "KEEL-VALIDATION");
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
async fn multiple_sort_keys_apply_in_order_with_stable_tiebreak() {
    let (pool, dir) = new_pool("multisort").await;
    // 同一 actor/action 的两行用于验证 id 兜底次序。
    audit::insert(&pool, 40, "alice", "export", "tie-1", "ok", "")
        .await
        .unwrap();
    audit::insert(&pool, 10, "alice", "export", "tie-2", "ok", "")
        .await
        .unwrap();
    audit::insert(&pool, 30, "alice", "import", "x", "ok", "")
        .await
        .unwrap();
    audit::insert(&pool, 20, "bob", "export", "y", "ok", "")
        .await
        .unwrap();

    let params = ListParams {
        keyword: String::new(),
        start_at_ms: None,
        end_at_ms_exclusive: None,
        sort: vec![
            SortKey {
                field: "actor".into(),
                descending: false,
            },
            SortKey {
                field: "action".into(),
                descending: true,
            },
            SortKey {
                field: "at".into(),
                descending: true,
            },
        ],
        page: 1,
        page_size: 50,
    };
    let (rows, total) = services::audit::list_filtered(&pool, &params)
        .await
        .unwrap();
    assert_eq!(total, 4);
    let seen: Vec<(&str, &str, i64)> = rows
        .iter()
        .map(|row| (row.actor.as_str(), row.action.as_str(), row.at))
        .collect();
    assert_eq!(
        seen,
        [
            ("alice", "import", 30),
            ("alice", "export", 40),
            ("alice", "export", 10),
            ("bob", "export", 20),
        ]
    );
    let _ = std::fs::remove_dir_all(dir.as_path());
}
