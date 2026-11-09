//! Bounded JSONL import into real users. No config or fixture writes.
use crate::data::user_import as storage;
use crate::diagnostics::correlation::new_correlation_id;
use crate::domain::permissions::{Permission, Role};
use crate::errors::KeelError;
use crate::services::{access, audit};
use serde::Deserialize;
use sqlx::SqlitePool;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

type Identity = (access::CurrentUser, String);

struct Ticket {
    owner: Identity,
    created: Instant,
    running: bool,
    cancelled: Arc<AtomicBool>,
    progress: Arc<ImportProgress>,
}

#[derive(Default)]
struct ImportProgress {
    processed: AtomicU32,
    total: AtomicU32,
}

/// Counts are provisional until run_prepared returns success.
pub fn progress(id: &str) -> Result<Option<(u32, u32)>, KeelError> {
    let owner = access::identity_snapshot()?;
    let registry = ticket_lock();
    let Some(ticket) = registry.get(id) else {
        return Ok(None);
    };
    if ticket.owner != owner {
        return Err(KeelError::PermissionDenied("users.manage".into()));
    }
    if !ticket.running && ticket.created.elapsed() >= Duration::from_secs(300) {
        return Ok(None);
    }
    // Read processed first: total is published before any row is processed.
    let processed = ticket.progress.processed.load(Ordering::Acquire);
    let total = ticket.progress.total.load(Ordering::Acquire);
    Ok(Some((processed, total)))
}

fn tickets() -> &'static Mutex<std::collections::HashMap<String, Ticket>> {
    static TICKETS: OnceLock<Mutex<std::collections::HashMap<String, Ticket>>> = OnceLock::new();
    TICKETS.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

fn ticket_lock() -> std::sync::MutexGuard<'static, std::collections::HashMap<String, Ticket>> {
    tickets().lock().unwrap_or_else(|error| error.into_inner())
}

/// Reserve before submitting so a cancel request cannot race registration.
/// Unused tickets expire after five minutes; at most six tickets exist.
pub async fn prepare(pool: &SqlitePool) -> Result<String, KeelError> {
    let _guard = access::lock_identity().await;
    access::require(pool, Permission::UserManage).await?;
    let owner = access::identity_snapshot()?;
    let mut registry = ticket_lock();
    registry
        .retain(|_, ticket| ticket.running || ticket.created.elapsed() < Duration::from_secs(300));
    if registry.len() >= 6 {
        return Err(KeelError::Validation("用户导入任务已达上限".into()));
    }
    let id = new_correlation_id();
    registry.insert(
        id.clone(),
        Ticket {
            owner,
            created: Instant::now(),
            running: false,
            cancelled: Arc::new(AtomicBool::new(false)),
            progress: Arc::new(ImportProgress::default()),
        },
    );
    Ok(id)
}

/// A cancellation request is acknowledged; the import result determines whether
/// it beat COMMIT. Never describe this acknowledgement as a rollback result.
pub fn cancel(id: &str) -> Result<(), KeelError> {
    let owner = access::identity_snapshot()?;
    let mut registry = ticket_lock();
    let ticket = registry.get(id).ok_or(KeelError::NotFound)?;
    if ticket.owner != owner {
        return Err(KeelError::PermissionDenied("users.manage".into()));
    }
    ticket.cancelled.store(true, Ordering::Release);
    if !ticket.running {
        registry.remove(id);
    }
    Ok(())
}

struct ReleaseTicket(String);

impl Drop for ReleaseTicket {
    fn drop(&mut self) {
        ticket_lock().remove(&self.0);
    }
}

/// Single-use operation bound to the identity generation that reserved it.
pub async fn run_prepared(pool: &SqlitePool, id: &str, input: &[u8]) -> Result<u32, KeelError> {
    let owner = access::identity_snapshot()?;
    let (cancelled, progress) = {
        let mut registry = ticket_lock();
        let ticket = registry.get_mut(id).ok_or(KeelError::NotFound)?;
        if ticket.owner != owner {
            return Err(KeelError::PermissionDenied("users.manage".into()));
        }
        if ticket.running || ticket.created.elapsed() >= Duration::from_secs(300) {
            return Err(KeelError::Validation("用户导入任务无效或已过期".into()));
        }
        ticket.running = true;
        (Arc::clone(&ticket.cancelled), Arc::clone(&ticket.progress))
    };
    let _release = ReleaseTicket(id.to_owned());
    import_owned(pool, input, &cancelled, owner, &progress).await
}

