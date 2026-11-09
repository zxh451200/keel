//! 文件日志：按天滚动，写入前统一脱敏（AGENTS.md §6，需求文档 §4.2）。
//!
//! - 日志在 `<数据目录>/logs/keel.log.<日期>`，只保留最近 [`KEEP_LOG_FILES`] 个。
//! - Release 默认 INFO，Debug 构建 DEBUG（不在 Release 输出高量调试日志）。
//! - 每次写入都先过 [`redact`]，密码、令牌、邮箱、用户目录等不会落盘。

use crate::config;
use crate::diagnostics::events::{self, Level};
use crate::diagnostics::{correlation::new_correlation_id, redact::redact};
use crate::errors::KeelError;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use tracing_appender::non_blocking::{NonBlocking, WorkerGuard};
use tracing_subscriber::fmt::MakeWriter;

/// 最多保留的日志文件数（每天一个）。
pub const KEEP_LOG_FILES: usize = 14;

const FILE_PREFIX: &str = "keel.log";

/// 后台写日志线程的守卫；它被释放时缓冲里的日志会丢，所以放全局。
static GUARD: OnceLock<WorkerGuard> = OnceLock::new();

/// 包一层：每次写入前先脱敏。
struct RedactingWriter<W: Write>(W);

impl<W: Write> Write for RedactingWriter<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let text = String::from_utf8_lossy(buf);
        self.0.write_all(redact(&text).as_bytes())?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

struct RedactingMakeWriter(NonBlocking);

impl<'a> MakeWriter<'a> for RedactingMakeWriter {
    type Writer = RedactingWriter<NonBlocking>;

    fn make_writer(&'a self) -> Self::Writer {
        RedactingWriter(self.0.clone())
    }
}

/// 日志放在用户数据目录下的 logs 子目录。
pub fn init_default() -> Result<(), KeelError> {
    init(&config::data_dir()?.join("logs"))
}

/// 初始化日志。只有第一次调用生效，重复调用直接返回 Ok。
pub fn init(log_dir: &Path) -> Result<(), KeelError> {
    if GUARD.get().is_some() {
        return Ok(());
    }
    std::fs::create_dir_all(log_dir)?;
    let _ = prune_old_logs(log_dir, KEEP_LOG_FILES); // 清理失败不影响启动

    let appender = tracing_appender::rolling::daily(log_dir, FILE_PREFIX);
    let (writer, guard) = tracing_appender::non_blocking(appender);

    let level = if cfg!(debug_assertions) {
        tracing::Level::DEBUG
    } else {
        tracing::Level::INFO
    };
    let subscriber = tracing_subscriber::fmt()
        .with_writer(RedactingMakeWriter(writer))
        .with_ansi(false)
        .with_max_level(level)
        .finish();
    tracing::subscriber::set_global_default(subscriber).map_err(KeelError::internal)?;

    let _ = GUARD.set(guard);
    Ok(())
}

/// 删除最旧的日志文件，只留 `keep` 个。文件名里的日期能直接按字典序比较。
pub fn prune_old_logs(dir: &Path, keep: usize) -> io::Result<()> {
    let mut logs: Vec<PathBuf> = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name == FILE_PREFIX || name.starts_with(&format!("{FILE_PREFIX}.")) {
            logs.push(entry.path());
        }
    }
    logs.sort();
    let excess = logs.len().saturating_sub(keep);
    for path in logs.into_iter().take(excess) {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

/// 安装 panic 钩子：任何线程 panic 时，把位置和（脱敏后的）原因写进日志，再交给原来的钩子处理。
/// 不装的话，Rust 侧崩溃只在控制台留一行，日志文件里什么都没有。只有第一次调用生效。
pub fn install_panic_hook() {
    static INSTALLED: std::sync::Once = std::sync::Once::new();
    INSTALLED.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let payload = info
                .payload()
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| info.payload().downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "（无法读取的 panic 内容）".to_string());
            let place = info
                .location()
                .map(|l| format!("{}:{}", l.file(), l.line()))
                .unwrap_or_default();
            let detail = redact(&format!("panic at {place}: {payload}"));
            let correlation_id = new_correlation_id();
            tracing::error!(code = "KEEL-INTERNAL", correlation_id = %correlation_id, "{detail}");
            events::record(
                Level::Error,
                "panic",
                "KEEL-INTERNAL",
                &correlation_id,
                &detail,
            );
            previous(info);
        }));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writer_redacts_secrets_and_keeps_the_newline() {
        let mut out: Vec<u8> = Vec::new();
        {
            let mut w = RedactingWriter(&mut out);
            writeln!(w, "login password=hunter2 for alice@corp.example.com").unwrap();
        }
        let text = String::from_utf8(out).unwrap();
        assert!(!text.contains("hunter2"));
        assert!(!text.contains("alice"));
        assert!(text.ends_with('\n'));
    }

    #[test]
    fn prune_keeps_only_the_newest_log_files() {
        let dir = std::env::temp_dir().join(format!("keel-logs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for day in 1..=5 {
            std::fs::write(dir.join(format!("keel.log.2026-11-0{day}")), "x").unwrap();
        }
        std::fs::write(dir.join("other.txt"), "keep me").unwrap();

        prune_old_logs(&dir, 2).unwrap();

        let mut left: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(
            left,
            vec!["keel.log.2026-11-04", "keel.log.2026-11-05", "other.txt"]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
