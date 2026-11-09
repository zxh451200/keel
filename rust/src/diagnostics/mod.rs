//! 诊断：关联 ID、脱敏、文件日志、诊断事件缓冲。

pub mod correlation;
pub mod events;
// Internal core awaits public API/codegen integration.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) mod external_input;
pub mod import_screen;
pub mod logging;
pub mod redact;
