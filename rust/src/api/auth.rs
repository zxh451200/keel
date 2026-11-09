//! 登录门禁的跨语言入口。口令校验值只存在数据库，不经过桥接返回。

use crate::api::error::ApiError;
use crate::services::auth;
use crate::state;

pub struct AuthStatusDto {
    /// 是否要求登录后才能使用。
    pub login_required: bool,
    /// 是否已经设置过口令。
    pub has_password: bool,
    /// 当前是否停在登录页（已开启登录保护且尚未认证）。
    pub locked: bool,
}

pub async fn auth_status() -> Result<AuthStatusDto, ApiError> {
    let status = auth::status(state::pool()?).await?;
    Ok(AuthStatusDto {
        login_required: status.login_required,
        has_password: status.has_password,
        locked: status.locked,
    })
}

/// 通过返回 true；口令错误或未设置返回 false（不区分原因）。
pub async fn sign_in(password: String) -> Result<bool, ApiError> {
    Ok(auth::sign_in(state::pool()?, &password).await?)
}

/// 立即锁定；未开启登录保护时为空操作。
pub async fn lock_app() -> Result<(), ApiError> {
    Ok(auth::lock(state::pool()?).await?)
}

/// 设置或修改口令；需要管理用户权限，已有口令时必须提供当前口令。
pub async fn set_login_password(
    current_password: Option<String>,
    new_password: String,
) -> Result<(), ApiError> {
    Ok(auth::set_password(state::pool()?, current_password.as_deref(), &new_password).await?)
}

/// 打开/关闭登录保护；需要管理用户权限与正确口令。
pub async fn set_login_required(enabled: bool, password: String) -> Result<(), ApiError> {
    Ok(auth::set_login_required(state::pool()?, enabled, &password).await?)
}
