// Compile the same service and data implementation without exposing public APIs.
#[path = "../src/data/grid_fixture.rs"]
pub(crate) mod grid_fixture_data;

mod data {
    pub(crate) use crate::grid_fixture_data as grid_fixture;
}

#[path = "../src/services/grid_fixture.rs"]
mod grid_fixture;

use grid_fixture::*;
use sqlx::sqlite::SqlitePoolOptions;
use sqlx::SqlitePool;
use std::io::{self, BufRead, Cursor, Read};
use std::time::{Duration, Instant};

fn row(id: &str) -> FixtureRow {
    FixtureRow {
        id: id.into(),
        text: " 合成 fixture ".into(),
        quantity: i32::MIN,
        date: "2000-02-29".into(),
        kind: "standard".into(),
    }
}

fn json(id: &str) -> String {
    format!(
        r#"{{"id":"{id}","text":"fixture","quantity":0,"date":"2000-02-29","kind":"standard"}}"#
    )
}

async fn pool() -> SqlitePool {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    initialize(&pool).await.unwrap();
    pool
}

async fn count(pool: &SqlitePool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM grid_poc_fixture")
        .fetch_one(pool)
        .await
        .unwrap()
}

async fn import(pool: &SqlitePool, bytes: &[u8]) -> Result<usize, FixtureError> {
    import_jsonl(
        pool,
        &mut Cursor::new(bytes),
        &Cancellation::default(),
        |_| {},
    )
    .await
}

#[test]
fn validates_id_text_and_enum_boundaries() {
    let mut value = row("A_z-09");
    assert_eq!(validate(&value), Ok(()));
    value.id = "x".repeat(64);
    assert_eq!(validate(&value), Ok(()));
    for id in [
        "".to_string(),
        "x".repeat(65),
        "é".into(),
        "a b".into(),
        "a/b".into(),
    ] {
        value.id = id;
        assert_eq!(validate(&value), Err(FixtureError::InvalidId));
    }
    value.id = "valid".into();
    value.text = "🦀".repeat(80);
    assert_eq!(validate(&value), Ok(()));
    for text in [
        "🦀".repeat(81),
        format!(" {} ", "a".repeat(79)),
        " \u{2003} ".into(),
        "a\n".into(),
        "a\u{7f}".into(),
        "a\u{85}".into(),
    ] {
        value.text = text;
        assert_eq!(validate(&value), Err(FixtureError::InvalidText));
    }
    value.text = "safe".into();
    value.kind = "priority".into();
    assert_eq!(validate(&value), Ok(()));
    value.kind = "Priority".into();
    assert_eq!(validate(&value), Err(FixtureError::InvalidKind));
}

#[test]
fn validates_real_gregorian_dates_without_dependencies() {
    let mut value = row("date");
    for date in [
        "1900-01-01",
        "2100-12-31",
        "2000-02-29",
        "2024-02-29",
        "1900-02-28",
        "2100-02-28",
    ] {
        value.date = date.into();
        assert_eq!(validate(&value), Ok(()), "{date}");
    }
    for date in [
        "1899-12-31",
        "2101-01-01",
        "1900-02-29",
        "2100-02-29",
        "2023-02-29",
        "2000-04-31",
        "2000-00-01",
        "2000-13-01",
        "2000-01-00",
        "2000-1-01",
        "2000-01-01 ",
        "２０００-01-01",
    ] {
        value.date = date.into();
        assert_eq!(validate(&value), Err(FixtureError::InvalidDate), "{date}");
    }
}

