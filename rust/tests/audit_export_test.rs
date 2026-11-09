//! 真实 SQLite 与真实 CSV；CURRENT/任务表共享的 API 场景串行放在一个测试中。
use rust_lib_keel::api::audit::{
    audit_export_status, cancel_audit_export, list_audit_exports, list_audit_logs,
    save_audit_export_copy, start_audit_export, AuditExportStatus, AuditQuery, AuditSort,
};
use rust_lib_keel::data::audit::{self, ExportSnapshot, ListParams, SortKey};
use rust_lib_keel::diagnostics::{
    correlation::new_correlation_id,
    events::{self, Level},
};
use rust_lib_keel::domain::permissions::Role;
use rust_lib_keel::services::{access, audit_export};
use rust_lib_keel::{data, state};
use std::path::{Path, PathBuf};
use std::time::Duration;

fn user(name: &str, role: Role) {
    access::set_current(access::CurrentUser {
        name: name.into(),
        role,
    });
}

fn query(keyword: &str) -> AuditQuery {
    AuditQuery {
        start_at_ms: None,
        end_at_ms_exclusive: None,
        keyword: keyword.into(),
        sort: vec![AuditSort {
            field: "at".into(),
            descending: false,
        }],
        // 导出明确忽略非法分页。
        page: 0,
        page_size: 0,
    }
}

async fn database() -> (sqlx::SqlitePool, PathBuf) {
    let dir = std::env::temp_dir().join(format!("keel-audit-export-{}", new_correlation_id()));
    std::fs::create_dir(&dir).unwrap();
    let pool = data::open(&dir.join("main.db")).await.unwrap();
    (pool, dir)
}

async fn terminal(pool: &sqlx::SqlitePool, id: &str) -> AuditExportStatus {
    tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            let status = audit_export::status(pool, id).await.unwrap();
            if status.phase != "running" {
                return status;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .expect("export must reach a terminal state")
}

async fn result_recorded(pool: &sqlx::SqlitePool, id: &str) {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM audit_log WHERE action = 'audit.export.result' AND correlation_id = ?"
            ).bind(id).fetch_one(pool).await.unwrap();
            if count == 1 { break; }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }).await.unwrap();
}

fn files(dir: &Path) -> usize {
    std::fs::read_dir(dir.join("exports"))
        .map(|entries| entries.count())
        .unwrap_or(0)
}

#[tokio::test]
async fn snapshot_count_and_batches_ignore_concurrent_insert_delete_and_update() {
    let (pool, dir) = database().await;
    sqlx::query(
        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 405) \
         INSERT INTO audit_log(at,actor,action,target,result,correlation_id) \
         SELECT 1,'actor','match','target','ok','' FROM n",
    )
    .execute(&pool)
    .await
    .unwrap();
    audit::insert(&pool, 0, "before", "match", "target", "ok", "")
        .await
        .unwrap();
    audit::insert(&pool, 2, "after", "match", "target", "ok", "")
        .await
        .unwrap();
    for sort in ["at", "actor", "action"] {
        for descending in [false, true] {
            let mut snapshot = ExportSnapshot::begin(
                &pool,
                ListParams {
                    start_at_ms: Some(1),
                    end_at_ms_exclusive: Some(2),
                    keyword: "match".into(),
                    sort: vec![SortKey {
                        field: sort.into(),
                        descending,
                    }],
                    page: 1,
                    page_size: 1,
                },
            )
            .await
            .unwrap();
            assert_eq!(snapshot.total, 405);
            let mut rows = snapshot.next_batch().await.unwrap();
            assert_eq!(rows.len(), 200);
            if sort == "at" && !descending {
                // WAL 允许第二连接在快照期间提交；已取 COUNT 不会随之漂移。
                sqlx::query("DELETE FROM audit_log WHERE id=405")
                    .execute(&pool)
                    .await
                    .unwrap();
                sqlx::query("UPDATE audit_log SET target='changed', at=2 WHERE id=404")
                    .execute(&pool)
                    .await
                    .unwrap();
                audit::insert(&pool, 1, "actor", "match", "new", "ok", "")
                    .await
                    .unwrap();
            }
            loop {
                let batch = snapshot.next_batch().await.unwrap();
                if batch.is_empty() {
                    break;
                }
                rows.extend(batch);
            }
            assert_eq!(rows.len(), 405);
            let ids: Vec<_> = rows.iter().map(|row| row.id).collect();
            assert_eq!(
                ids.iter().collect::<std::collections::HashSet<_>>().len(),
                405
            );
            assert!(ids.windows(2).all(|pair| if descending {
                pair[0] > pair[1]
            } else {
                pair[0] < pair[1]
            }));
            if sort == "at" && !descending {
                assert!(rows.iter().all(|row| row.target == "target"));
                assert_eq!(ids.last(), Some(&405));
                assert!(rows.iter().all(|row| row.at == 1));
                sqlx::query("UPDATE audit_log SET at=1 WHERE id=404")
                    .execute(&pool)
                    .await
                    .unwrap();
            }
        }
    }
    pool.close().await;
    remove_test_dir(&dir);
}

