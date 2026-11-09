//! 备份与恢复（真 SQLite）：创建、列表、保留份数、权限、登记恢复、启动时替换并保留旧库。
//! 当前用户是进程级状态，所以涉及权限的断言放在同一个测试里顺序执行。

use rust_lib_keel::api::diagnostics::DiagnosticPackRequest;
use rust_lib_keel::data;
use rust_lib_keel::domain::permissions::Role;
use rust_lib_keel::errors::KeelError;
use rust_lib_keel::services::access::{self, CurrentUser};
use rust_lib_keel::services::{audit, backup, diagnostic_pack};
use std::path::PathBuf;

// 当前用户是进程级共享状态；unix 下两个 tokio 测试并行会互相覆盖身份。
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn serial() -> tokio::sync::MutexGuard<'static, ()> {
    SERIAL.lock().await
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("keel-backup-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

async fn audit_count(pool: &sqlx::SqlitePool, keyword: &str) -> i64 {
    audit::list(pool, keyword.into(), "at".into(), true, 1, 50)
        .await
        .unwrap()
        .1
}

#[tokio::test]
async fn backup_restore_and_diagnostic_pack_flow() {
    let _serial = serial().await;
    let dir = temp_dir("flow");
    let db = dir.join("keel.db");
    let pool = data::open(&db).await.unwrap();
    access::init(&pool).await.unwrap(); // 默认管理员

    // 创建备份：文件存在、列表里有、审计有记录。
    audit::record(&pool, "before.backup", "x", "ok")
        .await
        .unwrap();
    let first = backup::create(&pool, &db).await.unwrap();
    assert!(backup::validate_name(&first.name).is_ok());
    assert!(backup::backups_dir(&db).join(&first.name).is_file());
    assert_eq!(backup::list(&db).unwrap().len(), 1);
    assert_eq!(audit_count(&pool, "backup.create").await, 1);
    backup::verify(&backup::backups_dir(&db).join(&first.name))
        .await
        .unwrap();

    // 保留策略：超过上限只留最新的。
    for _ in 0..(backup::KEEP + 2) {
        backup::create(&pool, &db).await.unwrap();
    }
    let kept = backup::list(&db).unwrap();
    assert_eq!(kept.len(), backup::KEEP);
    assert!(
        kept.iter().all(|f| f.name != first.name),
        "最旧的应已被清理"
    );

    // 备份之后再改数据库，用来证明恢复真的换回了旧状态。
    let target = kept[0].name.clone();
    audit::record(&pool, "after.backup", "x", "ok")
        .await
        .unwrap();

    // 查看者不能备份、不能恢复，并且被拒绝有审计记录。
    data::user::insert(&pool, "vera", "viewer", 1)
        .await
        .unwrap();
    access::switch_user(&pool, "vera").await.unwrap();
    assert!(matches!(
        backup::create(&pool, &db).await.unwrap_err(),
        KeelError::PermissionDenied(_)
    ));
    assert!(matches!(
        backup::schedule_restore(&pool, &db, &target)
            .await
            .unwrap_err(),
        KeelError::PermissionDenied(_)
    ));
    assert!(matches!(
        diagnostic_pack::prepare(
            &pool,
            DiagnosticPackRequest {
                categories: vec!["runtime".into()]
            },
            "0",
        )
        .await
        .unwrap_err(),
        KeelError::PermissionDenied(_)
    ));
    assert_eq!(audit_count(&pool, "permission.denied").await, 3);

    // 操作员可以备份和导出诊断包，但不能恢复。
    access::set_current(CurrentUser {
        name: "olga".into(),
        role: Role::Operator,
    });
    backup::create(&pool, &db).await.unwrap();
    let preview = diagnostic_pack::prepare(
        &pool,
        DiagnosticPackRequest {
            categories: vec!["runtime".into()],
        },
        "0.1.0",
    )
    .await
    .unwrap();
    let pack = diagnostic_pack::export_prepared(&pool, &db, &preview.preview_id)
        .await
        .unwrap();
    let text = std::fs::read_to_string(&pack).unwrap();
    assert!(text.starts_with("Keel diagnostic pack"));
    assert_eq!(text, preview.content, "导出必须使用预览的真实快照");
    assert!(matches!(
        backup::schedule_restore(&pool, &db, &target)
            .await
            .unwrap_err(),
        KeelError::PermissionDenied(_)
    ));

    // 管理员登记恢复：非法名字、不存在的备份被拒；合法的写下标记。
    access::set_current(CurrentUser {
        name: "local".into(),
        role: Role::Admin,
    });
    for bad in ["../keel-1.db", "keel-1.db/..", "x"] {
        assert!(matches!(
            backup::schedule_restore(&pool, &db, bad).await.unwrap_err(),
            KeelError::Validation(_)
        ));
    }
    assert!(matches!(
        backup::schedule_restore(&pool, &db, "keel-1.db")
            .await
            .unwrap_err(),
        KeelError::NotFound
    ));
    // 损坏的备份校验不通过，不会写标记。
    let broken = backup::backups_dir(&db).join("keel-2.db");
    std::fs::write(&broken, b"this is not a database").unwrap();
    assert!(matches!(
        backup::schedule_restore(&pool, &db, "keel-2.db")
            .await
            .unwrap_err(),
        KeelError::Backup(_)
    ));
    assert_eq!(backup::pending_restore(&db), None);
    std::fs::remove_file(&broken).unwrap();

    backup::schedule_restore(&pool, &db, &target).await.unwrap();
    assert_eq!(
        backup::pending_restore(&db).as_deref(),
        Some(target.as_str())
    );
    // 登记不会立刻改动当前数据库。
    assert_eq!(audit_count(&pool, "after.backup").await, 1);

    // viewer/operator 不能取消，原始标记保持不变；空标记也必须先授权。
    let marker = backup::marker_path(&db);
    let original = std::fs::read(&marker).unwrap();
    let denied_before = audit_count(&pool, "permission.denied").await;
    for (name, role) in [("vera", Role::Viewer), ("olga", Role::Operator)] {
        access::set_current(CurrentUser {
            name: name.into(),
            role,
        });
        assert!(matches!(
            backup::cancel_restore(&pool, &db).await.unwrap_err(),
            KeelError::PermissionDenied(_)
        ));
        assert_eq!(std::fs::read(&marker).unwrap(), original);
    }
    assert_eq!(
        audit_count(&pool, "permission.denied").await,
        denied_before + 2
    );
    assert_eq!(audit_count(&pool, "backup.restore.cancel").await, 0);

    access::set_current(CurrentUser {
        name: "local".into(),
        role: Role::Admin,
    });
    // request 审计失败：不能删除标记，也不能留下伪成功记录。
    sqlx::query(
        "CREATE TRIGGER reject_cancel_request BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'backup.restore.cancel.request' \
         BEGIN SELECT RAISE(ABORT, 'test audit failure'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    assert!(backup::cancel_restore(&pool, &db).await.is_err());
    assert_eq!(std::fs::read(&marker).unwrap(), original);
    assert_eq!(audit_count(&pool, "backup.restore.cancel").await, 0);
    sqlx::query("DROP TRIGGER reject_cancel_request")
        .execute(&pool)
        .await
        .unwrap();

    backup::cancel_restore(&pool, &db).await.unwrap();
    assert_eq!(backup::pending_restore(&db), None);
    let rows = audit::list(
        &pool,
        "backup.restore.cancel".into(),
        "at".into(),
        false,
        1,
        50,
    )
    .await
    .unwrap()
    .0;
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].action, "backup.restore.cancel.request");
    assert_eq!(rows[0].result, "requested");
    assert_eq!(rows[1].action, "backup.restore.cancel");
    assert_eq!(rows[1].result, "ok");
    assert!(rows
        .iter()
        .all(|row| row.actor == "local" && row.target == "pending restore"));
    backup::cancel_restore(&pool, &db).await.unwrap();
    assert_eq!(
        audit_count(&pool, "backup.restore.cancel").await,
        2,
        "幂等不新增审计"
    );

    access::set_current(CurrentUser {
        name: "vera".into(),
        role: Role::Viewer,
    });
    assert!(matches!(
        backup::cancel_restore(&pool, &db).await.unwrap_err(),
        KeelError::PermissionDenied(_)
    ));
    access::set_current(CurrentUser {
        name: "local".into(),
        role: Role::Admin,
    });

    // 删除后成功审计失败：诚实返回已取消，request 留存，不声称标记还在。
    backup::schedule_restore(&pool, &db, &target).await.unwrap();
    sqlx::query(
        "CREATE TRIGGER reject_cancel_ok BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'backup.restore.cancel' \
         BEGIN SELECT RAISE(ABORT, 'test audit failure'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    assert!(matches!(
        backup::cancel_restore(&pool, &db).await.unwrap_err(),
        KeelError::Backup(message) if message.contains("恢复已取消")
    ));
    assert!(!marker.exists());
    assert_eq!(audit_count(&pool, "backup.restore.cancel").await, 3);
    sqlx::query("DROP TRIGGER reject_cancel_ok")
        .execute(&pool)
        .await
        .unwrap();

    // 损坏正文不进入审计，仍可取消；删除失败只记 request。
    std::fs::write(&marker, b"/private/customer/password=secret").unwrap();
    backup::cancel_restore(&pool, &db).await.unwrap();
    assert!(!marker.exists());
    assert_eq!(audit_count(&pool, "secret").await, 0);
    std::fs::create_dir(&marker).unwrap();
    let count_before = audit_count(&pool, "backup.restore.cancel").await;
    assert!(matches!(
        backup::cancel_restore(&pool, &db).await.unwrap_err(),
        KeelError::Io(_)
    ));
    assert!(marker.is_dir());
    assert_eq!(
        audit_count(&pool, "backup.restore.cancel").await,
        count_before + 1
    );
    std::fs::remove_dir(&marker).unwrap();

    // join! 首先 poll 登记，登记持锁跨 verify/审计 await，取消必须排在其后。
    let (scheduled, cancelled) = tokio::join!(
        biased;
        backup::schedule_restore(&pool, &db, &target),
        backup::cancel_restore(&pool, &db),
    );
    scheduled.unwrap();
    cancelled.unwrap();
    assert!(!marker.exists());
    let rows = audit::list(&pool, "backup.restore.".into(), "at".into(), true, 1, 3)
        .await
        .unwrap()
        .0;
    assert_eq!(rows[0].action, "backup.restore.cancel");
    assert_eq!(rows[1].action, "backup.restore.cancel.request");
    assert_eq!(rows[2].action, "backup.restore.schedule");
    // 反向：先取消已有标记，再登记，最终应保留新标记。
    backup::schedule_restore(&pool, &db, &target).await.unwrap();
    let (cancelled, scheduled) = tokio::join!(
        biased;
        backup::cancel_restore(&pool, &db),
        backup::schedule_restore(&pool, &db, &target),
    );
    cancelled.unwrap();
    scheduled.unwrap();
    assert_eq!(
        backup::pending_restore(&db).as_deref(),
        Some(target.as_str())
    );
    let rows = audit::list(&pool, "backup.restore.".into(), "at".into(), true, 1, 3)
        .await
        .unwrap()
        .0;
    assert_eq!(rows[0].action, "backup.restore.schedule");
    assert_eq!(rows[1].action, "backup.restore.cancel");
    assert_eq!(rows[2].action, "backup.restore.cancel.request");

    // 关闭 pool 后用户取消失败保留标记；启动路径仍可独立执行。
    pool.close().await;
    assert!(backup::cancel_restore(&pool, &db).await.is_err());
    assert_eq!(
        backup::pending_restore(&db).as_deref(),
        Some(target.as_str())
    );

    // 下次启动：打开数据库之前执行恢复，旧数据库被改名保留。
    // Windows 关闭池后句柄释放略有延迟，模拟新进程启动前先等待。
    std::thread::sleep(std::time::Duration::from_millis(250));
    let restored = backup::apply_pending(&db).unwrap();
    assert_eq!(restored.as_deref(), Some(target.as_str()));
    assert_eq!(backup::pending_restore(&db), None);
    let kept_old: Vec<_> = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.contains(".pre-restore-"))
        .collect();
    assert!(!kept_old.is_empty(), "旧数据库应被保留");

    let pool = data::open(&db).await.unwrap();
    assert_eq!(
        audit_count(&pool, "before.backup").await,
        1,
        "备份前的数据还在"
    );
    assert_eq!(
        audit_count(&pool, "after.backup").await,
        0,
        "备份后的改动应被撤销"
    );

    // 没有标记时 apply_pending 什么也不做。
    assert_eq!(backup::apply_pending(&db).unwrap(), None);
    pool.close().await;

    let _ = std::fs::remove_dir_all(dir.as_path());
}

