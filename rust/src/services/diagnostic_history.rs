//! Bounded text search; tracing text is preserved, never treated as JSON/events or executed.
//! Only this service selects the directory. Filesystem work runs on the blocking pool.
use crate::api::diagnostics::{DiagnosticHistoryPage, DiagnosticHistoryQuery};
use crate::diagnostics::redact::redact;
use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::access;
use sqlx::SqlitePool;
use std::fs::{self, Metadata, OpenOptions};
use std::io::{BufRead, BufReader, Read};
use std::path::Path;

const MAX_FILES: usize = 14;
const MAX_DIRECTORY_ENTRIES: usize = 256;
const MAX_BYTES: u64 = 4 * 1024 * 1024;
const MAX_LINE_BYTES: u64 = 8192;
const MAX_RESULTS: usize = 200;
const MAX_OUTPUT_CHARS: usize = 2048;
// Bound concurrent scans too. No lock is held on the UI thread.
static SCAN: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);

fn validate(text: &str) -> Result<(), KeelError> {
    if text.chars().count() > 128 || text.chars().any(char::is_control) {
        return Err(KeelError::Validation(
            "History text must be at most 128 characters without controls".into(),
        ));
    }
    Ok(())
}

pub async fn search(
    pool: &SqlitePool,
    query: DiagnosticHistoryQuery,
) -> Result<DiagnosticHistoryPage, KeelError> {
    let owner = access::require(pool, Permission::DiagnosticsExport).await?;
    validate(&query.text)?;
    let permit = SCAN
        .try_acquire()
        .map_err(|_| KeelError::Validation("History search is busy; retry".into()))?;
    let dir = crate::config::data_dir()?.join("logs");
    let result = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        scan(&dir, &query.text)
    })
    .await;
    // Discard data AND IO errors if the identity/role changed during the read.
    let current = access::require(pool, Permission::DiagnosticsExport).await?;
    check_owner(&owner, &current)?;
    result.map_err(|_| KeelError::internal("History worker failed"))?
}

fn check_owner(
    owner: &access::CurrentUser,
    current: &access::CurrentUser,
) -> Result<(), KeelError> {
    if current != owner {
        return Err(KeelError::PermissionDenied(
            "diagnostics.history.owner".into(),
        ));
    }
    Ok(())
}

fn unsafe_link(meta: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return true;
        }
    }
    meta.file_type().is_symlink()
}

fn check_directories(dir: &Path) -> std::io::Result<()> {
    for parent in dir.ancestors() {
        let meta = fs::symlink_metadata(parent)?;
        if unsafe_link(&meta) || !meta.is_dir() {
            return Err(std::io::Error::other("Unsafe history directory"));
        }
    }
    Ok(())
}

/// Actual tracing_appender::rolling::daily naming: keel.log.YYYY-MM-DD.
fn log_name(name: &str) -> bool {
    let Some(date) = name.strip_prefix("keel.log.") else {
        return false;
    };
    let b = date.as_bytes();
    if b.len() != 10
        || b[4] != b'-'
        || b[7] != b'-'
        || b.iter()
            .enumerate()
            .any(|(i, c)| i != 4 && i != 7 && !c.is_ascii_digit())
    {
        return false;
    }
    let year: u32 = date[..4].parse().unwrap_or(0);
    let month: u32 = date[5..7].parse().unwrap_or(0);
    let day: u32 = date[8..].parse().unwrap_or(0);
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    let days = match month {
        2 if leap => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        _ => 0,
    };
    year > 0 && day > 0 && day <= days
}

fn same_file(a: &Metadata, b: &Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        a.dev() == b.dev() && a.ino() == b.ino()
    }
    #[cfg(not(unix))]
    {
        a.created().ok().is_some() && a.created().ok() == b.created().ok()
    }
}

