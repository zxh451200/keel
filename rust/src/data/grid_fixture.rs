//! Explicitly initialized synthetic POC storage. Never called by product startup.
use sqlx::{Sqlite, SqlitePool, Transaction};

pub(crate) async fn initialize(pool: &SqlitePool) -> Result<(), sqlx::Error> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS grid_poc_fixture (\
         id TEXT PRIMARY KEY NOT NULL, text TEXT NOT NULL, quantity INTEGER NOT NULL, \
         date TEXT NOT NULL, kind TEXT NOT NULL)",
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub(crate) async fn insert(
    tx: &mut Transaction<'_, Sqlite>,
    id: &str,
    text: &str,
    quantity: i32,
    date: &str,
    kind: &str,
) -> Result<u64, sqlx::Error> {
    let result =
        sqlx::query("INSERT INTO grid_poc_fixture (text,quantity,date,kind,id) VALUES (?,?,?,?,?)")
            .bind(text)
            .bind(quantity)
            .bind(date)
            .bind(kind)
            .bind(id)
            .execute(&mut **tx)
            .await?;
    Ok(result.rows_affected())
}

pub(crate) async fn update(
    tx: &mut Transaction<'_, Sqlite>,
    id: &str,
    text: &str,
    quantity: i32,
    date: &str,
    kind: &str,
) -> Result<u64, sqlx::Error> {
    let result =
        sqlx::query("UPDATE grid_poc_fixture SET text=?,quantity=?,date=?,kind=? WHERE id=?")
            .bind(text)
            .bind(quantity)
            .bind(date)
            .bind(kind)
            .bind(id)
            .execute(&mut **tx)
            .await?;
    Ok(result.rows_affected())
}
