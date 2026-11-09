//! Synthetic POC only. The caller must supply an isolated SQLite pool and invoke
//! initialize explicitly. No startup, product database, audit, or FRB wiring.
use crate::data::grid_fixture as storage;
use serde::Deserialize;
use sqlx::{Sqlite, SqlitePool, Transaction};
use std::collections::HashSet;
use std::io::BufRead;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

pub(crate) const MAX_BYTES: usize = 1024 * 1024;
pub(crate) const MAX_ROWS: usize = 10_000;
pub(crate) const MAX_LINE: usize = 4096;
const PROGRESS_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct FixtureRow {
    pub(crate) id: String,
    pub(crate) text: String,
    pub(crate) quantity: i32,
    pub(crate) date: String,
    pub(crate) kind: String,
}

// These variants deliberately never retain input, IO errors, or SQL errors.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FixtureError {
    Cancelled,
    InputLimit,
    RowLimit,
    LineLimit,
    Encoding,
    EmptyLine,
    InvalidJson,
    InvalidId,
    InvalidText,
    InvalidDate,
    InvalidKind,
    DuplicateId,
    MissingId,
    Read,
    Storage,
}

#[derive(Default)]
pub(crate) struct Cancellation(AtomicBool);

impl Cancellation {
    pub(crate) fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    fn check(&self) -> Result<(), FixtureError> {
        if self.0.load(Ordering::Acquire) {
            Err(FixtureError::Cancelled)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Progress {
    pub(crate) bytes_read: usize,
    pub(crate) rows_processed: usize,
    // Only emitted after successful commit; processing progress is provisional.
    pub(crate) committed: bool,
}

#[derive(Clone, Copy)]
pub(crate) enum SaveMode {
    Create,
    Update,
}

pub(crate) fn validate(row: &FixtureRow) -> Result<(), FixtureError> {
    if row.id.is_empty()
        || row.id.len() > 64
        || !row
            .id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err(FixtureError::InvalidId);
    }
    if row.text.chars().count() > 80
        || row.text.trim().is_empty()
        || row.text.chars().any(char::is_control)
    {
        return Err(FixtureError::InvalidText);
    }
    if !valid_date(&row.date) {
        return Err(FixtureError::InvalidDate);
    }
    if !matches!(row.kind.as_str(), "standard" | "priority") {
        return Err(FixtureError::InvalidKind);
    }
    Ok(())
}

fn valid_date(value: &str) -> bool {
    let b = value.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return false;
    }
    if !b
        .iter()
        .enumerate()
        .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
    {
        return false;
    }
    let number = |s: &[u8]| s.iter().fold(0_u32, |n, c| n * 10 + u32::from(c - b'0'));
    let year = number(&b[..4]);
    let month = number(&b[5..7]);
    let day = number(&b[8..]);
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => return false,
    };
    (1900..=2100).contains(&year) && (1..=days).contains(&day)
}

pub(crate) async fn initialize(pool: &SqlitePool) -> Result<(), FixtureError> {
    storage::initialize(pool)
        .await
        .map_err(|_| FixtureError::Storage)
}

fn storage_error(error: sqlx::Error) -> FixtureError {
    if matches!(&error, sqlx::Error::Database(e) if e.is_unique_violation()) {
        FixtureError::DuplicateId
    } else {
        FixtureError::Storage
    }
}

async fn write_row(
    tx: &mut Transaction<'_, Sqlite>,
    row: &FixtureRow,
    mode: SaveMode,
) -> Result<(), FixtureError> {
    let rows_affected = match mode {
        SaveMode::Create => {
            storage::insert(tx, &row.id, &row.text, row.quantity, &row.date, &row.kind).await
        }
        SaveMode::Update => {
            storage::update(tx, &row.id, &row.text, row.quantity, &row.date, &row.kind).await
        }
    }
    .map_err(storage_error)?;
    if rows_affected != 1 {
        return Err(match mode {
            SaveMode::Update => FixtureError::MissingId,
            SaveMode::Create => FixtureError::Storage,
        });
    }
    Ok(())
}

async fn finish<T>(
    tx: Transaction<'_, Sqlite>,
    outcome: Result<T, FixtureError>,
    cancel: &Cancellation,
) -> Result<T, FixtureError> {
    let outcome = outcome.and_then(|value| cancel.check().map(|()| value));
    match outcome {
        Ok(value) => {
            // Last cooperative cancellation point is immediately before COMMIT.
            // A request racing the commit is best effort; never undo success.
            tx.commit().await.map_err(|_| FixtureError::Storage)?;
            Ok(value)
        }
        Err(error) => {
            tx.rollback().await.map_err(|_| FixtureError::Storage)?;
            Err(error)
        }
    }
}

