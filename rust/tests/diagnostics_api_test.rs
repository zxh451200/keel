//! 诊断中心的数据入口：API 错误和 panic 都会进入诊断事件，且已脱敏。
//! 事件缓冲是进程级的；本文件所有测试串行访问，并使用独立关联 ID。

use rust_lib_keel::api::diagnostics::{recent_events, DiagnosticEventQuery};
use rust_lib_keel::api::error::ApiError;
use rust_lib_keel::diagnostics::correlation::new_correlation_id;
use rust_lib_keel::diagnostics::events::{self, Level};
use rust_lib_keel::diagnostics::logging;
use rust_lib_keel::errors::KeelError;
use std::sync::Mutex;

// 批量写入/不限 ID 的断言也必须持锁，避免其他测试写入导致条数变化或提前淘汰。
// 其他集成测试文件运行于独立进程，不共享此缓冲。
static TEST_LOCK: Mutex<()> = Mutex::new(());

fn query(limit: u32, min_level: &str, correlation_id: &str) -> DiagnosticEventQuery {
    DiagnosticEventQuery {
        limit,
        min_level: min_level.into(),
        correlation_id: correlation_id.into(),
    }
}

fn record(level: Level, id: &str, summary: &str) {
    events::record(level, "query-test", "", id, summary);
}

#[test]
fn api_errors_show_up_with_correlation_id_and_redaction() {
    let _guard = TEST_LOCK.lock().unwrap();
    let api = ApiError::from(KeelError::Io(std::io::Error::other(
        "open failed token=unique-token-marker",
    )));

    let events = recent_events(query(50, "error", &api.correlation_id)).unwrap();
    assert_eq!(events.len(), 1);
    let hit = &events[0];
    assert_eq!(hit.correlation_id, api.correlation_id);
    assert_eq!(hit.code, "KEEL-IO");
    assert_eq!(hit.area, "api");
    assert_eq!(hit.level, "error");
    assert!(hit.summary.contains("open failed"), "诊断里应有底层原因");
    assert!(
        !hit.summary.contains("unique-token-marker"),
        "令牌必须被脱敏"
    );
    assert!(!api.message.contains("unique-token-marker"));

    let validation = ApiError::from(KeelError::Validation("password=conversion-secret".into()));
    assert!(!validation.message.contains("conversion-secret"));
    let events = recent_events(query(1, "error", &validation.correlation_id)).unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].code, "KEEL-VALIDATION");
    assert!(!events[0].summary.contains("conversion-secret"));
}

#[test]
fn panics_are_recorded_and_redacted() {
    let _guard = TEST_LOCK.lock().unwrap();
    logging::install_panic_hook();
    let marker = new_correlation_id();
    let result = std::panic::catch_unwind(|| {
        panic!("boom {marker} password=unique-panic-marker");
    });
    assert!(result.is_err());

    let events = recent_events(query(200, "error", "")).unwrap();
    let hit = events
        .iter()
        .find(|e| e.area == "panic" && e.summary.contains(&marker))
        .expect("panic 应进入诊断事件");
    assert_eq!(hit.code, "KEEL-INTERNAL");
    assert!(!hit.correlation_id.is_empty());
    assert!(!hit.summary.contains("unique-panic-marker"));
    let exact = recent_events(query(1, "error", &hit.correlation_id)).unwrap();
    assert_eq!(exact.len(), 1);
    assert_eq!(exact[0].summary, hit.summary);
}

#[test]
fn id_is_trimmed_then_matched_exactly_with_level() {
    let _guard = TEST_LOCK.lock().unwrap();
    let id = new_correlation_id();
    record(Level::Info, &id, "info");
    record(Level::Warn, &id, "warn");
    record(Level::Error, &id, "error");
    record(Level::Error, &format!("{id}-suffix"), "suffix");
    record(Level::Error, &format!("prefix-{id}"), "prefix");
    record(Level::Error, &id.to_lowercase(), "case");
    let padded = format!("\u{3000}\u{a0}\t\n{id}\r\u{2003}");
    let hits = recent_events(query(200, "warn", &padded)).unwrap();
    let summaries: Vec<_> = hits.iter().map(|e| e.summary.as_str()).collect();
    assert_eq!(summaries, ["error", "warn"]);
    assert!(hits.iter().all(|e| e.correlation_id == id));
    assert_eq!(recent_events(query(200, "info", &id)).unwrap().len(), 3);
    assert_eq!(recent_events(query(200, "error", &id)).unwrap().len(), 1);
    assert!(recent_events(query(200, "info", &new_correlation_id()))
        .unwrap()
        .is_empty());
}

#[test]
fn empty_or_unicode_whitespace_id_preserves_unfiltered_results() {
    let _guard = TEST_LOCK.lock().unwrap();
    let marker = new_correlation_id();
    record(Level::Error, "", &marker);
    let expected = events::recent(200, Level::Info);
    for id in ["", " \t\n\r\u{a0}\u{2003}\u{3000}"] {
        let actual = recent_events(query(200, "info", id)).unwrap();
        assert_eq!(actual.len(), expected.len());
        for (actual, expected) in actual.iter().zip(&expected) {
            assert_eq!(actual.at, expected.at);
            assert_eq!(actual.level, expected.level.as_str());
            assert_eq!(actual.area, expected.area);
            assert_eq!(actual.code, expected.code);
            assert_eq!(actual.correlation_id, expected.correlation_id);
            assert_eq!(actual.summary, expected.summary);
        }
        assert!(actual
            .iter()
            .any(|e| e.correlation_id.is_empty() && e.summary == marker));
    }
}