fn scan(dir: &Path, text: &str) -> Result<DiagnosticHistoryPage, KeelError> {
    validate(text)?;
    let mut page = DiagnosticHistoryPage::default();
    if let Err(error) = check_directories(dir) {
        if error.kind() == std::io::ErrorKind::NotFound {
            return Ok(page);
        }
        return Err(KeelError::Io(std::io::Error::other(
            "History directory unavailable",
        )));
    }
    let mut paths = Vec::new();
    let mut entries = fs::read_dir(dir)?;
    for index in 0..MAX_DIRECTORY_ENTRIES {
        let Some(entry) = entries.next() else {
            break;
        };
        let entry = entry?;
        // Do not probe one more entry; reaching the budget is conservatively truncated.
        if index + 1 == MAX_DIRECTORY_ENTRIES {
            page.truncated = true;
        }
        if !entry.file_name().to_str().is_some_and(log_name) {
            continue;
        }
        let meta = fs::symlink_metadata(entry.path())?;
        if unsafe_link(&meta) || !meta.is_file() {
            page.truncated = true;
            continue;
        }
        paths.push(entry.path());
    }
    paths.sort_by(|a, b| b.cmp(a));
    if paths.len() > MAX_FILES {
        page.truncated = true;
        paths.truncate(MAX_FILES);
    }
    for path in paths {
        if u64::from(page.scanned_bytes) >= MAX_BYTES {
            page.truncated = true;
            break;
        }
        check_directories(dir)?;
        let before = fs::symlink_metadata(&path)?;
        if unsafe_link(&before) || !before.is_file() {
            page.truncated = true;
            continue;
        }
        let mut options = OpenOptions::new();
        options.read(true);
        // O_NOFOLLOW | O_NONBLOCK prevents a raced symlink/FIFO open on Linux.
        #[cfg(target_os = "linux")]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(0x20000 | 0x800);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.custom_flags(0x00200000);
        }
        let file = options.open(&path)?;
        let opened = file.metadata()?;
        if unsafe_link(&opened) || !opened.is_file() || !same_file(&before, &opened) {
            page.truncated = true;
            continue;
        }
        #[cfg(windows)]
        let identity = windows_identity(&file)?;
        // Snapshot size excludes concurrent appends; Take bounds actual bytes read.
        let budget = (MAX_BYTES - u64::from(page.scanned_bytes)).min(opened.len());
        if budget < opened.len() {
            page.truncated = true;
        }
        let mut reader = BufReader::new(file.take(budget));
        page.scanned_files += 1;
        let mut result_limit = false;
        loop {
            let mut line = Vec::new();
            let n = reader
                .by_ref()
                .take(MAX_LINE_BYTES + 1)
                .read_until(b'\n', &mut line)?;
            if n == 0 {
                break;
            }
            page.scanned_bytes += n as u32;
            // Never return partial secrets from split/overlong or invalid UTF-8 lines.
            if n as u64 > MAX_LINE_BYTES || !line.ends_with(b"\n") {
                page.skipped_lines += 1;
                page.truncated = true;
                if !line.ends_with(b"\n") {
                    loop {
                        let mut discard = Vec::new();
                        let n = reader
                            .by_ref()
                            .take(MAX_LINE_BYTES)
                            .read_until(b'\n', &mut discard)?;
                        page.scanned_bytes += n as u32;
                        if n == 0 || discard.ends_with(b"\n") {
                            break;
                        }
                    }
                }
                continue;
            }
            let Ok(raw) = std::str::from_utf8(&line) else {
                page.skipped_lines += 1;
                page.truncated = true;
                continue;
            };
            let safe = redact(raw.trim_end_matches(['\r', '\n']));
            let safe: String = safe
                .chars()
                .map(|c| if c.is_control() { ' ' } else { c })
                .collect();
            if !safe.contains(text) {
                continue;
            }
            if page.lines.len() == MAX_RESULTS {
                page.truncated = true;
                result_limit = true;
                break;
            }
            if safe.chars().count() > MAX_OUTPUT_CHARS {
                page.truncated = true;
            }
            page.lines
                .push(safe.chars().take(MAX_OUTPUT_CHARS).collect());
        }
        let after = fs::symlink_metadata(&path)?;
        if unsafe_link(&after) || !same_file(&opened, &after) {
            return Err(KeelError::Io(std::io::Error::other("History file changed")));
        }
        #[cfg(windows)]
        {
            let verify = options.open(&path)?;
            if unsafe_link(&verify.metadata()?) || windows_identity(&verify)? != identity {
                return Err(KeelError::Io(std::io::Error::other("History file changed")));
            }
        }
        if result_limit {
            break;
        }
    }
    check_directories(dir)?;
    Ok(page)
}

