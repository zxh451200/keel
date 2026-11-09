//! Separate from the six transient action handles. No automatic replay.
use crate::api::audit::AuditExportStatus;
use crate::api::audit_export_history::{AuditExportHistoryEntry, AuditExportHistoryPage};
use crate::data::{audit_export_history as storage, user};
use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::{access, audit};
use sqlx::SqlitePool;

const RETENTION_MS: i64 = 30 * 24 * 60 * 60 * 1000;

fn is_sqlite_contention(error: &KeelError) -> bool {
    let KeelError::Db(sqlx::Error::Database(db)) = error else {
        return false;
    };
    db.code()
        .and_then(|code| code.parse::<i32>().ok())
        .is_some_and(|code| matches!(code & 0xff, 5 | 6))
}

/// Retry only transient SQLite BUSY/LOCKED errors, at most three attempts.
pub(crate) async fn finish_with_retry(
    pool: &SqlitePool,
    status: &AuditExportStatus,
) -> Result<(), KeelError> {
    let delays = [50_u64, 150];
    for attempt in 0..=delays.len() {
        match finish(pool, status).await {
            Ok(()) => return Ok(()),
            Err(error) if attempt < delays.len() && is_sqlite_contention(&error) => {
                tokio::time::sleep(std::time::Duration::from_millis(delays[attempt])).await;
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("bounded retry loop always returns")
}

pub(crate) async fn register(
    pool: &SqlitePool,
    owner: &access::CurrentUser,
    task_id: &str,
) -> Result<(), KeelError> {
    let row = user::find_by_name(pool, &owner.name)
        .await?
        .ok_or(KeelError::NotFound)?;
    if row.role != owner.role.as_str() || access::current()? != *owner {
        return Err(KeelError::PermissionDenied("audit.export.owner".into()));
    }
    let now = audit::now_ms();
    storage::register(pool, task_id, row.id, now, now.saturating_sub(RETENTION_MS)).await
}

pub(crate) async fn finish(pool: &SqlitePool, status: &AuditExportStatus) -> Result<(), KeelError> {
    if !matches!(status.phase.as_str(), "completed" | "cancelled" | "failed") {
        return Err(KeelError::internal(
            "export history received a non-terminal status",
        ));
    }
    let result_name = if status.phase == "completed" {
        Some(format!("audit-{}.csv", status.task_id))
    } else {
        None
    };
    let now = audit::now_ms();
    storage::finish(
        pool,
        storage::HistoryRow {
            task_id: status.task_id.clone(),
            created_at_ms: 0,
            finished_at_ms: Some(now),
            phase: status.phase.clone(),
            completed_rows: i64::from(status.completed_rows),
            total_rows: i64::from(status.total_rows),
            result_name,
            error_code: status.error_code.clone(),
        },
        now,
        now.saturating_sub(RETENTION_MS),
    )
    .await
}

/// Called before publishing the pool or current user. Never infer completion from a CSV.
pub async fn recover_on_startup(pool: &SqlitePool) -> Result<(), KeelError> {
    let now = audit::now_ms();
    storage::recover(pool, now, now.saturating_sub(RETENTION_MS)).await
}

pub async fn list(
    pool: &SqlitePool,
    page: u32,
    page_size: u32,
) -> Result<AuditExportHistoryPage, KeelError> {
    if !(1..=1000).contains(&page) || !(1..=100).contains(&page_size) {
        return Err(KeelError::Validation("历史分页超出范围".into()));
    }
    let _guard = access::lock_identity().await;
    let owner = access::require(pool, Permission::AuditExport).await?;
    let (_, epoch) = access::identity_snapshot()?;
    let row = user::find_by_name(pool, &owner.name)
        .await?
        .ok_or(KeelError::NotFound)?;
    if row.role != owner.role.as_str() {
        return Err(KeelError::PermissionDenied("audit.export.owner".into()));
    }
    let (rows, total) = storage::list(
        pool,
        row.id,
        i64::from(page_size),
        i64::from(page - 1) * i64::from(page_size),
        audit::now_ms().saturating_sub(RETENTION_MS),
    )
    .await?;
    let (current, current_epoch) = access::identity_snapshot()?;
    if current != owner || current_epoch != epoch {
        return Err(KeelError::PermissionDenied("audit.export.owner".into()));
    }
    let entries = rows
        .into_iter()
        .map(|row| {
            let completed_rows = u32::try_from(row.completed_rows).map_err(KeelError::internal)?;
            let total_rows = u32::try_from(row.total_rows).map_err(KeelError::internal)?;
            Ok(AuditExportHistoryEntry {
                task_id: row.task_id,
                created_at_ms: row.created_at_ms,
                finished_at_ms: row.finished_at_ms,
                phase: row.phase,
                completed_rows,
                total_rows,
                result_name: row.result_name,
                error_code: row.error_code,
            })
        })
        .collect::<Result<Vec<_>, KeelError>>()?;
    Ok(AuditExportHistoryPage {
        entries,
        total,
        page,
        page_size,
    })
}
