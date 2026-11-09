//! 关联 ID：同一次失败在界面提示、日志和诊断里用同一个 ID，用户报告问题时凭它查找。
//! 形如 `K19a3f2c1b2-0001`：毫秒时间戳（十六进制）加进程内序号，不含任何用户信息。

use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static SEQ: AtomicU32 = AtomicU32::new(0);

pub fn new_correlation_id() -> String {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    format!("K{ms:x}-{:04x}", seq & 0xffff)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_contain_no_spaces() {
        let ids: Vec<String> = (0..100).map(|_| new_correlation_id()).collect();
        let unique: std::collections::HashSet<_> = ids.iter().collect();
        assert_eq!(unique.len(), ids.len());
        assert!(ids
            .iter()
            .all(|id| id.starts_with('K') && !id.contains(' ')));
    }
}