#[tokio::test]
async fn explicit_initialization_and_single_row_transactions() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    let cancel = Cancellation::default();
    let mut value = row("edit");
    assert_eq!(
        save_row(&pool, &value, SaveMode::Create, &cancel).await,
        Err(FixtureError::Storage)
    );
    initialize(&pool).await.unwrap();
    initialize(&pool).await.unwrap();
    save_row(&pool, &value, SaveMode::Create, &cancel)
        .await
        .unwrap();
    assert_eq!(
        save_row(&pool, &value, SaveMode::Create, &cancel).await,
        Err(FixtureError::DuplicateId)
    );
    value.quantity = i32::MAX;
    value.kind = "priority".into();
    save_row(&pool, &value, SaveMode::Update, &cancel)
        .await
        .unwrap();
    let actual: (String, i32, String) =
        sqlx::query_as("SELECT text,quantity,kind FROM grid_poc_fixture WHERE id='edit'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(actual, (value.text.clone(), i32::MAX, "priority".into()));
    value.text = "bad\ntext".into();
    assert_eq!(
        save_row(&pool, &value, SaveMode::Update, &cancel).await,
        Err(FixtureError::InvalidText)
    );
    value = row("missing");
    assert_eq!(
        save_row(&pool, &value, SaveMode::Update, &cancel).await,
        Err(FixtureError::MissingId)
    );
    cancel.cancel();
    assert_eq!(
        save_row(&pool, &row("cancelled"), SaveMode::Create, &cancel).await,
        Err(FixtureError::Cancelled)
    );
    assert_eq!(count(&pool).await, 1);
    let tables: Vec<String> =
        sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type='table'")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(tables, vec!["grid_poc_fixture"]);
}

#[tokio::test]
async fn invalid_last_line_and_duplicate_ids_roll_back_the_entire_batch() {
    let pool = pool().await;
    for tail in [
        "{bad json".into(),
        json("first"),
        json("bad").replace("2000-02-29", "1900-02-29"),
    ] {
        let input = format!("{}\n{tail}", json("first"));
        assert!(import(&pool, input.as_bytes()).await.is_err());
        assert_eq!(count(&pool).await, 0);
    }
    save_row(
        &pool,
        &row("existing"),
        SaveMode::Create,
        &Cancellation::default(),
    )
    .await
    .unwrap();
    let input = format!("{}\n{}\n", json("new"), json("existing"));
    assert_eq!(
        import(&pool, input.as_bytes()).await,
        Err(FixtureError::DuplicateId)
    );
    assert_eq!(count(&pool).await, 1);
    let actual: String =
        sqlx::query_scalar("SELECT text FROM grid_poc_fixture WHERE id='existing'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(actual, row("existing").text);
}

#[tokio::test]
async fn rejects_unknown_duplicate_fields_invalid_encoding_and_integer_overflow() {
    let pool = pool().await;
    let good = json("first");
    for bad in [
        good.replacen('{', "{\"unknown\":true,", 1),
        good.replacen('{', "{\"id\":\"duplicate-field\",", 1),
        good.replace("\"quantity\":0", "\"quantity\":2147483648"),
        good.replace("\"quantity\":0", "\"quantity\":-2147483649"),
        good.replace("\"quantity\":0", "\"quantity\":1.0"),
        good.replace("\"quantity\":0", "\"quantity\":\"0\""),
        good.replace("\"text\":\"fixture\",", ""),
        r#"["first","fixture",0,"2000-02-29","standard"]"#.into(),
    ] {
        assert_eq!(
            import(&pool, bad.as_bytes()).await,
            Err(FixtureError::InvalidJson)
        );
    }
    let bytes = [good.as_bytes(), b"\n\xff"].concat();
    assert_eq!(import(&pool, &bytes).await, Err(FixtureError::Encoding));
    let bom = [b"\xef\xbb\xbf".as_slice(), good.as_bytes()].concat();
    assert_eq!(import(&pool, &bom).await, Err(FixtureError::InvalidJson));
    for bytes in [
        format!("{good}\n\n"),
        format!("{good}\n \t\n{}", json("second")),
        format!("\n{good}"),
    ] {
        assert_eq!(
            import(&pool, bytes.as_bytes()).await,
            Err(FixtureError::EmptyLine)
        );
    }
    assert_eq!(count(&pool).await, 0);
    assert_eq!(import(&pool, format!("{good}\r\n").as_bytes()).await, Ok(1));
    assert_eq!(import(&pool, b"").await, Ok(0));
}

#[tokio::test]
async fn line_limits_include_json_whitespace_but_exclude_newline() {
    let pool = pool().await;
    let good = json("line");
    let padded = format!("{good}{}", " ".repeat(MAX_LINE - good.len()));
    assert_eq!(
        import(&pool, format!("{padded}\r\n").as_bytes()).await,
        Ok(1)
    );
    for suffix in ["", "\n", "\r\n"] {
        let input = format!("{}\n{padded} {suffix}", json("rollback"));
        assert_eq!(
            import(&pool, input.as_bytes()).await,
            Err(FixtureError::LineLimit)
        );
        assert_eq!(count(&pool).await, 1);
    }
}

#[tokio::test]
async fn record_limit_accepts_ten_thousand_and_rejects_one_more_atomically() {
    let pool = pool().await;
    let input: String = (0..MAX_ROWS)
        .map(|i| format!("{}\n", json(&format!("id{i}"))))
        .collect();
    assert!(input.len() < MAX_BYTES);
    let too_many = format!("{input}{}", json("overflow"));
    assert_eq!(
        import(&pool, too_many.as_bytes()).await,
        Err(FixtureError::RowLimit)
    );
    assert_eq!(count(&pool).await, 0);
    assert_eq!(import(&pool, input.as_bytes()).await, Ok(MAX_ROWS));
    assert_eq!(count(&pool).await, MAX_ROWS as i64);
}

#[tokio::test]
async fn byte_limit_accepts_exactly_one_mib_and_rolls_back_overflow() {
    let pool = pool().await;
    let mut input = String::new();
    for i in 0..255 {
        let value = json(&format!("padded{i}"));
        input.push_str(&value);
        input.push_str(&" ".repeat(MAX_LINE - value.len()));
        input.push('\n');
    }
    let value = json("last");
    let remaining = MAX_BYTES - input.len();
    assert!(remaining >= value.len() && remaining <= MAX_LINE);
    input.push_str(&value);
    input.push_str(&" ".repeat(remaining - value.len()));
    assert_eq!(input.len(), MAX_BYTES);
    let overflow = format!("{input}\n");
    assert_eq!(
        import(&pool, overflow.as_bytes()).await,
        Err(FixtureError::InputLimit)
    );
    assert_eq!(count(&pool).await, 0);
    assert_eq!(import(&pool, input.as_bytes()).await, Ok(256));
}

// Cancels on EOF, after the final row has been written but before COMMIT.
struct CancelAtEof<'a> {
    input: Cursor<Vec<u8>>,
    cancel: &'a Cancellation,
}

