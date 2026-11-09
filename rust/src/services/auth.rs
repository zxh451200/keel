//! 应用级登录保护：Argon2id 校验值 + 开关。
//!
//! 边界（需求 §4.1/S05、AGENTS §11）：这是"离开工位时挡住随手打开"的门禁，
//! 不是对本机管理员的隔离——能读到用户数据目录的人可以离线尝试口令，
//! 也可以直接删库绕过。口令只以 Argon2id 校验值保存，配置文件和日志不含明文。

use crate::data::auth as auth_data;
use crate::data::auth::SecurityRow;
use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::{access, audit};
use argon2::password_hash::{rand_core::OsRng, PasswordHash, SaltString};
use argon2::{Argon2, PasswordHasher, PasswordVerifier};
use sqlx::SqlitePool;
use tokio::sync::Mutex;

pub const MIN_PASSWORD_CHARS: usize = 8;
pub const MAX_PASSWORD_CHARS: usize = 128;

static AUTH_LOCK: Mutex<()> = Mutex::const_new(());

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthStatus {
    pub login_required: bool,
    pub has_password: bool,
    pub locked: bool,
}

fn hash_password(password: &str) -> Result<String, KeelError> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|_| KeelError::internal("口令校验值生成失败"))
}

fn verify_password(hash: &str, password: &str) -> bool {
    PasswordHash::new(hash).is_ok_and(|parsed| {
        Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok()
    })
}

/// 8–128 个字符、不含控制字符、不是同一个字符重复。
pub fn validate_password(password: &str) -> Result<(), KeelError> {
    let count = password.chars().count();
    if !(MIN_PASSWORD_CHARS..=MAX_PASSWORD_CHARS).contains(&count) {
        return Err(KeelError::Validation(format!(
            "口令长度需为 {MIN_PASSWORD_CHARS} 到 {MAX_PASSWORD_CHARS} 个字符"
        )));
    }
    if password.chars().any(char::is_control) {
        return Err(KeelError::Validation("口令不能包含控制字符".into()));
    }
    let mut chars = password.chars();
    if let Some(first) = chars.next() {
        if chars.all(|c| c == first) {
            return Err(KeelError::Validation("口令不能是同一个字符重复".into()));
        }
    }
    Ok(())
}

/// 启动时用：是否需要登录才能继续。读失败按"不需要"处理，不把用户锁在门外。
pub async fn required(pool: &SqlitePool) -> Result<bool, KeelError> {
    Ok(auth_data::load(pool)
        .await?
        .is_some_and(|row| row.login_required))
}

pub async fn status(pool: &SqlitePool) -> Result<AuthStatus, KeelError> {
    let row = auth_data::load(pool).await?;
    let login_required = row.as_ref().is_some_and(|row| row.login_required);
    Ok(AuthStatus {
        login_required,
        has_password: row.as_ref().is_some_and(|row| row.password_hash.is_some()),
        // 没有发布当前用户 = 仍处于锁定状态。
        locked: login_required && access::current().is_err(),
    })
}

async fn load_row(pool: &SqlitePool) -> Result<SecurityRow, KeelError> {
    Ok(auth_data::load(pool).await?.unwrap_or(SecurityRow {
        password_hash: None,
        login_required: false,
        updated_at: 0,
    }))
}

/// 设置或修改口令。已有口令时必须提供当前口令；需要管理用户权限。
pub async fn set_password(
    pool: &SqlitePool,
    current_password: Option<&str>,
    new_password: &str,
) -> Result<(), KeelError> {
    let me = access::require(pool, Permission::UserManage).await?;
    validate_password(new_password)?;
    let _guard = AUTH_LOCK.lock().await;
    let row = load_row(pool).await?;
    if let Some(hash) = row.password_hash.as_deref() {
        if !current_password.is_some_and(|current| verify_password(hash, current)) {
            return Err(KeelError::Auth);
        }
    }
    let hash = hash_password(new_password)?;
    auth_data::save(pool, Some(&hash), row.login_required, audit::now_ms()).await?;
    let _ = audit::record_as(pool, &me.name, "auth.password.set", "application", "ok").await;
    Ok(())
}

/// 打开/关闭登录保护。开启时若尚未设置口令，则本次口令即为新口令；
/// 已有口令时口令必须匹配。关闭同样需要当前口令。
pub async fn set_login_required(
    pool: &SqlitePool,
    enabled: bool,
    password: &str,
) -> Result<(), KeelError> {
    let me = access::require(pool, Permission::UserManage).await?;
    let _guard = AUTH_LOCK.lock().await;
    let row = load_row(pool).await?;
    if enabled == row.login_required {
        return Ok(());
    }
    let mut next_hash = row.password_hash.clone();
    if enabled {
        match row.password_hash.as_deref() {
            Some(hash) => {
                if !verify_password(hash, password) {
                    return Err(KeelError::Auth);
                }
            }
            None => {
                validate_password(password)?;
                next_hash = Some(hash_password(password)?);
            }
        }
    } else {
        let Some(hash) = row.password_hash.as_deref() else {
            return Err(KeelError::Auth);
        };
        if !verify_password(hash, password) {
            return Err(KeelError::Auth);
        }
    }
    auth_data::save(pool, next_hash.as_deref(), enabled, audit::now_ms()).await?;
    let _ = audit::record_as(
        pool,
        &me.name,
        if enabled {
            "auth.protect.enable"
        } else {
            "auth.protect.disable"
        },
        "application",
        "ok",
    )
    .await;
    Ok(())
}

/// 登录：通过后发布默认本地用户；失败返回 false（不泄露是"口令错"还是"未设置"）。
pub async fn sign_in(pool: &SqlitePool, password: &str) -> Result<bool, KeelError> {
    let row = load_row(pool).await?;
    if !row.login_required {
        // 未开启登录保护时，恢复默认用户即可（与启动路径一致）。
        if access::current().is_err() {
            access::set_current(access::load_default(pool).await?);
        }
        return Ok(true);
    }
    let Some(hash) = row.password_hash.as_deref() else {
        return Ok(false);
    };
    if verify_password(hash, password) {
        let user = access::load_default(pool).await?;
        access::set_current(user.clone());
        let _ = audit::record_as(pool, &user.name, "auth.login", "application", "ok").await;
        return Ok(true);
    }
    // 失败也写审计；限速放在调用方，服务层保持可测试。
    let _ = audit::record_as(
        pool,
        access::DEFAULT_USER,
        "auth.login",
        "application",
        "failed",
    )
    .await;
    // 固定延迟降低在线试错速度；本机离线爆破不在防护范围（见文件头边界）。
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    Ok(false)
}

/// 立即锁定（只在开启登录保护时生效）。
pub async fn lock(pool: &SqlitePool) -> Result<(), KeelError> {
    let row = load_row(pool).await?;
    if !row.login_required {
        return Ok(());
    }
    let actor = access::current().ok().map(|user| user.name);
    access::clear_current();
    if let Some(actor) = actor {
        let _ = audit::record_as(pool, &actor, "auth.lock", "application", "ok").await;
    }
    Ok(())
}
