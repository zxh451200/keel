//! 诊断事件缓冲：最近的错误和警告放在内存里（有上限，满了丢最旧的），供诊断中心显示。
//! 写入时统一脱敏；界面只拿到脱敏后的摘要，不含堆栈和 SQL 参数（需求文档 §1.4）。

use crate::diagnostics::redact::redact;
use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

/// 缓冲最多保存的事件数。
pub const CAPACITY: usize = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Info,
    Warn,
    Error,
}

impl Level {
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Info => "info",
            Level::Warn => "warn",
            Level::Error => "error",
        }
    }

    pub fn parse(s: &str) -> Option<Level> {
        match s {
            "info" => Some(Level::Info),
            "warn" => Some(Level::Warn),
            "error" => Some(Level::Error),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Event {
    /// UTC epoch 毫秒
    pub at: i64,
    pub level: Level,
    /// 功能区域，如 "api"、"panic"
    pub area: String,
    /// 错误码，没有则为空
    pub code: String,
    /// 关联 ID，没有则为空
    pub correlation_id: String,
    /// 已脱敏的摘要
    pub summary: String,
}

pub struct EventBuffer {
    capacity: usize,
    items: VecDeque<Event>,
}

impl EventBuffer {
    pub fn new(capacity: usize) -> Self {
        EventBuffer {
            capacity,
            items: VecDeque::new(),
        }
    }

    /// 写入一条事件。摘要在这里脱敏，调用方不用操心。
    pub fn push(&mut self, mut event: Event) {
        event.summary = redact(&event.summary);
        if self.items.len() >= self.capacity {
            self.items.pop_front();
        }
        self.items.push_back(event);
    }

    /// 最新的在前，只返回 `min_level` 及以上的，最多 `limit` 条。
    pub fn recent(&self, limit: usize, min_level: Level) -> Vec<Event> {
        self.items
            .iter()
            .rev()
            .filter(|e| e.level >= min_level)
            .take(limit)
            .cloned()
            .collect()
    }

    /// ID 为空表示不限，否则区分大小写精确匹配。调用方负责 trim 和输入校验。
    /// 在完整缓冲中先筛级别和 ID 再限量，不受诊断中心单次 200 条上限影响。
    pub fn recent_filtered(
        &self,
        limit: usize,
        min_level: Level,
        correlation_id: &str,
    ) -> Vec<Event> {
        self.items
            .iter()
            .rev()
            .filter(|e| {
                e.level >= min_level
                    && (correlation_id.is_empty() || e.correlation_id == correlation_id)
            })
            .take(limit)
            .cloned()
            .collect()
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

fn global() -> &'static Mutex<EventBuffer> {
    static BUFFER: OnceLock<Mutex<EventBuffer>> = OnceLock::new();
    BUFFER.get_or_init(|| Mutex::new(EventBuffer::new(CAPACITY)))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

/// 记一条事件到全局缓冲（时间取当前）。
pub fn record(level: Level, area: &str, code: &str, correlation_id: &str, summary: &str) {
    let event = Event {
        at: now_ms(),
        level,
        area: area.to_string(),
        code: code.to_string(),
        correlation_id: correlation_id.to_string(),
        summary: summary.to_string(),
    };
    global()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(event);
}

pub fn recent(limit: usize, min_level: Level) -> Vec<Event> {
    global()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .recent(limit, min_level)
}

pub fn recent_filtered(limit: usize, min_level: Level, correlation_id: &str) -> Vec<Event> {
    global()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .recent_filtered(limit, min_level, correlation_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(level: Level, summary: &str) -> Event {
        Event {
            at: 1,
            level,
            area: "test".into(),
            code: String::new(),
            correlation_id: String::new(),
            summary: summary.into(),
        }
    }

    #[test]
    fn newest_first_and_limited() {
        let mut buf = EventBuffer::new(10);
        for i in 0..5 {
            buf.push(event(Level::Error, &format!("e{i}")));
        }
        let recent = buf.recent(3, Level::Info);
        let summaries: Vec<_> = recent.iter().map(|e| e.summary.as_str()).collect();
        assert_eq!(summaries, ["e4", "e3", "e2"]);
    }

    #[test]
    fn drops_the_oldest_when_full() {
        let mut buf = EventBuffer::new(3);
        for i in 0..5 {
            buf.push(event(Level::Info, &format!("e{i}")));
        }
        assert_eq!(buf.len(), 3);
        let recent = buf.recent(10, Level::Info);
        assert_eq!(recent.last().unwrap().summary, "e2");
    }

    #[test]
    fn filters_by_minimum_level() {
        let mut buf = EventBuffer::new(10);
        buf.push(event(Level::Info, "i"));
        buf.push(event(Level::Warn, "w"));
        buf.push(event(Level::Error, "e"));
        assert_eq!(buf.recent(10, Level::Info).len(), 3);
        assert_eq!(buf.recent(10, Level::Warn).len(), 2);
        assert_eq!(buf.recent(10, Level::Error).len(), 1);
    }

    #[test]
    fn summary_is_redacted_on_write() {
        let mut buf = EventBuffer::new(10);
        buf.push(event(
            Level::Error,
            "failed password=hunter2 for bob@corp.example.com",
        ));
        let summary = &buf.recent(1, Level::Info)[0].summary;
        assert!(!summary.contains("hunter2"));
        assert!(!summary.contains("bob"));
    }

    #[test]
    fn level_parse_round_trips() {
        for level in [Level::Info, Level::Warn, Level::Error] {
            assert_eq!(Level::parse(level.as_str()), Some(level));
        }
        assert_eq!(Level::parse("debug"), None);
    }

    fn identified_event(level: Level, id: &str, summary: &str) -> Event {
        Event {
            correlation_id: id.into(),
            ..event(level, summary)
        }
    }

    #[test]
    fn id_filter_is_exact_case_sensitive_and_combined_with_level() {
        let mut buf = EventBuffer::new(CAPACITY);
        for (level, id, summary) in [
            (Level::Info, "K-Exact", "info"),
            (Level::Warn, "K-Exact", "warn"),
            (Level::Error, "K-Exact", "error"),
            (Level::Error, "k-exact", "case"),
            (Level::Error, "K-Exact-extra", "suffix"),
            (Level::Error, "prefix-K-Exact", "prefix"),
            (Level::Error, "", "no id"),
        ] {
            buf.push(identified_event(level, id, summary));
        }
        let hits = buf.recent_filtered(200, Level::Warn, "K-Exact");
        let summaries: Vec<_> = hits.iter().map(|e| e.summary.as_str()).collect();
        assert_eq!(summaries, ["error", "warn"]);
        assert_eq!(buf.recent_filtered(200, Level::Info, "K-Exact").len(), 3);
        assert_eq!(buf.recent_filtered(200, Level::Error, "K-Exact").len(), 1);
        assert_eq!(buf.recent_filtered(200, Level::Info, "k-exact").len(), 1);
        assert!(buf.recent_filtered(200, Level::Info, "K-EXACT").is_empty());
        assert!(buf.recent_filtered(200, Level::Info, "missing").is_empty());
        assert!(buf.recent_filtered(0, Level::Info, "K-Exact").is_empty());
    }

    #[test]
    fn empty_id_keeps_recent_behavior_including_events_without_ids() {
        let mut buf = EventBuffer::new(CAPACITY);
        assert!(buf.recent_filtered(200, Level::Info, "").is_empty());
        assert!(buf.recent_filtered(200, Level::Info, "missing").is_empty());
        buf.push(identified_event(Level::Error, "K-a", "identified"));
        buf.push(event(Level::Info, "no id"));
        for level in [Level::Info, Level::Warn, Level::Error] {
            for limit in [0, 1, 200, CAPACITY] {
                let old = buf.recent(limit, level);
                let new = buf.recent_filtered(limit, level, "");
                let old_summaries: Vec<_> = old.iter().map(|e| &e.summary).collect();
                let new_summaries: Vec<_> = new.iter().map(|e| &e.summary).collect();
                assert_eq!(new_summaries, old_summaries);
            }
        }
        assert!(buf.recent_filtered(200, Level::Info, "")[0]
            .correlation_id
            .is_empty());
    }

    #[test]
    fn filters_full_buffer_before_taking_limit_and_preserves_snapshots() {
        let mut buf = EventBuffer::new(CAPACITY);
        buf.push(identified_event(Level::Warn, "target", "older match"));
        buf.push(identified_event(Level::Error, "target", "newer match"));
        for _ in 0..225 {
            buf.push(identified_event(Level::Error, "other", "unrelated"));
            buf.push(identified_event(Level::Info, "target", "below level"));
        }
        let hits = buf.recent_filtered(1, Level::Warn, "target");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].summary, "newer match");
        let hits = buf.recent_filtered(2, Level::Warn, "target");
        let summaries: Vec<_> = hits.iter().map(|e| e.summary.as_str()).collect();
        assert_eq!(summaries, ["newer match", "older match"]);
        // 查询不改变缓冲；诊断包仍可获取超过 200 条的完整事件快照。
        let snapshot = buf.recent(CAPACITY, Level::Info);
        assert!(snapshot.len() > 200);
        assert!(snapshot.iter().any(|e| e.correlation_id == "other"));
        buf.push(identified_event(Level::Error, "target", "later"));
        assert_eq!(hits[0].summary, "newer match");
        assert_eq!(snapshot.last().unwrap().summary, "older match");
    }

    #[test]
    fn id_filter_observes_capacity_eviction_and_write_redaction() {
        let mut buf = EventBuffer::new(CAPACITY);
        buf.push(identified_event(Level::Error, "evicted", "old"));
        for _ in 1..CAPACITY {
            buf.push(identified_event(Level::Info, "other", "filler"));
        }
        assert_eq!(buf.recent_filtered(1, Level::Info, "evicted").len(), 1);
        buf.push(identified_event(
            Level::Error,
            "retained",
            "failed token=buffer-secret",
        ));
        assert_eq!(buf.len(), CAPACITY);
        assert!(buf.recent_filtered(200, Level::Info, "evicted").is_empty());
        let hits = buf.recent_filtered(200, Level::Error, "retained");
        assert_eq!(hits.len(), 1);
        assert!(!hits[0].summary.contains("buffer-secret"));
        assert_eq!(buf.recent(CAPACITY, Level::Info).len(), CAPACITY);
    }
}