pub const MAX_BYTES: usize = 1024 * 1024;
pub const MAX_ROWS: u32 = 1000;
const MAX_LINE_BYTES: usize = 4096;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InputRow {
    name: String,
    role: String,
}

fn invalid() -> KeelError {
    KeelError::Validation("用户导入格式或上限无效".into())
}

fn parse(line: &str) -> Result<(String, Role), KeelError> {
    if line.len() > MAX_LINE_BYTES || !line.trim_start().starts_with('{') {
        return Err(invalid());
    }
    let row: InputRow = serde_json::from_str(line).map_err(|_| invalid())?;
    let name = access::validate_name(&row.name)?;
    let role = match Role::parse(&row.role) {
        Some(role @ (Role::Viewer | Role::Operator)) => role,
        _ => return Err(invalid()),
    };
    Ok((name, role))
}

/// Only explicit viewer/operator creation; no defaults, updates, skips or admin imports.
/// Cancellation is cooperative until the final check preceding COMMIT.
/// Permission denial keeps the existing permission.denied audit policy.
pub async fn import_jsonl(
    pool: &SqlitePool,
    input: &[u8],
    cancelled: &AtomicBool,
) -> Result<u32, KeelError> {
    let expected = access::identity_snapshot()?;
    import_owned(pool, input, cancelled, expected, &ImportProgress::default()).await
}

async fn import_owned(
    pool: &SqlitePool,
    input: &[u8],
    cancelled: &AtomicBool,
    expected: Identity,
    progress: &ImportProgress,
) -> Result<u32, KeelError> {
    let _guard = access::lock_identity().await;
    let owner = access::require(pool, Permission::UserManage).await?;
    let check = || -> Result<(), KeelError> {
        if access::identity_snapshot()? != expected {
            return Err(KeelError::PermissionDenied("users.manage".into()));
        }
        if cancelled.load(Ordering::Acquire) {
            return Err(KeelError::Cancelled);
        }
        Ok(())
    };
    check()?;
    if input.is_empty() || input.len() > MAX_BYTES {
        return Err(invalid());
    }
    let text = std::str::from_utf8(input).map_err(|_| invalid())?;
    let total = text.split_inclusive('\n').count();
    if total == 0 || total > MAX_ROWS as usize {
        return Err(invalid());
    }
    progress.total.store(total as u32, Ordering::Release);
    let mut tx = pool.begin().await?;
    let mut created = 0_u32;
    let correlation = new_correlation_id();
    let outcome: Result<(), KeelError> = async {
        let mut names = HashSet::new();
        for raw in text.split_inclusive('\n') {
            check()?;
            if created == MAX_ROWS {
                return Err(invalid());
            }
            let line = match raw.strip_suffix('\n') {
                Some(line) => line.strip_suffix('\r').unwrap_or(line),
                None => raw,
            };
            let (name, role) = parse(line)?;
            if !names.insert(name.clone()) {
                return Err(KeelError::Duplicate);
            }
            let at = audit::now_ms();
            storage::insert_user(tx.as_mut(), &name, role.as_str(), at).await?;
            storage::insert_audit(
                tx.as_mut(),
                at,
                &owner.name,
                "user.create",
                &name,
                "ok",
                &correlation,
            )
            .await?;
            created += 1;
            progress.processed.store(created, Ordering::Release);
            tokio::task::yield_now().await;
        }
        if created == 0 {
            return Err(invalid());
        }
        storage::insert_audit(
            tx.as_mut(),
            audit::now_ms(),
            &owner.name,
            "users.import",
            "app_user",
            &format!("created:{created}"),
            &correlation,
        )
        .await?;
        check()?;
        Ok(())
    }
    .await;
    if let Err(error) = outcome {
        tx.rollback().await?;
        return Err(error);
    }
    tx.commit().await?;
    Ok(created)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_ambiguous_or_privileged_rows() {
        for line in [
            "",
            "[]",
            r#"["a","viewer"]"#,
            r#"{"name":"a","role":"admin"}"#,
            r#"{"name":"a"}"#,
            r#"{"name":"a","role":"viewer","extra":1}"#,
            r#"{"name":"a","name":"b","role":"viewer"}"#,
            r#"{"name":"a\u0000b","role":"viewer"}"#,
        ] {
            assert!(parse(line).is_err(), "{line}");
        }
        let (name, role) = parse(r#"{"name":" 中文 ","role":"viewer"}"#).unwrap();
        assert_eq!(name, "中文");
        assert_eq!(role, Role::Viewer);
    }
}
