//! 给 Dart 的统一错误。界面按 `code` 分支并翻译成提示，不解析 `message`。

use crate::diagnostics::events::{self, Level};
use crate::diagnostics::{correlation::new_correlation_id, redact::redact};
use crate::errors::KeelError;

#[derive(Debug, Clone)]
pub struct ApiError {
    /// 稳定的错误码，如 `KEEL-VALIDATION`。
    pub code: String,
    /// 已脱敏的说明，只作诊断参考，界面文案按 `code` 翻译。
    pub message: String,
    /// 关联 ID：界面可以显示给用户，用户报告问题时凭它在日志里找到同一次失败。
    pub correlation_id: String,
}

impl From<KeelError> for ApiError {
    fn from(e: KeelError) -> Self {
        let correlation_id = new_correlation_id();
        // 技术详情（含底层原因）只进日志，和关联 ID 一起；不放进返回给界面的 message。
        let detail = redact(&e.detail());
        tracing::error!(code = e.code(), correlation_id = %correlation_id, "{detail}");
        // 同时进诊断事件缓冲，诊断中心显示的就是这些。
        events::record(Level::Error, "api", e.code(), &correlation_id, &detail);
        ApiError {
            code: e.code().to_string(),
            // message 里可能带输入内容，所以先脱敏。
            message: redact(&e.to_string()),
            correlation_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_code_and_redacts_the_message() {
        let e = ApiError::from(KeelError::Validation("password=hunter2".into()));
        assert_eq!(e.code, "KEEL-VALIDATION");
        assert!(!e.message.contains("hunter2"));
        assert!(e.correlation_id.starts_with('K'));
    }

    #[test]
    fn io_cause_is_not_exposed_in_the_message() {
        let cause = std::io::Error::other("C:\\Users\\alice\\secret.txt");
        let e = ApiError::from(KeelError::Io(cause));
        assert_eq!(e.code, "KEEL-IO");
        assert!(!e.message.contains("alice"));
    }

    #[test]
    fn each_error_gets_its_own_correlation_id() {
        let a = ApiError::from(KeelError::Cancelled);
        let b = ApiError::from(KeelError::Cancelled);
        assert_ne!(a.correlation_id, b.correlation_id);
    }
}
