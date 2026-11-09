//! 本地用户表的读写。

use crate::errors::KeelError;
use sqlx::{SqliteConnection, SqlitePool};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct UserRow {
    pub id: i64,
    pub name: String,
    pub role: String,
    pub created_at: i64,
}

pub async fn find_by_name(pool: &SqlitePool, name: &str) -> Result<Option<UserRow>, KeelError> {
    let row = sqlx::query_as::<_, UserRow>(
        "SELECT id, name, role, created_at FROM app_user WHERE name = ?1",
    )
    .bind(name)
    .fetch_optional(pool)
    .await?;
    Ok(row)
}

pub async fn list(pool: &SqlitePool) -> Result<Vec<UserRow>, KeelError> {
    let rows = sqlx::query_as::<_, UserRow>(
        "SELECT id, name, role, created_at FROM app_user ORDER BY name",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows)
}

/// 名字重复会返回 `KEEL-DUPLICATE`（唯一约束）。
pub async fn insert(pool: &SqlitePool, name: &str, role: &str, at: i64) -> Result<(), KeelError> {
    let mut connection = pool.acquire().await?;
    insert_conn(&mut connection, name, role, at).await
}

/// 在已有连接上插入用户，供事务和连接池包装复用。
pub async fn insert_conn(
    connection: &mut SqliteConnection,
    name: &str,
    role: &str,
    at: i64,
) -> Result<(), KeelError> {
    sqlx::query("INSERT INTO app_user (name, role, created_at) VALUES (?1, ?2, ?3)")
        .bind(name)
        .bind(role)
        .bind(at)
        .execute(&mut *connection)
        .await?;
    Ok(())
}