#[test]
fn startup_marker_cleanup_needs_neither_pool_nor_current_user() {
    // 同一集成测试进程中即使 async 测试正在切换用户，这条路径也不读取身份。
    let dir = temp_dir("startup-cleanup");
    let db = dir.join("keel.db");
    let marker = backup::marker_path(&db);
    assert_eq!(backup::apply_pending(&db).unwrap(), None);
    std::fs::write(&marker, b"../../private/path").unwrap();
    assert_eq!(backup::apply_pending(&db).unwrap(), None);
    assert!(!marker.exists());
    std::fs::write(&marker, b"keel-123.db").unwrap();
    assert!(matches!(
        backup::apply_pending(&db),
        Err(KeelError::NotFound)
    ));
    assert!(!marker.exists(), "启动恢复失败也清标记");
    remove_test_dir(&dir);
}

#[cfg(unix)]
#[tokio::test]
async fn restore_does_not_follow_marker_or_temporary_database_symlinks() {
    let _serial = serial().await;
    use std::os::unix::fs::symlink;

    let dir = temp_dir("symlink-boundary");
    let db = dir.join("keel.db");
    let pool = data::open(&db).await.unwrap();
    access::init(&pool).await.unwrap();
    let backup = backup::create(&pool, &db).await.unwrap();
    pool.close().await;

    let marker_target = dir.join("marker-target");
    std::fs::write(&marker_target, b"external-marker-content").unwrap();
    symlink(&marker_target, backup::marker_path(&db)).unwrap();
    let pool = data::open(&db).await.unwrap();
    assert!(matches!(
        backup::schedule_restore(&pool, &db, &backup.name)
            .await
            .unwrap_err(),
        KeelError::Validation(_)
    ));
    assert_eq!(
        std::fs::read_to_string(&marker_target).unwrap(),
        "external-marker-content"
    );
    std::fs::remove_file(backup::marker_path(&db)).unwrap();
    pool.close().await;

    let tmp_target = dir.join("tmp-target");
    std::fs::write(&tmp_target, b"external-tmp-content").unwrap();
    symlink(&tmp_target, db.with_file_name("keel.db.restore-tmp")).unwrap();
    std::fs::write(backup::marker_path(&db), backup.name.as_bytes()).unwrap();
    assert_eq!(
        backup::apply_pending(&db).unwrap().as_deref(),
        Some(backup.name.as_str())
    );
    assert_eq!(
        std::fs::read_to_string(&tmp_target).unwrap(),
        "external-tmp-content"
    );
    let _ = std::fs::remove_dir_all(dir);
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