pub(crate) async fn save_row(
    pool: &SqlitePool,
    row: &FixtureRow,
    mode: SaveMode,
    cancel: &Cancellation,
) -> Result<(), FixtureError> {
    cancel.check()?;
    let mut tx = pool.begin().await.map_err(|_| FixtureError::Storage)?;
    let outcome = async {
        cancel.check()?;
        validate(row)?;
        write_row(&mut tx, row, mode).await
    }
    .await;
    finish(tx, outcome, cancel).await
}

// Reads at most 512 bytes between cancellation checks, without an unbounded
// read_until allocation. Limits exclude LF (and CR in CRLF) from line length;
// total input bytes include all delimiters. A bare CR is JSON whitespace only.
fn read_line<R: BufRead>(
    reader: &mut R,
    line: &mut Vec<u8>,
    bytes: &mut usize,
    cancel: &Cancellation,
) -> Result<bool, FixtureError> {
    line.clear();
    loop {
        cancel.check()?;
        let available = reader.fill_buf().map_err(|_| FixtureError::Read)?;
        if available.is_empty() {
            cancel.check()?;
            return Ok(!line.is_empty());
        }
        let chunk = &available[..available.len().min(512)];
        let newline = chunk.iter().position(|b| *b == b'\n');
        let count = newline.map_or(chunk.len(), |i| i + 1);
        *bytes += count;
        if *bytes > MAX_BYTES {
            return Err(FixtureError::InputLimit);
        }
        line.extend_from_slice(&chunk[..count]);
        reader.consume(count);
        cancel.check()?;
        if newline.is_some() {
            line.pop();
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            if line.len() > MAX_LINE {
                return Err(FixtureError::LineLimit);
            }
            return Ok(true);
        }
        // One extra CR may be followed by LF in the next buffer.
        if line.len() > MAX_LINE && !(line.len() == MAX_LINE + 1 && line.last() == Some(&b'\r')) {
            return Err(FixtureError::LineLimit);
        }
    }
}

/// Caller owns the isolated pool and reader. Use a worker runtime for blocking
/// readers; this core opens no paths and holds only one bounded line plus IDs.
/// Progress callbacks must be short and non-panicking. Success is the returned
/// count / committed event, never a provisional row count. Empty input is a no-op.
pub(crate) async fn import_jsonl<R: BufRead, F: FnMut(Progress)>(
    pool: &SqlitePool,
    reader: &mut R,
    cancel: &Cancellation,
    mut progress: F,
) -> Result<usize, FixtureError> {
    cancel.check()?;
    let mut tx = pool.begin().await.map_err(|_| FixtureError::Storage)?;
    let mut bytes_read = 0;
    let mut rows_processed = 0;
    let outcome = async {
        cancel.check()?;
        progress(Progress {
            bytes_read: 0,
            rows_processed: 0,
            committed: false,
        });
        let mut last_progress = Instant::now();
        let mut line = Vec::with_capacity(MAX_LINE + 2);
        let mut ids = HashSet::new();
        while read_line(reader, &mut line, &mut bytes_read, cancel)? {
            cancel.check()?;
            if line.len() > MAX_LINE {
                return Err(FixtureError::LineLimit);
            }
            if rows_processed == MAX_ROWS {
                return Err(FixtureError::RowLimit);
            }
            let text = std::str::from_utf8(&line).map_err(|_| FixtureError::Encoding)?;
            if text.trim().is_empty() {
                return Err(FixtureError::EmptyLine);
            }
            // Serde structs can deserialize positional arrays; JSONL requires objects.
            if !text.trim_start().starts_with('{') {
                return Err(FixtureError::InvalidJson);
            }
            let row: FixtureRow =
                serde_json::from_str(text).map_err(|_| FixtureError::InvalidJson)?;
            validate(&row)?;
            if !ids.insert(row.id.clone()) {
                return Err(FixtureError::DuplicateId);
            }
            write_row(&mut tx, &row, SaveMode::Create).await?;
            rows_processed += 1;
            if last_progress.elapsed() >= PROGRESS_INTERVAL {
                progress(Progress {
                    bytes_read,
                    rows_processed,
                    committed: false,
                });
                last_progress = Instant::now();
            }
            // Ensure cancellation can run even for memory readers / ready SQL.
            tokio::task::yield_now().await;
        }
        Ok(rows_processed)
    }
    .await;
    let count = finish(tx, outcome, cancel).await?;
    // Terminal notification is exempt from the processing update interval.
    progress(Progress {
        bytes_read,
        rows_processed: count,
        committed: true,
    });
    Ok(count)
}