#[tokio::test]
async fn api_permissions_owner_csv_limits_cancellation_and_failures() {
    let (pool, dir) = database().await;
    state::set_pool(pool.clone());
    state::set_db_path(&dir.join("main.db"));
    data::user::insert(&pool, "owner", "operator", 1)
        .await
        .unwrap();
    user("owner", Role::Viewer);
    assert_eq!(
        start_audit_export(query("")).await.unwrap_err().code,
        "KEEL-PERMISSION"
    );
    assert_eq!(
        list_audit_exports().await.unwrap_err().code,
        "KEEL-PERMISSION"
    );
    user("owner", Role::Operator);
    assert!(list_audit_exports().await.unwrap().is_empty());
    for mut invalid in [query("a\nb"), query(&"x".repeat(1025)), query("")] {
        if invalid.keyword.is_empty() {
            invalid.sort = vec![AuditSort {
                field: "at; DROP TABLE audit_log".into(),
                descending: false,
            }];
        }
        assert_eq!(
            start_audit_export(invalid).await.unwrap_err().code,
            "KEEL-VALIDATION"
        );
    }
    for (start, end) in [(42, 42), (43, 42), (i64::MAX, i64::MIN)] {
        let mut invalid = query("");
        invalid.start_at_ms = Some(start);
        invalid.end_at_ms_exclusive = Some(end);
        assert_eq!(
            start_audit_export(invalid).await.unwrap_err().code,
            "KEEL-VALIDATION"
        );
        let mut invalid = query("");
        invalid.start_at_ms = Some(start);
        invalid.end_at_ms_exclusive = Some(end);
        invalid.page = 1;
        invalid.page_size = 50;
        assert_eq!(
            list_audit_logs(invalid).await.err().unwrap().code,
            "KEEL-VALIDATION"
        );
    }
    // 401 行跨三个批次、同排序值，以 id 稳定排列；%/_ 按字面匹配。
    sqlx::query(
        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 400) \
         INSERT INTO audit_log(at,actor,action,target,result,correlation_id) \
         SELECT 42,'普通','sample','100%_target','ok','' FROM n",
    )
    .execute(&pool)
    .await
    .unwrap();
    audit::insert(
        &pool,
        42,
        " \t=1",
        "sample",
        "100%_target",
        "a,\"b\"\r\n中文",
        "",
    )
    .await
    .unwrap();
    audit::insert(&pool, 42, "exclude", "sample", "100xx_target", "ok", "")
        .await
        .unwrap();
    audit::insert(&pool, 41, "before-range", "sample", "100%_target", "ok", "")
        .await
        .unwrap();
    audit::insert(&pool, 43, "at-end", "sample", "100%_target", "ok", "")
        .await
        .unwrap();
    let mut listed = query("%_");
    listed.start_at_ms = Some(42);
    listed.end_at_ms_exclusive = Some(43);
    listed.page = 3;
    listed.page_size = 200;
    let page = list_audit_logs(listed).await.unwrap();
    assert_eq!(page.total, 401);
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].at, 42);
    let mut filtered = query("%_");
    filtered.start_at_ms = Some(42);
    filtered.end_at_ms_exclusive = Some(43);
    let started = start_audit_export(filtered).await.unwrap();
    for (name, role) in [
        ("other", Role::Admin),
        ("owner", Role::Admin),
        ("owner", Role::Viewer),
    ] {
        user(name, role);
        if role == Role::Viewer {
            assert_eq!(
                list_audit_exports().await.unwrap_err().code,
                "KEEL-PERMISSION"
            );
        } else {
            assert!(list_audit_exports().await.unwrap().is_empty());
        }
        assert_eq!(
            audit_export_status(started.task_id.clone())
                .await
                .unwrap_err()
                .code,
            "KEEL-PERMISSION"
        );
        assert_eq!(
            cancel_audit_export(started.task_id.clone())
                .await
                .unwrap_err()
                .code,
            "KEEL-PERMISSION"
        );
    }
    user("owner", Role::Operator);
    let done = terminal(&pool, &started.task_id).await;
    let history = list_audit_exports().await.unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].task_id, started.task_id);
    assert_eq!(history[0].output_path, done.output_path);
    assert_eq!(done.phase, "completed");
    assert_eq!((done.completed_rows, done.total_rows), (401, 401));
    assert!(done.error_code.is_none());
    let path = PathBuf::from(done.output_path.unwrap());
    assert_eq!(path.parent().unwrap(), dir.join("exports"));
    let csv = std::fs::read_to_string(&path).unwrap();
    assert!(csv.starts_with("\u{feff}id,at_utc_ms,actor,action,target,result\r\n"));
    assert!(csv.contains("\"' \t=1\",\"sample\",\"100%_target\",\"a,\"\"b\"\"\r\n中文\"\r\n"));
    assert!(!csv.contains("exclude"));
    assert!(!csv.contains("before-range"));
    assert!(!csv.contains("at-end"));
    assert_eq!(csv.matches("\"100%_target\"").count(), 401);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert_eq!(
        cancel_audit_export(started.task_id.clone())
            .await
            .unwrap()
            .phase,
        "completed"
    );
    assert_eq!(
        audit_export_status("unknown".into())
            .await
            .unwrap_err()
            .code,
        "KEEL-NOT-FOUND"
    );
    result_recorded(&pool, &started.task_id).await;
    let records: Vec<(String, String, String, String)> = sqlx::query_as(
        "SELECT actor,action,target,result FROM audit_log WHERE correlation_id=? ORDER BY id",
    )
    .bind(&started.task_id)
    .fetch_all(&pool)
    .await
    .unwrap();
    let expected: Vec<(String, String, String, String)> = vec![
        (
            "owner".into(),
            "audit.export.start".into(),
            "audit_log".into(),
            "started".into(),
        ),
        (
            "owner".into(),
            "audit.export.result".into(),
            "audit_log".into(),
            "completed".into(),
        ),
    ];
    assert_eq!(records, expected);

    let copy = dir.join("另存副本.csv");
    let destination = copy.to_str().unwrap().to_owned();
    for (name, role) in [
        ("other", Role::Admin),
        ("owner", Role::Admin),
        ("owner", Role::Viewer),
    ] {
        user(name, role);
        assert_eq!(
            save_audit_export_copy(started.task_id.clone(), destination.clone())
                .await
                .unwrap_err()
                .code,
            "KEEL-PERMISSION"
        );
        assert!(!copy.exists());
    }
    user("owner", Role::Operator);
    assert_eq!(
        save_audit_export_copy("unknown".into(), destination.clone())
            .await
            .unwrap_err()
            .code,
        "KEEL-NOT-FOUND"
    );
    assert_eq!(
        save_audit_export_copy(started.task_id.clone(), destination.clone())
            .await
            .unwrap(),
        destination
    );
    assert_eq!(std::fs::read(&copy).unwrap(), std::fs::read(&path).unwrap());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&copy).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    std::fs::write(&copy, b"keep-existing").unwrap();
    assert!(
        save_audit_export_copy(started.task_id.clone(), destination.clone())
            .await
            .is_err()
    );
    assert_eq!(std::fs::read(&copy).unwrap(), b"keep-existing");
    let copy_audits: Vec<(String, String, String)> = sqlx::query_as(
        "SELECT target,result,correlation_id FROM audit_log WHERE action='audit.export.copy'",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert!(copy_audits
        .iter()
        .any(|(target, result, id)| target == &started.task_id
            && result == "ok"
            && id == &started.task_id));
    assert!(copy_audits
        .iter()
        .all(|(target, result, id)| !target.contains(&destination)
            && !result.contains(&destination)
            && !id.contains(&destination)));
    let damaged = dir.join("damaged.csv").to_str().unwrap().to_owned();
    std::fs::write(&path, b"damaged").unwrap();
    assert_eq!(
        save_audit_export_copy(started.task_id.clone(), damaged.clone())
            .await
            .unwrap_err()
            .code,
        "KEEL-VALIDATION"
    );
    assert!(!Path::new(&damaged).exists());
    #[cfg(unix)]
    {
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&copy, &path).unwrap();
        assert!(
            save_audit_export_copy(started.task_id.clone(), damaged.clone())
                .await
                .is_err()
        );
        std::fs::remove_file(&path).unwrap();
    }
    std::fs::write(&path, csv.as_bytes()).unwrap();
    assert_eq!(
        std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
            .count(),
        0
    );

    // Pause after durable registration and before worker I/O.
    let (arrived, release) = audit_export::pause_next_worker_for_tests();
    let cancelled = start_audit_export(query("sample")).await.unwrap();
    arrived.await.unwrap();
    assert_eq!(
        start_audit_export(query("sample")).await.unwrap_err().code,
        "KEEL-VALIDATION"
    );
    cancel_audit_export(cancelled.task_id.clone())
        .await
        .unwrap();
    release.send(()).unwrap();
    let cancelled = terminal(&pool, &cancelled.task_id).await;
    assert_eq!(cancelled.phase, "cancelled");
    assert!(cancelled.output_path.is_none());
    assert!(cancelled.error_code.is_none());
    assert_eq!(
        save_audit_export_copy(cancelled.task_id.clone(), damaged.clone())
            .await
            .unwrap_err()
            .code,
        "KEEL-VALIDATION"
    );
    result_recorded(&pool, &cancelled.task_id).await;
    assert_eq!(files(&dir), 1);

    // 第三个任务：拒绝已有 exports 符号链接/文件，worker 必须落 failed。
    let blocked = dir.join("blocked");
    std::fs::create_dir(&blocked).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(dir.join("exports"), blocked.join("exports")).unwrap();
    #[cfg(not(unix))]
    std::fs::write(blocked.join("exports"), "blocked").unwrap();
    let failed = audit_export::start(&pool, &blocked.join("main.db"), query("sample"))
        .await
        .unwrap();
    let failed = terminal(&pool, &failed.task_id).await;
    assert_eq!(failed.phase, "failed");
    assert!(failed.output_path.is_none());
    assert!(failed.error_code.is_some());
    result_recorded(&pool, &failed.task_id).await;
    assert_eq!(files(&dir), 1);

    // 第四个任务：100001 个真实匹配行，拒绝而非截断。
    sqlx::query(
        "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 100001) \
         INSERT INTO audit_log(at,actor,action,target,result,correlation_id) \
         SELECT 1,'limit','row-limit','target','ok','' FROM n",
    )
    .execute(&pool)
    .await
    .unwrap();
    let limit = start_audit_export(query("row-limit")).await.unwrap();
    let limit = terminal(&pool, &limit.task_id).await;
    assert_eq!(limit.phase, "failed");
    assert_eq!(limit.error_code.as_deref(), Some("KEEL-VALIDATION"));
    result_recorded(&pool, &limit.task_id).await;
    assert_eq!(files(&dir), 1);

    // 第五个任务：原始内容 <64MiB，但引号转义后 >64MiB，失败清掉真实已写临时文件。
    let quotes = "\"".repeat(34 * 1024 * 1024);
    audit::insert(&pool, 1, "size", "byte-limit", "target", &quotes, "")
        .await
        .unwrap();
    drop(quotes);
    let size = start_audit_export(query("byte-limit")).await.unwrap();
    let size = terminal(&pool, &size.task_id).await;
    assert_eq!(size.phase, "failed");
    assert_eq!(size.error_code.as_deref(), Some("KEEL-VALIDATION"));
    result_recorded(&pool, &size.task_id).await;
    assert_eq!(files(&dir), 1);

    // 第六个任务：审计触发器拒绝写入，导出结果不被审计错误掩盖，有固定安全诊断。
    sqlx::query(
        "CREATE TRIGGER deny_export_audit BEFORE INSERT ON audit_log \
         WHEN NEW.action LIKE 'audit.export.%' BEGIN SELECT RAISE(ABORT,'private-error'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    let final_task = start_audit_export(query("no-matches")).await.unwrap();
    let final_status = terminal(&pool, &final_task.task_id).await;
    assert_eq!(final_status.phase, "completed");
    assert_eq!(final_status.total_rows, 0);
    let audit_failure_copy = dir.join("audit-failure.csv").to_str().unwrap().to_owned();
    assert_eq!(
        save_audit_export_copy(final_task.task_id.clone(), audit_failure_copy.clone())
            .await
            .unwrap(),
        audit_failure_copy
    );
    assert_eq!(
        std::fs::read(&audit_failure_copy).unwrap(),
        std::fs::read(final_status.output_path.as_ref().unwrap()).unwrap()
    );
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let diagnostics = events::recent(500, Level::Warn);
            if diagnostics
                .iter()
                .filter(|event| {
                    event.correlation_id == final_task.task_id
                        && event.summary.contains("audit record failed")
                })
                .count()
                >= 2
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
    assert!(events::recent(500, Level::Warn)
        .iter()
        .filter(|event| event.correlation_id == final_task.task_id)
        .all(|event| !event.summary.contains("private-error")
            && !event.summary.contains("no-matches")));
    assert_eq!(
        start_audit_export(query("")).await.unwrap_err().code,
        "KEEL-VALIDATION"
    );
    assert_eq!(files(&dir), 2);
    assert!(path.exists(), "任务容量/清理不能删除用户已导出文件");
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
    remove_test_dir(path);
}