impl Read for CancelAtEof<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.input.read(buffer)
    }
}

impl BufRead for CancelAtEof<'_> {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        let bytes = self.input.fill_buf()?;
        if bytes.is_empty() {
            self.cancel.cancel();
        }
        Ok(bytes)
    }

    fn consume(&mut self, amount: usize) {
        self.input.consume(amount);
    }
}

#[tokio::test]
async fn cancellation_before_read_during_processing_and_before_commit() {
    let pool = pool().await;
    let cancel = Cancellation::default();
    cancel.cancel();
    assert_eq!(
        import_jsonl(&pool, &mut Cursor::new(json("a")), &cancel, |_| panic!(
            "pre-cancel must not report progress"
        ))
        .await,
        Err(FixtureError::Cancelled)
    );
    let cancel = Cancellation::default();
    assert_eq!(
        import_jsonl(&pool, &mut Cursor::new(json("a")), &cancel, |_| cancel
            .cancel())
        .await,
        Err(FixtureError::Cancelled)
    );
    let cancel = Cancellation::default();
    let mut reader = CancelAtEof {
        input: Cursor::new(format!("{}\n{}\n", json("a"), json("b")).into_bytes()),
        cancel: &cancel,
    };
    let mut events = Vec::new();
    assert_eq!(
        import_jsonl(&pool, &mut reader, &cancel, |event| events.push(event)).await,
        Err(FixtureError::Cancelled)
    );
    assert!(events.iter().all(|event| !event.committed));
    assert_eq!(count(&pool).await, 0);
}

