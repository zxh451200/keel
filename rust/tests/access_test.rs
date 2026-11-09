//! 用户与权限：默认管理员、创建用户、权限检查与审计、切换用户。
//! 当前用户是进程级状态，所以所有断言放在同一个测试里顺序执行。

use rust_lib_keel::data;
use rust_lib_keel::domain::permissions::{Permission, Role};
use rust_lib_keel::errors::KeelError;
use rust_lib_keel::services::{access, audit};

async fn audit_rows(pool: &sqlx::SqlitePool, keyword: &str) -> Vec<data::audit::AuditRow> {
    audit::list(pool, keyword.into(), "at".into(), true, 1, 50)
        .await
        .unwrap()
        .0
}

#[tokio::test]
async fn users_permissions_and_audit_trail() {
    let dir = std::env::temp_dir().join(format!("keel-access-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let pool = data::open(&dir.join("main.db")).await.unwrap();

    // 首次启动：自动有一个管理员，并且是当前用户。
    access::init(&pool).await.unwrap();
    let me = access::current().unwrap();
    assert_eq!(me.name, access::DEFAULT_USER);
    assert_eq!(me.role, Role::Admin);
    // 重复初始化不会重复创建。
    access::init(&pool).await.unwrap();
    assert_eq!(data::user::list(&pool).await.unwrap().len(), 1);

    // 管理员可以创建用户；重复名字、非法角色、空名字被拒绝。
    access::create_user(&pool, "olive", "operator")
        .await
        .unwrap();
    assert!(matches!(
        access::create_user(&pool, "olive", "viewer")
            .await
            .unwrap_err(),
        KeelError::Duplicate
    ));
    assert!(matches!(
        access::create_user(&pool, "x", "root").await.unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        access::create_user(&pool, "   ", "viewer")
            .await
            .unwrap_err(),
        KeelError::Validation(_)
    ));
    // Creation uses the same Rust-side name contract as JSONL import.
    assert!(matches!(
        access::create_user(&pool, "a\u{0000}b", "viewer")
            .await
            .unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        access::create_user(&pool, &"x".repeat(33), "viewer")
            .await
            .unwrap_err(),
        KeelError::Validation(_)
    ));
    access::create_user(&pool, "  中文  ", "viewer")
        .await
        .unwrap();
    assert!(data::user::find_by_name(&pool, "中文")
        .await
        .unwrap()
        .is_some());

    // 创建动作记在管理员名下。
    let created = audit_rows(&pool, "user.create").await;
    assert_eq!(created.len(), 2);
    let olive = created.iter().find(|row| row.target == "olive").unwrap();
    assert_eq!(olive.actor, access::DEFAULT_USER);
    let chinese = created.iter().find(|row| row.target == "中文").unwrap();
    assert_eq!(chinese.actor, access::DEFAULT_USER);

    // 创建用户和成功审计必须同事务：审计被拒绝时，用户插入也要回滚。
    sqlx::query(
        "CREATE TRIGGER reject_user_create BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'user.create' \
         BEGIN SELECT RAISE(ABORT, 'test: reject user create audit'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    assert!(access::create_user(&pool, "rollback-user", "viewer")
        .await
        .is_err());
    assert!(data::user::find_by_name(&pool, "rollback-user")
        .await
        .unwrap()
        .is_none());
    assert_eq!(audit_rows(&pool, "user.create").await.len(), 2);
    sqlx::query("DROP TRIGGER reject_user_create")
        .execute(&pool)
        .await
        .unwrap();
    access::create_user(&pool, "rollback-user", "viewer")
        .await
        .unwrap();
    assert!(data::user::find_by_name(&pool, "rollback-user")
        .await
        .unwrap()
        .is_some());
    assert_eq!(audit_rows(&pool, "user.create").await.len(), 3);

    // 切换成操作员：能看审计，但不能创建用户，并且被拒绝这件事有审计记录。
    let switched = access::switch_user(&pool, "olive").await.unwrap();
    assert_eq!(switched.role, Role::Operator);
    let switches = audit_rows(&pool, "user.switch").await;
    assert_eq!(switches.len(), 1);
    assert_eq!(switches[0].actor, access::DEFAULT_USER);
    assert_eq!(switches[0].target, "olive");
    access::require(&pool, Permission::AuditRead).await.unwrap();
    let denied = access::create_user(&pool, "mallory", "admin")
        .await
        .unwrap_err();
    assert!(matches!(denied, KeelError::PermissionDenied(_)));
    assert_eq!(denied.code(), "KEEL-PERMISSION");
    assert!(data::user::find_by_name(&pool, "mallory")
        .await
        .unwrap()
        .is_none());

    let denials = audit_rows(&pool, "permission.denied").await;
    assert_eq!(denials.len(), 1);
    assert_eq!(denials[0].actor, "olive");
    assert_eq!(denials[0].target, "users.manage");

    // 切换到不存在的用户：NOT-FOUND，当前用户不变。
    assert!(matches!(
        access::switch_user(&pool, "ghost").await.unwrap_err(),
        KeelError::NotFound
    ));
    assert_eq!(access::current().unwrap().name, "olive");

    // 审计写入失败时，切换必须失败且保留原用户。
    sqlx::query(
        "CREATE TRIGGER reject_user_switch BEFORE INSERT ON audit_log \
         WHEN NEW.action = 'user.switch' \
         BEGIN SELECT RAISE(ABORT, 'test: reject user switch audit'); END",
    )
    .execute(&pool)
    .await
    .unwrap();
    assert!(access::switch_user(&pool, access::DEFAULT_USER)
        .await
        .is_err());
    assert_eq!(access::current().unwrap().name, "olive");
    assert_eq!(access::current().unwrap().role, Role::Operator);
    assert_eq!(audit_rows(&pool, "user.switch").await.len(), 1);
    sqlx::query("DROP TRIGGER reject_user_switch")
        .execute(&pool)
        .await
        .unwrap();

    // 审计恢复后可以重试，切回管理员，操作者仍是原用户。
    access::switch_user(&pool, access::DEFAULT_USER)
        .await
        .unwrap();
    assert_eq!(access::current().unwrap().role, Role::Admin);
    let switches = audit_rows(&pool, "user.switch").await;
    assert_eq!(switches.len(), 2);
    let switched_back = switches
        .iter()
        .find(|row| row.target == access::DEFAULT_USER)
        .unwrap();
    assert_eq!(switched_back.actor, "olive");

    let _ = std::fs::remove_dir_all(dir.as_path());
}
