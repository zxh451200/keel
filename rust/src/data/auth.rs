//! 登录保护的持久化：只有校验值和开关，没有明文口令。

use crate::errors::KeelError;
use sqlx::SqlitePool;

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct SecurityRow {
    pub password_hash: Option<String>,
    pub login_required: bool,
    pub updated_at: i64,
}

pub async fn load(pool: &SqlitePool) -> Result<Option<SecurityRow>, KeelError> {
    let row = sqlx::query_as::<_, SecurityRow>(
        "SELECT password_hash, login_required, updated_at FROM app_security WHERE id = 1",
    )
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

/// 单行 upsert；密码校验值为 None 表示尚未设置。
pub async fn save(
    pool: &SqlitePool,
    password_hash: Option<&str>,
    login_required: bool,
    at: i64,
) -> Result<(), KeelError> {
    sqlx::query(
        "INSERT INTO app_security (id, password_hash, login_required, updated_at) \
         VALUES (1, ?1, ?2, ?3) \
         ON CONFLICT(id) DO UPDATE SET password_hash = excluded.password_hash, \
         login_required = excluded.login_required, updated_at = excluded.updated_at",
    )
    .bind(password_hash)
    .bind(login_required)
    .bind(at)
    .execute(pool)
    .await?;
    Ok(())
}
