//! 当前用户与用户管理。注意：这是应用内权限，不是对本机管理员的安全隔离。

use crate::api::error::ApiError;
use crate::data::user;
use crate::domain::permissions::Role;
use crate::services::access;
use crate::state;

pub struct UserInfo {
    pub name: String,
    /// "admin" | "operator" | "viewer"
    pub role: String,
    /// 该角色拥有的权限名。界面据此决定入口是否可用（仅作提示，Rust 边界仍会再校验）
    pub permissions: Vec<String>,
}

fn info(name: String, role: Role) -> UserInfo {
    UserInfo {
        name,
        role: role.as_str().to_string(),
        permissions: role
            .permissions()
            .iter()
            .map(|p| p.as_str().to_string())
            .collect(),
    }
}

/// 当前用户。数据库还没初始化时返回 `KEEL-UNINITIALIZED`。
pub async fn current_user() -> Result<UserInfo, ApiError> {
    let me = access::current()?;
    Ok(info(me.name, me.role))
}

/// 列出所有本地用户的名字和角色，供"切换用户"使用，不需要权限。
/// 本地应用没有密码登录，切换用户本来就不是安全边界，所以这里不设门槛。
pub async fn list_users() -> Result<Vec<UserInfo>, ApiError> {
    let rows = user::list(state::pool()?).await?;
    let mut users = Vec::with_capacity(rows.len());
    for row in rows {
        let role = Role::parse(&row.role).ok_or_else(|| {
            crate::errors::KeelError::internal(format!("用户 {} 的角色无法识别", row.id))
        })?;
        users.push(info(row.name, role));
    }
    Ok(users)
}

/// 创建用户。需要"管理用户"权限（`KEEL-PERMISSION`）；用户名重复返回 `KEEL-DUPLICATE`。
pub async fn create_user(name: String, role: String) -> Result<(), ApiError> {
    access::create_user(state::pool()?, &name, &role).await?;
    Ok(())
}

/// Atomically create viewer/operator users from bounded UTF-8 JSONL.
pub async fn import_users_jsonl(input: Vec<u8>) -> Result<u32, ApiError> {
    let cancelled = std::sync::atomic::AtomicBool::new(false);
    Ok(crate::services::user_import::import_jsonl(state::pool()?, &input, &cancelled).await?)
}

/// Reserve an identity-bound, single-use import handle before submitting data.
pub async fn prepare_user_import() -> Result<String, ApiError> {
    Ok(crate::services::user_import::prepare(state::pool()?).await?)
}

/// Cancellation is cooperative until the check preceding COMMIT.
pub async fn run_user_import(ticket_id: String, input: Vec<u8>) -> Result<u32, ApiError> {
    Ok(crate::services::user_import::run_prepared(state::pool()?, &ticket_id, &input).await?)
}

/// Acknowledges a request; await run_user_import for the final transaction result.
pub fn cancel_user_import(ticket_id: String) -> Result<(), ApiError> {
    Ok(crate::services::user_import::cancel(&ticket_id)?)
}

pub struct UserImportProgress {
    /// Provisional rows in the transaction, not committed users.
    pub processed: u32,
    pub total: u32,
}

/// None means the handle is no longer observable. Only run_user_import supplies
/// the transaction result; a missing handle must never imply success.
pub fn user_import_progress(ticket_id: String) -> Result<Option<UserImportProgress>, ApiError> {
    Ok(crate::services::user_import::progress(&ticket_id)?
        .map(|(processed, total)| UserImportProgress { processed, total }))
}

/// 切换当前用户，并写一条审计。用户不存在返回 `KEEL-NOT-FOUND`。
pub async fn switch_user(name: String) -> Result<UserInfo, ApiError> {
    let me = access::switch_user(state::pool()?, &name).await?;
    Ok(info(me.name, me.role))
}
