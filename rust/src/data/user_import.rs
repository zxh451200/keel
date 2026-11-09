//! Insert-only batch import SQL; caller owns the transaction.
use crate::errors::KeelError;
use sqlx::SqliteConnection;

fn written(affected: u64) -> Result<(), KeelError> {
    if affected == 1 {
        Ok(())
    } else {
        Err(KeelError::internal("user import write was ignored"))
    }
}

pub(crate) async fn insert_user(
    connection: &mut SqliteConnection,
    name: &str,
    role: &str,
    at: i64,
) -> Result<(), KeelError> {
    let result = sqlx::query("INSERT INTO app_user(name, role, created_at) VALUES (?1, ?2, ?3)")
        .bind(name)
        .bind(role)
        .bind(at)
        .execute(connection)
        .await?;
    written(result.rows_affected())
}

pub(crate) async fn insert_audit(
    connection: &mut SqliteConnection,
    at: i64,
    actor: &str,
    action: &str,
    target: &str,
    result: &str,
    correlation_id: &str,
) -> Result<(), KeelError> {
    let row = sqlx::query(
        "INSERT INTO audit_log(at, actor, action, target, result, correlation_id) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .bind(at)
    .bind(actor)
    .bind(action)
    .bind(target)
    .bind(result)
    .bind(correlation_id)
    .execute(connection)
    .await?;
    written(row.rows_affected())
}