#[cfg(windows)]
fn windows_identity(file: &std::fs::File) -> Result<(u32, u32, u32), KeelError> {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    // Win32 BY_HANDLE_FILE_INFORMATION，布局与 import_screen 中的实现一致。
    #[repr(C)]
    struct Information {
        attributes: u32,
        creation: [u32; 2],
        access: [u32; 2],
        write: [u32; 2],
        volume: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFileInformationByHandle(handle: *mut c_void, info: *mut Information) -> i32;
    }
    let mut info = std::mem::MaybeUninit::<Information>::uninit();
    // SAFETY: File 句柄在调用期间有效，输出缓冲符合 Win32 ABI，仅成功后读取。
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), info.as_mut_ptr()) } == 0 {
        return Err(KeelError::Io(std::io::Error::last_os_error()));
    }
    // SAFETY: 成功返回说明 Win32 已初始化完整结构。
    let info = unsafe { info.assume_init() };
    Ok((info.volume, info.index_high, info.index_low))
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Temp(std::path::PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "keel-history-{}-{}",
                std::process::id(),
                crate::diagnostics::correlation::new_correlation_id()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn write(&self, name: &str, text: impl AsRef<[u8]>) {
            fs::write(self.0.join(name), text).unwrap();
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn real_files_redact_before_matching_and_preserve_tracing_format() {
        let t = Temp::new();
        let raw = "2026-11-02T00:00:00Z  INFO keel: login password=hunter2 id=K-1\n";
        t.write("keel.log.2026-11-02", raw);
        t.write("keel.log.2026-11-01", "older\n");
        for name in [
            "keel.log",
            "keel.log.2026-11-03.bak",
            "keel.log.2026-02-30",
            "other.log",
        ] {
            t.write(name, "forbidden\n");
        }
        fs::create_dir(t.0.join("keel.log.2026-11-04")).unwrap();
        let p = scan(&t.0, "").unwrap();
        assert_eq!(p.scanned_files, 2);
        assert_eq!(
            p.lines,
            [
                "2026-11-02T00:00:00Z  INFO keel: login password=*** id=K-1",
                "older"
            ]
        );
        assert!(p.truncated); // matching directory was rejected
        assert!(scan(&t.0, "hunter2").unwrap().lines.is_empty());
        assert_eq!(scan(&t.0, "password=***").unwrap().lines.len(), 1);
        assert_eq!(
            fs::read_to_string(t.0.join("keel.log.2026-11-02")).unwrap(),
            raw
        );
    }

    #[test]
    fn malformed_long_and_partial_lines_never_return_fragments() {
        let t = Temp::new();
        let mut bytes = vec![b'x'; MAX_LINE_BYTES as usize + 10];
        bytes.extend_from_slice(b"password=secret-tail\n");
        bytes.extend_from_slice(b"invalid-utf8-\xff\n");
        bytes.extend_from_slice("中".repeat(3000).as_bytes()); // >8192: skipped whole
        bytes.extend_from_slice(b"\n");
        bytes.extend_from_slice("中".repeat(2500).as_bytes()); // valid, output length bounded
        bytes.extend_from_slice(b"\nnot-json token=hide-me\npartial password=no-newline");
        t.write("keel.log.2026-11-02", &bytes);
        let p = scan(&t.0, "").unwrap();
        assert!(p.truncated);
        assert_eq!(p.skipped_lines, 4);
        assert_eq!(p.lines.len(), 2);
        assert_eq!(p.lines[0].chars().count(), MAX_OUTPUT_CHARS);
        assert_eq!(p.lines[1], "not-json token=***");
        assert_eq!(p.scanned_bytes as usize, bytes.len());
    }

    #[test]
    fn file_result_and_byte_budgets_are_enforced() {
        let t = Temp::new();
        for day in 1..=15 {
            t.write(&format!("keel.log.2026-11-{day:02}"), "entry\n");
        }
        let p = scan(&t.0, "").unwrap();
        assert_eq!(p.scanned_files as usize, MAX_FILES);
        assert!(p.truncated);
        t.write("keel.log.2026-11-15", "hit\n".repeat(201));
        let p = scan(&t.0, "hit").unwrap();
        assert_eq!(p.lines.len(), MAX_RESULTS);
        assert!(p.truncated);
        t.write("keel.log.2026-11-15", vec![b'x'; MAX_BYTES as usize + 1]);
        let p = scan(&t.0, "no hit").unwrap();
        assert_eq!(u64::from(p.scanned_bytes), MAX_BYTES);
        assert!(p.truncated);
        assert!(p.lines.is_empty());
    }

    #[test]
    fn directory_budget_is_conservative_at_exact_limit() {
        for count in [
            0,
            MAX_DIRECTORY_ENTRIES - 1,
            MAX_DIRECTORY_ENTRIES,
            MAX_DIRECTORY_ENTRIES + 1,
        ] {
            let t = Temp::new();
            // Ignored names still consume the enumeration budget.
            for i in 0..count {
                t.write(&format!("other-{i}"), "");
            }
            let p = scan(&t.0, "").unwrap();
            assert_eq!(
                p.truncated,
                count >= MAX_DIRECTORY_ENTRIES,
                "directory entries: {count}"
            );
            assert_eq!(p.scanned_files, 0);
            assert!(p.lines.is_empty());
        }
    }

    #[test]
    fn directory_bound_and_missing_directory() {
        let t = Temp::new();
        for i in 0..=MAX_DIRECTORY_ENTRIES {
            t.write(&format!("other-{i}"), "");
        }
        assert!(scan(&t.0, "").unwrap().truncated);
        assert!(scan(&t.0.join("missing"), "").unwrap().lines.is_empty());
        for text in ["x".repeat(129), "bad\0query".into()] {
            assert!(matches!(scan(&t.0, &text), Err(KeelError::Validation(_))));
        }
    }

    #[cfg(unix)]
    #[test]
    fn rejects_file_and_directory_symlinks() {
        use std::os::unix::fs::symlink;
        let t = Temp::new();
        t.write("outside", "outside-secret\n");
        symlink(t.0.join("outside"), t.0.join("keel.log.2026-11-02")).unwrap();
        let p = scan(&t.0, "").unwrap();
        assert!(p.lines.is_empty());
        assert!(p.truncated);
        symlink(&t.0, t.0.join("linked-directory")).unwrap();
        assert!(scan(&t.0.join("linked-directory"), "").is_err());
        assert_eq!(
            fs::read_to_string(t.0.join("outside")).unwrap(),
            "outside-secret\n"
        );
    }

    #[test]
    fn owner_recheck_binds_name_and_role() {
        use crate::domain::permissions::Role;
        let owner = access::CurrentUser {
            name: "a".into(),
            role: Role::Admin,
        };
        assert!(check_owner(&owner, &owner).is_ok());
        for current in [
            access::CurrentUser {
                name: "b".into(),
                role: Role::Admin,
            },
            access::CurrentUser {
                name: "a".into(),
                role: Role::Operator,
            },
        ] {
            assert!(matches!(
                check_owner(&owner, &current),
                Err(KeelError::PermissionDenied(_))
            ));
        }
    }
}
