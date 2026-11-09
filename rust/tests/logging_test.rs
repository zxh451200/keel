//! 日志端到端：错误转成 ApiError 时，详情（含底层原因）和关联 ID 写进日志文件，且已脱敏。
//! 日志初始化和环境变量都是进程级的，所以放在同一个测试里。

use rust_lib_keel::api::error::ApiError;
use rust_lib_keel::diagnostics::logging;
use rust_lib_keel::errors::KeelError;
use std::time::{Duration, Instant};

fn read_logs(dir: &std::path::Path) -> String {
    let mut all = String::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            if let Ok(text) = std::fs::read_to_string(entry.path()) {
                all.push_str(&text);
            }
        }
    }
    all
}

#[test]
fn api_errors_are_logged_with_cause_and_correlation_id_but_redacted() {
    let dir = std::env::temp_dir().join(format!("keel-logging-it-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let log_dir = dir.join("logs");
    logging::init(&log_dir).unwrap();
    logging::init(&log_dir).unwrap(); // 重复初始化无副作用

    let cause = std::io::Error::other("write failed for C:\\Users\\alice\\data.csv token=abc123");
    let api = ApiError::from(KeelError::Io(cause));
    assert_eq!(api.code, "KEEL-IO");
    // 返回给界面的 message 不含底层原因。
    assert!(!api.message.contains("write failed"));

    // 日志是后台线程异步写的，最多等 5 秒。
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut logged = String::new();
    while Instant::now() < deadline {
        logged = read_logs(&log_dir);
        if logged.contains(&api.correlation_id) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    assert!(
        logged.contains(&api.correlation_id),
        "日志里应有关联 ID：{logged}"
    );
    assert!(logged.contains("KEEL-IO"));
    assert!(logged.contains("write failed"), "日志里应有底层原因");
    assert!(!logged.contains("abc123"), "令牌必须被脱敏");
    assert!(!logged.contains("alice"), "用户目录名必须被脱敏");

    let _ = std::fs::remove_dir_all(&dir);
}
