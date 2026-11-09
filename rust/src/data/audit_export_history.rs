//! Durable metadata queries; never resolves result names into filesystem paths.
use crate::errors::KeelError;
use sqlx::{SqliteConnection, SqlitePool};

#[cfg(test)]
mod tests {
    use super::*;

    fn completed(task: &str) -> HistoryRow {
        HistoryRow {
            task_id: task.into(),
            created_at_ms: 0,
            finished_at_ms: None,
            phase: "completed".into(),
            completed_rows: 2,
            total_rows: 2,
            result_name: Some(format!("audit-{task}.csv")),
            error_code: None,
        }
    }

    #[tokio::test]
    async fn terminal_replay_preserves_time_and_rejects_conflicts_and_ignored_writes() {
        let directory = std::env::temp_dir().join(format!(
            "keel-history-replay-{}",
            crate::diagnostics::correlation::new_correlation_id(),
        ));
        std::fs::create_dir(&directory).unwrap();
        let pool = crate::data::open(&directory.join("main.db")).await.unwrap();
        let owner = sqlx::query(
            "INSERT INTO app_user(name, role, created_at) VALUES ('history-test', 'admin', 0)",
        )
        .execute(&pool)
        .await
        .unwrap()
        .last_insert_rowid();
        register(&pool, "done", owner, 1, 0).await.unwrap();
        finish(&pool, completed("done"), 10, 0).await.unwrap();
        finish(&pool, completed("done"), 20, 0).await.unwrap();
        let timestamp: i64 = sqlx::query_scalar(
            "SELECT finished_at_ms FROM audit_export_history WHERE task_id = 'done'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(timestamp, 10);
        let mut conflict = completed("done");
        conflict.completed_rows = 1;
        assert!(finish(&pool, conflict, 30, 0).await.is_err());

        register(&pool, "interrupted", owner, 1, 0).await.unwrap();
        recover(&pool, 40, 0).await.unwrap();
        assert!(finish(&pool, completed("interrupted"), 50, 0)
            .await
            .is_err());
        register(&pool, "ignored", owner, 1, 0).await.unwrap();
        sqlx::query(
            "CREATE TRIGGER ignore_finish BEFORE UPDATE ON audit_export_history \
             BEGIN SELECT RAISE(IGNORE); END",
        )
        .execute(&pool)
        .await
        .unwrap();
        assert!(finish(&pool, completed("ignored"), 60, 0).await.is_err());
        let phase: String =
            sqlx::query_scalar("SELECT phase FROM audit_export_history WHERE task_id = 'ignored'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(phase, "running");
        pool.close().await;
        // Windows 关闭池后文件句柄可能延迟释放，重试清理避免误报。
        for _ in 0..40 {
            match std::fs::remove_dir_all(&directory) {
                Ok(()) => break,
                Err(error)
                    if error.raw_os_error() == Some(32)
                        || error.kind() == std::io::ErrorKind::PermissionDenied =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(error) => panic!("remove test dir failed: {error}"),
            }
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
pub(crate) struct HistoryRow {
    pub task_id: String,
    pub created_at_ms: i64,
    pub finished_at_ms: Option<i64>,
    pub phase: String,
    pub completed_rows: i64,
    pub total_rows: i64,
    pub result_name: Option<String>,
    pub error_code: Option<String>,
}

async fn prune(connection: &mut SqliteConnection, cutoff: i64) -> Result<(), KeelError> {
    sqlx::query(
        "DELETE FROM audit_export_history WHERE phase <> 'running' AND finished_at_ms < ?1",
    )
    .bind(cutoff)
    .execute(&mut *connection)
    .await?;
    sqlx::query(
        "DELETE FROM audit_export_history WHERE task_id IN \
         (SELECT task_id FROM audit_export_history WHERE phase <> 'running' \
          ORDER BY finished_at_ms DESC, task_id DESC LIMIT -1 OFFSET 1000)",
    )
    .execute(connection)
    .await?;
    Ok(())
}

pub(crate) async fn register(
    pool: &SqlitePool,
    task_id: &str,
    owner: i64,
    at: i64,
    cutoff: i64,
) -> Result<(), KeelError> {
    let mut transaction = pool.begin().await?;
    let result = async {
        let result = sqlx::query(
            "INSERT INTO audit_export_history(task_id, owner_id, created_at_ms, phase) \
             VALUES (?1, ?2, ?3, 'running')",
        )
        .bind(task_id)
        .bind(owner)
        .bind(at)
        .execute(transaction.as_mut())
        .await?;
        if result.rows_affected() != 1 {
            return Err(KeelError::internal(
                "export history registration was not stored",
            ));
        }
        prune(transaction.as_mut(), cutoff).await?;
        Ok(())
    }
    .await;
    match result {
        Ok(()) => transaction.commit().await?,
        // 显式回滚：丢弃事务的后台回滚可能与连接复用竞态，留下旧快照连接。
        Err(error) => {
            let _ = transaction.rollback().await;
            return Err(error);
        }
    }
    Ok(())
}

pub(crate) async fn finish(
    pool: &SqlitePool,
    row: HistoryRow,
    at: i64,
    cutoff: i64,
) -> Result<(), KeelError> {
    if !matches!(row.phase.as_str(), "completed" | "cancelled" | "failed") {
        return Err(KeelError::internal("invalid export history terminal phase"));
    }
    let mut transaction = pool.begin().await?;
    let result = async {
        sqlx::query(
            "UPDATE audit_export_history SET phase = ?1, finished_at_ms = ?2, \
             completed_rows = ?3, total_rows = ?4, result_name = ?5, error_code = ?6 \
             WHERE task_id = ?7 AND phase = 'running'",
        )
        .bind(&row.phase)
        .bind(at)
        .bind(row.completed_rows)
        .bind(row.total_rows)
        .bind(&row.result_name)
        .bind(&row.error_code)
        .bind(&row.task_id)
        .execute(transaction.as_mut())
        .await?;
        // Repeated identical completion preserves the first finish time. A conflicting
        // or interrupted result, and a trigger silently ignoring UPDATE, must fail.
        let matches: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_export_history \
             WHERE task_id = ?1 AND phase = ?2 AND finished_at_ms IS NOT NULL \
             AND completed_rows = ?3 AND total_rows = ?4 \
             AND result_name IS ?5 AND error_code IS ?6",
        )
        .bind(&row.task_id)
        .bind(&row.phase)
        .bind(row.completed_rows)
        .bind(row.total_rows)
        .bind(&row.result_name)
        .bind(&row.error_code)
        .fetch_one(transaction.as_mut())
        .await?;
        if matches != 1 {
            return Err(KeelError::internal(
                "export history terminal status was not stored or conflicts",
            ));
        }
        prune(transaction.as_mut(), cutoff).await?;
        Ok(())
    }
    .await;
    match result {
        Ok(()) => transaction.commit().await?,
        Err(error) => {
            let _ = transaction.rollback().await;
            return Err(error);
        }
    }
    Ok(())
}

pub(crate) async fn recover(pool: &SqlitePool, at: i64, cutoff: i64) -> Result<(), KeelError> {
    let mut transaction = pool.begin().await?;
    let result = async {
        sqlx::query(
            "UPDATE audit_export_history SET phase = 'interrupted', finished_at_ms = ?1, \
             result_name = NULL, error_code = 'KEEL-INTERNAL' WHERE phase = 'running'",
        )
        .bind(at)
        .execute(transaction.as_mut())
        .await?;
        let remaining: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM audit_export_history WHERE phase = 'running'")
                .fetch_one(transaction.as_mut())
                .await?;
        if remaining != 0 {
            return Err(KeelError::internal(
                "export history recovery was not stored",
            ));
        }
        prune(transaction.as_mut(), cutoff).await?;
        Ok(())
    }
    .await;
    match result {
        Ok(()) => transaction.commit().await?,
        Err(error) => {
            let _ = transaction.rollback().await;
            return Err(error);
        }
    }
    Ok(())
}

pub(crate) async fn list(
    pool: &SqlitePool,
    owner: i64,
    limit: i64,
    offset: i64,
    cutoff: i64,
) -> Result<(Vec<HistoryRow>, i64), KeelError> {
    let mut transaction = pool.begin().await?;
    let result = async {
        let total: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_export_history \
             WHERE owner_id = ?1 AND (phase = 'running' OR finished_at_ms >= ?2)",
        )
        .bind(owner)
        .bind(cutoff)
        .fetch_one(transaction.as_mut())
        .await?;
        let rows = sqlx::query_as::<_, HistoryRow>(
            "SELECT task_id, created_at_ms, finished_at_ms, phase, completed_rows, \
             total_rows, result_name, error_code FROM audit_export_history \
             WHERE owner_id = ?1 AND (phase = 'running' OR finished_at_ms >= ?2) \
             ORDER BY created_at_ms DESC, task_id DESC LIMIT ?3 OFFSET ?4",
        )
        .bind(owner)
        .bind(cutoff)
        .bind(limit)
        .bind(offset)
        .fetch_all(transaction.as_mut())
        .await?;
        Ok((rows, total))
    }
    .await;
    match result {
        Ok(value) => {
            transaction.commit().await?;
            Ok(value)
        }
        Err(error) => {
            let _ = transaction.rollback().await;
            Err(error)
        }
    }
}
