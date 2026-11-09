//! 单独集成测试二进制，只有一个顺序测试，避免 CURRENT 与其他测试并行互扰。
use rust_lib_keel::api::diagnostics::{
    export_prepared_diagnostic_pack, prepare_diagnostic_pack, DiagnosticPackRequest,
};
use rust_lib_keel::diagnostics::events::{self, Level};
use rust_lib_keel::domain::permissions::Role;
use rust_lib_keel::services::{access, audit, diagnostic_pack};
use rust_lib_keel::{data, state};

fn request(categories: &[&str]) -> DiagnosticPackRequest {
    DiagnosticPackRequest {
        categories: categories.iter().map(|c| (*c).into()).collect(),
    }
}

fn set_user(name: &str, role: Role) {
    access::set_current(access::CurrentUser {
        name: name.into(),
        role,
    });
}

#[tokio::test]
async fn prepared_pack_security_snapshot_and_failure_lifecycle() {
    let dir = std::env::temp_dir().join(format!("keel-diagnostic-pack-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("main.db");
    let pool = data::open(&db).await.unwrap();
    state::set_db_path(&db);
    state::set_pool(pool.clone());
    access::init(&pool).await.unwrap();
    let me = access::current().unwrap();

    for invalid in [request(&[]), request(&["runtime", "raw_logs"])] {
        assert_eq!(
            prepare_diagnostic_pack(invalid).await.unwrap_err().code,
            "KEEL-VALIDATION"
        );
    }
    events::record(
        Level::Error,
        "snapshot-test",
        "KEEL-IO",
        "pack-test",
        "before-prepare-marker password=pack-secret C:\\Users\\packuser\\private",
    );
    let runtime = prepare_diagnostic_pack(request(&["runtime"]))
        .await
        .unwrap();
    assert_eq!(runtime.categories, vec!["runtime"]);
    assert_eq!(runtime.event_count, 0);
    assert!(!runtime.content.contains("before-prepare-marker"));

    let preview = prepare_diagnostic_pack(request(&["recent_events", "runtime", "runtime"]))
        .await
        .unwrap();
    assert_eq!(preview.categories, vec!["runtime", "recent_events"]);
    assert!(preview.event_count > 0 && preview.event_count <= 500);
    assert!(preview.content.contains("before-prepare-marker"));
    assert!(!preview.content.contains("pack-secret"));
    assert!(!preview.content.contains("packuser"));
    events::record(Level::Warn, "snapshot-test", "", "", "after-prepare-marker");
    let path = export_prepared_diagnostic_pack(preview.preview_id.clone())
        .await
        .unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), preview.content.as_bytes());
    assert!(!std::fs::read_to_string(&path)
        .unwrap()
        .contains("after-prepare-marker"));
    assert_eq!(
        export_prepared_diagnostic_pack(preview.preview_id.clone())
            .await
            .unwrap_err()
            .code,
        "KEEL-VALIDATION"
    );

    // 两个并发导出只允许一个成功。
    let concurrent = prepare_diagnostic_pack(request(&["runtime"]))
        .await
        .unwrap();
    let (a, b) = tokio::join!(
        export_prepared_diagnostic_pack(concurrent.preview_id.clone()),
        export_prepared_diagnostic_pack(concurrent.preview_id.clone())
    );
    assert_ne!(a.is_ok(), b.is_ok());

    // viewer 无法 prepare/export，但旧预览只能拿到不敏感 runtime。
    let protected = prepare_diagnostic_pack(request(&["recent_events"]))
        .await
        .unwrap();
    set_user(&me.name, Role::Viewer);
    assert_eq!(
        prepare_diagnostic_pack(request(&["runtime"]))
            .await
            .unwrap_err()
            .code,
        "KEEL-PERMISSION"
    );
    assert_eq!(
        export_prepared_diagnostic_pack(protected.preview_id.clone())
            .await
            .unwrap_err()
            .code,
        "KEEL-PERMISSION"
    );
    assert!(!diagnostic_pack::preview("test").contains("before-prepare-marker"));

    // 即使新用户也有导出权限，名字或角色不同仍不能复用 token。
    for (name, role) in [
        ("other-admin", Role::Admin),
        (me.name.as_str(), Role::Operator),
    ] {
        set_user(name, role);
        assert_eq!(
            export_prepared_diagnostic_pack(protected.preview_id.clone())
                .await
                .unwrap_err()
                .code,
            "KEEL-PERMISSION"
        );
    }
    access::set_current(me.clone());
    let path = export_prepared_diagnostic_pack(protected.preview_id.clone())
        .await
        .unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), protected.content.as_bytes());

    let rows: Vec<_> = audit::list_filtered(
        &pool,
        &data::audit::ListParams {
            keyword: "diagnostics.export".into(),
            sort: vec![data::audit::SortKey {
                field: "at".into(),
                descending: true,
            }],
            page: 1,
            page_size: 200,
            start_at_ms: None,
            end_at_ms_exclusive: None,
        },
    )
    .await
    .unwrap()
    .0
    .into_iter()
    .filter(|row| row.action == "diagnostics.export")
    .collect();
    assert_eq!(rows.len(), 3);
    for row in rows {
        assert_eq!(row.actor, me.name);
        assert_eq!(row.target, "diagnostic pack");
        assert_eq!(row.result, "ok");
        assert!(!format!("{row:?}").contains(&protected.preview_id));
        assert!(!format!("{row:?}").contains("before-prepare-marker"));
    }

    // 文件失败后释放快照，修复目录也不能重用已消费的句柄。
    let bad_dir = dir.join("blocked");
    std::fs::write(&bad_dir, "not a directory").unwrap();
    let failed = diagnostic_pack::prepare(&pool, request(&["runtime"]), "test")
        .await
        .unwrap();
    let error =
        diagnostic_pack::export_prepared(&pool, &bad_dir.join("main.db"), &failed.preview_id)
            .await
            .unwrap_err();
    assert_eq!(error.code(), "KEEL-IO");
    assert_eq!(
        export_prepared_diagnostic_pack(failed.preview_id)
            .await
            .unwrap_err()
            .code,
        "KEEL-VALIDATION"
    );

    // 审计失败不报告成功，不保留文件，且 token 已消费。
    sqlx::query(
        "CREATE TRIGGER reject_diagnostic_export BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'diagnostics.export' \
         BEGIN SELECT RAISE(ABORT, 'test: reject export audit'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    let failed = prepare_diagnostic_pack(request(&["runtime"]))
        .await
        .unwrap();
    let export_dir = diagnostic_pack::export_dir(&db);
    let before = std::fs::read_dir(&export_dir).unwrap().count();
    assert_eq!(
        export_prepared_diagnostic_pack(failed.preview_id.clone())
            .await
            .unwrap_err()
            .code,
        "KEEL-DB"
    );
    assert_eq!(std::fs::read_dir(&export_dir).unwrap().count(), before);
    assert_eq!(
        export_prepared_diagnostic_pack(failed.preview_id)
            .await
            .unwrap_err()
            .code,
        "KEEL-VALIDATION"
    );
    sqlx::query("DROP TRIGGER reject_diagnostic_export")
        .execute(&pool)
        .await
        .unwrap();

    // 正文大小有界：拒绝超限快照，随后正常 prepare/export 仍可用。
    events::record(
        Level::Info,
        "snapshot-test",
        "",
        "",
        &"x".repeat(1024 * 1024 + 1),
    );
    assert_eq!(
        prepare_diagnostic_pack(request(&["recent_events"]))
            .await
            .unwrap_err()
            .code,
        "KEEL-VALIDATION"
    );
    let path = export_prepared_diagnostic_pack(runtime.preview_id)
        .await
        .unwrap();
    assert_eq!(std::fs::read(path).unwrap(), runtime.content.as_bytes());

    // 全局 API 缓存的容量也确实受限；runtime prepare 不受超大事件影响。
    let mut ids = Vec::new();
    for _ in 0..7 {
        ids.push(
            prepare_diagnostic_pack(request(&["runtime"]))
                .await
                .unwrap()
                .preview_id,
        );
    }
    assert_eq!(
        export_prepared_diagnostic_pack(ids[0].clone())
            .await
            .unwrap_err()
            .code,
        "KEEL-VALIDATION"
    );
    assert!(export_prepared_diagnostic_pack(ids[6].clone())
        .await
        .is_ok());

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
