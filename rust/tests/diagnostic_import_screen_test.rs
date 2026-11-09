use rust_lib_keel::diagnostics::import_screen::{
    screen_bytes, screen_text, ScreenKind, MAX_PREVIEW_CHARS, MAX_SCREEN_BYTES,
};

#[test]
fn external_screen_returns_only_redacted_preview() {
    let source = r#"{"version":3,"token":"external-secret","language":"en"}"#;
    let result = screen_text(source).unwrap();

    assert_eq!(result.kind, ScreenKind::Config);
    assert!(!result.config_importable);
    assert!(result
        .sensitive_categories
        .iter()
        .any(|c| c == "token-or-access-key"));
    assert!(!result.preview.contains("external-secret"));
}

#[test]
fn external_input_boundaries_are_fixed_and_safe() {
    let too_large = vec![b'x'; MAX_SCREEN_BYTES + 1];
    assert_eq!(
        screen_bytes(&too_large).unwrap_err().code(),
        "KEEL-VALIDATION"
    );
    assert_eq!(
        screen_text(&format!("token={}", "x".repeat(MAX_SCREEN_BYTES)))
            .unwrap_err()
            .code(),
        "KEEL-VALIDATION"
    );

    let preview = screen_text(&format!("plain {}", "x".repeat(MAX_PREVIEW_CHARS + 10))).unwrap();
    assert_eq!(preview.preview.chars().count(), MAX_PREVIEW_CHARS);
}

#[test]
fn malformed_and_future_config_never_become_importable() {
    for input in [r#"{"version":99}"#, r#"{"version":"3"}"#, "{broken"] {
        assert_eq!(screen_text(input).unwrap_err().code(), "KEEL-VALIDATION");
    }
    let unknown = screen_text(r#"{"version":3,"run":"do not execute"}"#).unwrap();
    assert!(!unknown.config_importable);
}