#[tokio::test]
async fn committed_completion_survives_late_cancel_and_progress_is_throttled() {
    let pool = pool().await;
    let cancel = Cancellation::default();
    let input: String = (0..500)
        .map(|i| format!("{}\n", json(&format!("progress{i}"))))
        .collect();
    let mut events = Vec::new();
    let result = import_jsonl(
        &pool,
        &mut Cursor::new(input.as_bytes()),
        &cancel,
        |event| {
            events.push((Instant::now(), event));
            if event.committed {
                cancel.cancel();
            }
        },
    )
    .await;
    assert_eq!(result, Ok(500));
    assert_eq!(count(&pool).await, 500);
    let provisional: Vec<_> = events
        .iter()
        .filter(|(_, event)| !event.committed)
        .collect();
    for pair in provisional.windows(2) {
        assert!(pair[1].0.duration_since(pair[0].0) >= Duration::from_millis(100));
        assert!(pair[1].1.rows_processed >= pair[0].1.rows_processed);
    }
    assert_eq!(
        events.iter().filter(|(_, event)| event.committed).count(),
        1
    );
    assert_eq!(
        events.last().unwrap().1,
        Progress {
            bytes_read: input.len(),
            rows_processed: 500,
            committed: true
        }
    );
}

#[tokio::test]
async fn database_write_failure_rolls_back_and_does_not_expose_sql() {
    let pool = pool().await;
    sqlx::query("CREATE TRIGGER fixture_failure BEFORE INSERT ON grid_poc_fixture WHEN NEW.id='fail' BEGIN SELECT RAISE(ABORT, 'private SQL /secret/path'); END")
        .execute(&pool).await.unwrap();
    let input = format!("{}\n{}", json("ok"), json("fail"));
    let error = import(&pool, input.as_bytes()).await.unwrap_err();
    assert_eq!(error, FixtureError::Storage);
    assert_eq!(format!("{error:?}"), "Storage");
    assert_eq!(count(&pool).await, 0);
}
// A bounded reader fault/cancel after one successful row tests rollback across
// the reading boundary, rather than only cancellation before any writes.
struct InterruptedInput<'a> {
    input: Cursor<Vec<u8>>,
    boundary: usize,
    cancel: Option<&'a Cancellation>,
}

impl Read for InterruptedInput<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.input.read(buffer)
    }
}

impl BufRead for InterruptedInput<'_> {
    fn fill_buf(&mut self) -> io::Result<&[u8]> {
        let position = self.input.position() as usize;
        if position >= self.boundary && self.cancel.is_none() {
            return Err(io::Error::other("private input /path must not escape"));
        }
        let bytes = self.input.fill_buf()?;
        Ok(&bytes[..bytes
            .len()
            .min(self.boundary.saturating_sub(position).max(1))])
    }

    fn consume(&mut self, amount: usize) {
        self.input.consume(amount);
        if self.input.position() as usize >= self.boundary
            && let Some(cancel) = self.cancel
        {
            cancel.cancel();
        }
    }
}

#[tokio::test]
async fn reader_failure_and_mid_line_cancel_undo_preceding_inserts() {
    let pool = pool().await;
    let first = format!("{}\n", json("first"));
    let input = format!("{first}{}{}", json("second"), " ".repeat(1000));
    let mut faulty = InterruptedInput {
        input: Cursor::new(input.clone().into_bytes()),
        boundary: first.len(),
        cancel: None,
    };
    assert_eq!(
        import_jsonl(&pool, &mut faulty, &Cancellation::default(), |_| {}).await,
        Err(FixtureError::Read)
    );
    assert_eq!(count(&pool).await, 0);
    let cancel = Cancellation::default();
    let mut interrupted = InterruptedInput {
        input: Cursor::new(input.into_bytes()),
        boundary: first.len() + 512,
        cancel: Some(&cancel),
    };
    assert_eq!(
        import_jsonl(&pool, &mut interrupted, &cancel, |_| {}).await,
        Err(FixtureError::Cancelled)
    );
    assert_eq!(count(&pool).await, 0);
}