#[test]
fn id_length_counts_unicode_scalars_after_trim() {
    let _guard = TEST_LOCK.lock().unwrap();
    let prefix = new_correlation_id();
    // U+1F980 在 UTF-8 中占 4 字节、UTF-16 中占 2 个 code unit，但只算一个标量。
    let id = format!(
        "{prefix}{}",
        "\u{1f980}".repeat(128 - prefix.chars().count())
    );
    assert_eq!(id.chars().count(), 128);
    record(Level::Error, &id, "unicode boundary");
    let padded = format!("\u{3000}{id}\u{a0}");
    let hits = recent_events(query(1, "info", &padded)).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].correlation_id, id);

    let overlong = format!("{id}x");
    let error = recent_events(query(1, "info", &overlong)).unwrap_err();
    assert_validation_does_not_leak(&error, &overlong);
}

fn assert_validation_does_not_leak(error: &ApiError, input: &str) {
    assert_eq!(error.code, "KEEL-VALIDATION");
    assert!(!error.message.contains(input));
    assert_ne!(error.correlation_id, input);
    let hits = recent_events(query(1, "error", &error.correlation_id)).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].area, "api");
    assert_eq!(hits[0].code, "KEEL-VALIDATION");
    for field in [
        error.code.as_str(),
        error.message.as_str(),
        error.correlation_id.as_str(),
        hits[0].area.as_str(),
        hits[0].code.as_str(),
        hits[0].correlation_id.as_str(),
        hits[0].summary.as_str(),
    ] {
        // 比较实际字段，避免 Debug 转义控制字符后使 no-leak 断言空过。
        assert!(!field.contains(input));
    }
}

#[test]
fn invalid_ids_use_fixed_errors_without_recording_raw_input() {
    let _guard = TEST_LOCK.lock().unwrap();
    let overlong = format!("unredactable-private-input-{}", "x".repeat(129));
    let reference = recent_events(query(10, "info", &overlong)).unwrap_err();
    assert_validation_does_not_leak(&reference, &overlong);
    // char::is_control 对应 C0 (U+0000..001F)、DEL 和 C1 (U+007F..009F)。
    for codepoint in (0..=0x1f).chain(0x7f..=0x9f) {
        let control = char::from_u32(codepoint).unwrap();
        let input = format!("private-{}{control}-tail", new_correlation_id());
        let error = recent_events(query(10, "info", &input)).unwrap_err();
        assert_eq!(error.message, reference.message);
        assert_validation_does_not_leak(&error, &input);
    }
    // trim 不会移除 NUL/DEL；位于边缘也必须拒绝。
    for input in ["\0private-edge", "private-edge\u{7f}"] {
        let error = recent_events(query(10, "info", input)).unwrap_err();
        assert_validation_does_not_leak(&error, input);
    }
    let hits = recent_events(query(200, "info", "")).unwrap();
    let text = format!("{hits:?}");
    assert!(!text.contains("unredactable-private-input"));
    assert!(!text.contains("private-edge"));
    assert!(!text.contains("private-K"));
}

#[test]
fn invalid_level_validation_remains_strict_and_does_not_leak() {
    let _guard = TEST_LOCK.lock().unwrap();
    let reference = recent_events(query(10, "debug", "")).unwrap_err();
    for level in ["", "Info", "INFO", " info", "info ", "private-level-input"] {
        let error = recent_events(query(10, level, "")).unwrap_err();
        assert_eq!(error.code, "KEEL-VALIDATION");
        assert_eq!(error.message, reference.message);
    }
    let error = recent_events(query(10, "private-level-input", "")).unwrap_err();
    assert_validation_does_not_leak(&error, "private-level-input");
}

#[test]
fn limit_is_clamped_after_filtering_the_full_buffer() {
    let _guard = TEST_LOCK.lock().unwrap();
    let id = new_correlation_id();
    let other = new_correlation_id();
    record(Level::Warn, &id, "older");
    record(Level::Error, &id, "newer");
    // 匹配项在最近 200 条之外；低级别同 ID 和高级别其他 ID 均不能消耗 limit。
    for _ in 0..105 {
        record(Level::Info, &id, "below level");
        record(Level::Error, &other, "unrelated");
    }
    for limit in [0, 1] {
        let hits = recent_events(query(limit, "warn", &id)).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].summary, "newer");
    }
    let hits = recent_events(query(2, "warn", &id)).unwrap();
    let summaries: Vec<_> = hits.iter().map(|e| e.summary.as_str()).collect();
    assert_eq!(summaries, ["newer", "older"]);

    let bulk = new_correlation_id();
    for _ in 0..205 {
        record(Level::Error, &bulk, "bulk");
    }
    for limit in [200, 201, 100_000, u32::MAX] {
        let hits = recent_events(query(limit, "info", &bulk)).unwrap();
        assert_eq!(hits.len(), 200);
        assert!(hits.iter().all(|e| e.correlation_id == bulk));
        assert_eq!(recent_events(query(limit, "info", "")).unwrap().len(), 200);
    }
    assert_eq!(recent_events(query(0, "info", "")).unwrap().len(), 1);
}
