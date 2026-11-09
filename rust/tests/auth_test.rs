//! 登录保护：口令策略、开启/关闭、锁定与登录、审计与不落明文。
//! 当前用户是进程级状态，所有断言放在同一个测试里顺序执行。

use rust_lib_keel::data;
use rust_lib_keel::errors::KeelError;
use rust_lib_keel::services::{access, audit, auth};

const PASSWORD: &str = "keel-pass-2026";

async fn audit_rows(pool: &sqlx::SqlitePool, keyword: &str) -> Vec<data::audit::AuditRow> {
    audit::list(pool, keyword.into(), "at".into(), true, 1, 100)
        .await
        .unwrap()
        .0
}

#[tokio::test]
async fn login_gate_covers_password_policy_lock_and_audit() {
    let dir = std::env::temp_dir().join(format!("keel-auth-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let pool = data::open(&dir.join("main.db")).await.unwrap();
    access::init(&pool).await.unwrap();

    // 默认不要求登录，也没有口令。
    let status = auth::status(&pool).await.unwrap();
    assert!(!status.login_required);
    assert!(!status.has_password);
    assert!(!status.locked);
    assert!(!auth::required(&pool).await.unwrap());

    // 口令策略：过短、单字符重复、控制字符、超长都拒绝。
    for bad in ["short", "aaaaaaaa", "1234567\u{0007}", &"x".repeat(129)] {
        assert!(
            matches!(
                auth::set_password(&pool, None, bad).await.unwrap_err(),
                KeelError::Validation(_)
            ),
            "{bad:?} should be rejected"
        );
    }

    // 首次设置不需要当前口令；只存 Argon2id 校验值。
    auth::set_password(&pool, None, PASSWORD).await.unwrap();
    let status = auth::status(&pool).await.unwrap();
    assert!(status.has_password);
    assert!(!status.login_required);
    let stored: (String,) = sqlx::query_as("SELECT password_hash FROM app_security WHERE id = 1")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert!(stored.0.starts_with("$argon2"));
    assert!(!stored.0.contains(PASSWORD));

    // 已有口令后修改必须提供当前口令。
    assert!(matches!(
        auth::set_password(&pool, None, "another-pass-1")
            .await
            .unwrap_err(),
        KeelError::Auth
    ));
    assert!(matches!(
        auth::set_password(&pool, Some("wrong-pass-1"), "another-pass-1")
            .await
            .unwrap_err(),
        KeelError::Auth
    ));

    // 开启登录：口令不匹配拒绝；正确口令开启后仍在已解锁状态（当前会话不退出）。
    assert!(matches!(
        auth::set_login_required(&pool, true, "wrong-pass-1")
            .await
            .unwrap_err(),
        KeelError::Auth
    ));
    auth::set_login_required(&pool, true, PASSWORD)
        .await
        .unwrap();
    assert!(auth::required(&pool).await.unwrap());
    let status = auth::status(&pool).await.unwrap();
    assert!(status.login_required);
    assert!(!status.locked);

    // 锁定后当前用户被清除，错误口令不会恢复。
    auth::lock(&pool).await.unwrap();
    assert!(access::current().is_err());
    assert!(auth::status(&pool).await.unwrap().locked);
    assert!(!auth::sign_in(&pool, "wrong-pass-1").await.unwrap());
    assert!(access::current().is_err(), "失败登录不得发布用户");

    // 正确口令恢复默认用户。
    assert!(auth::sign_in(&pool, PASSWORD).await.unwrap());
    assert_eq!(access::current().unwrap().name, access::DEFAULT_USER);

    // 关闭登录保护需要当前口令。
    assert!(matches!(
        auth::set_login_required(&pool, false, "wrong-pass-1")
            .await
            .unwrap_err(),
        KeelError::Auth
    ));
    auth::set_login_required(&pool, false, PASSWORD)
        .await
        .unwrap();
    assert!(!auth::required(&pool).await.unwrap());

    // 审计：口令设置、开启/关闭、登录成功与失败、锁定各一条以上。
    for action in [
        "auth.password.set",
        "auth.protect.enable",
        "auth.protect.disable",
        "auth.login",
        "auth.lock",
    ] {
        assert!(
            !audit_rows(&pool, action).await.is_empty(),
            "missing audit {action}"
        );
    }
    let failed = audit_rows(&pool, "auth.login").await;
    assert!(failed.iter().any(|row| row.result == "failed"));
    assert!(failed.iter().any(|row| row.result == "ok"));

    let _ = std::fs::remove_dir_all(&dir);
}
