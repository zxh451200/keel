//! 当前用户与权限检查。注意：这是应用内权限，不是对本机管理员的安全隔离——
//! 本地应用没有密码登录，切换用户本来就不是安全边界（AGENTS.md §11）。
//! 它的作用是让误操作更难发生，并让每次敏感操作都留下"谁做的"的审计记录。

use crate::data::user::UserRow;
use crate::data::{audit as audit_data, user};
use crate::domain::permissions::{Permission, Role};
use crate::errors::KeelError;
use crate::services::audit;
use sqlx::SqlitePool;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::RwLock;
use tokio::sync::Mutex;

/// 首次启动时自动创建的管理员。
pub const DEFAULT_USER: &str = "local";

/// 用户名长度上限（按字符数）。
const MAX_NAME_CHARS: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurrentUser {
    pub name: String,
    pub role: Role,
}

static CURRENT: RwLock<Option<CurrentUser>> = RwLock::new(None);
static SWITCH_LOCK: Mutex<()> = Mutex::const_new(());
static IDENTITY_EPOCH: AtomicU64 = AtomicU64::new(0);

/// Serializes an identity-bound transaction with user switching.
pub(crate) async fn lock_identity() -> tokio::sync::MutexGuard<'static, ()> {
    SWITCH_LOCK.lock().await
}

/// Read user and generation under the same lock; A→B→A changes the token.
pub(crate) fn identity_snapshot() -> Result<(CurrentUser, String), KeelError> {
    let current = CURRENT.read().unwrap_or_else(|e| e.into_inner());
    let user = current.clone().ok_or(KeelError::Uninitialized)?;
    Ok((user, IDENTITY_EPOCH.load(Ordering::SeqCst).to_string()))
}

fn row_to_user(row: &UserRow) -> Result<CurrentUser, KeelError> {
    let role = Role::parse(&row.role)
        .ok_or_else(|| KeelError::internal(format!("用户 {} 的角色无法识别", row.id)))?;
    Ok(CurrentUser {
        name: row.name.clone(),
        role,
    })
}

pub fn set_current(user: CurrentUser) {
    let mut current = CURRENT.write().unwrap_or_else(|e| e.into_inner());
    IDENTITY_EPOCH.fetch_add(1, Ordering::SeqCst);
    *current = Some(user);
}

/// 锁定：清除当前用户但不改数据库；之后 `current()` 返回 `KEEL-UNINITIALIZED`。
pub fn clear_current() {
    let mut current = CURRENT.write().unwrap_or_else(|e| e.into_inner());
    IDENTITY_EPOCH.fetch_add(1, Ordering::SeqCst);
    *current = None;
}

/// 当前用户；数据库还没初始化好之前是 `KEEL-UNINITIALIZED`。
pub fn current() -> Result<CurrentUser, KeelError> {
    CURRENT
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .ok_or(KeelError::Uninitialized)
}

/// 当前用户的名字，没有时按默认用户（给审计用，不让记审计这件事本身失败）。
pub fn current_name() -> String {
    current()
        .map(|u| u.name)
        .unwrap_or_else(|_| DEFAULT_USER.to_string())
}

/// 准备默认用户，但不发布进程级当前用户。启动完成后才对其他调用可见。
pub async fn load_default(pool: &SqlitePool) -> Result<CurrentUser, KeelError> {
    let row = match user::find_by_name(pool, DEFAULT_USER).await? {
        Some(row) => row,
        None => {
            user::insert(pool, DEFAULT_USER, Role::Admin.as_str(), audit::now_ms()).await?;
            user::find_by_name(pool, DEFAULT_USER)
                .await?
                .ok_or(KeelError::NotFound)?
        }
    };
    row_to_user(&row)
}

/// 独立服务测试/调用使用；应用启动由 startup 在所有准备步骤成功后发布用户。
pub async fn init(pool: &SqlitePool) -> Result<(), KeelError> {
    set_current(load_default(pool).await?);
    Ok(())
}

/// 检查当前用户有没有某项权限。没有时写一条 `permission.denied` 审计并返回 `KEEL-PERMISSION`。
pub async fn require(pool: &SqlitePool, permission: Permission) -> Result<CurrentUser, KeelError> {
    let me = current()?;
    if me.role.allows(permission) {
        return Ok(me);
    }
    // 审计写失败不能掩盖真正的权限错误。
    let _ = audit::record_as(
        pool,
        &me.name,
        "permission.denied",
        permission.as_str(),
        "denied",
    )
    .await;
    Err(KeelError::PermissionDenied(permission.as_str().to_string()))
}

pub(crate) fn validate_name(name: &str) -> Result<String, KeelError> {
    let name = name.trim();
    let count = name.chars().count();
    if count == 0 || count > MAX_NAME_CHARS {
        return Err(KeelError::Validation(format!(
            "用户名需为 1 到 {MAX_NAME_CHARS} 个字符"
        )));
    }
    if name.chars().any(|c| c.is_control()) {
        return Err(KeelError::Validation("用户名不能包含控制字符".into()));
    }
    Ok(name.to_string())
}

/// 创建用户。需要"管理用户"权限；用户名重复返回 `KEEL-DUPLICATE`。
pub async fn create_user(pool: &SqlitePool, name: &str, role: &str) -> Result<(), KeelError> {
    // Keep the actor and the transaction stable while switching users is possible.
    // The import path already uses this lock for the same identity-bound contract.
    let _identity_guard = lock_identity().await;
    let me = require(pool, Permission::UserManage).await?;
    let name = validate_name(name)?;
    let role = Role::parse(role)
        .ok_or_else(|| KeelError::Validation("角色需为 admin / operator / viewer".into()))?;

    let mut transaction = pool.begin().await?;
    user::insert_conn(transaction.as_mut(), &name, role.as_str(), audit::now_ms()).await?;
    audit_data::insert_conn(
        transaction.as_mut(),
        audit::now_ms(),
        &me.name,
        "user.create",
        &name,
        "ok",
        "",
    )
    .await?;
    transaction.commit().await?;
    Ok(())
}

/// 切换当前用户（本地应用没有密码，见文件头说明），切换本身写审计。
pub async fn switch_user(pool: &SqlitePool, name: &str) -> Result<CurrentUser, KeelError> {
    let _switch_guard = SWITCH_LOCK.lock().await;
    let old = current()?;
    let row = user::find_by_name(pool, name.trim())
        .await?
        .ok_or(KeelError::NotFound)?;
    let next = row_to_user(&row)?;
    // 先以原用户身份记录切换，写入失败时不发布新用户。
    audit::record_as(pool, &old.name, "user.switch", &next.name, "ok").await?;
    set_current(next.clone());
    Ok(next)
}
