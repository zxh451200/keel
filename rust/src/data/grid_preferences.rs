//! Parameterized storage only; layout and ownership rules live in services.
use crate::errors::KeelError;
use sqlx::SqliteConnection;

#[derive(sqlx::FromRow)]
pub(crate) struct StoredLayout {
    pub revision: i64,
    pub layout_json: String,
}

pub(crate) async fn load(
    connection: &mut SqliteConnection,
    owner: i64,
    list_id: &str,
) -> Result<Option<StoredLayout>, KeelError> {
    Ok(sqlx::query_as::<_, StoredLayout>(
        "SELECT revision, layout_json FROM grid_preferences WHERE owner_id = ?1 AND list_id = ?2",
    )
    .bind(owner)
    .bind(list_id)
    .fetch_optional(connection)
    .await?)
}

/// Compare-and-swap; zero affected rows is a stale revision, never success.
pub(crate) async fn save(
    connection: &mut SqliteConnection,
    owner: i64,
    list_id: &str,
    expected: i64,
    json: &str,
) -> Result<bool, KeelError> {
    let result = if expected == 0 {
        sqlx::query(
            "INSERT INTO grid_preferences(owner_id, list_id, revision, layout_json) \
             VALUES (?1, ?2, 1, ?3) ON CONFLICT(owner_id, list_id) DO NOTHING",
        )
        .bind(owner)
        .bind(list_id)
        .bind(json)
        .execute(connection)
        .await?
    } else {
        sqlx::query(
            "UPDATE grid_preferences SET revision = revision + 1, layout_json = ?1 \
             WHERE owner_id = ?2 AND list_id = ?3 AND revision = ?4",
        )
        .bind(json)
        .bind(owner)
        .bind(list_id)
        .bind(expected)
        .execute(connection)
        .await?
    };
    Ok(result.rows_affected() == 1)
}
