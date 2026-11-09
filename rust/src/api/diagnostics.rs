//! 诊断中心的数据入口：读取最近的诊断事件（已脱敏）。

use crate::api::error::ApiError;
use crate::diagnostics::events::{self, Level};
use crate::errors::KeelError;

#[derive(Debug, Clone)]
pub struct DiagnosticPackRequest {
    /// 至少一项：runtime / recent_events。UI 默认仅选择 runtime。
    pub categories: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct DiagnosticPackPreview {
    /// 进程内、绑定当前用户名字和角色、5 分钟有效的单次句柄。
    pub preview_id: String,
    /// 已脱敏的完整快照；导出逐字节写入此文本。
    pub content: String,
    /// 去重后的类别，固定按 runtime、recent_events 排序。
    pub categories: Vec<String>,
    pub event_count: u32,
}

/// 外部输入的完整脱敏快照；导出复用诊断包的单次消费入口。
#[derive(Debug, Clone)]
pub struct ExternalDiagnosticPreview {
    pub preview_id: String,
    pub content: String,
    pub sensitive_categories: Vec<String>,
}

/// 仅筛查诊断文本，不解析或导入配置。
pub async fn prepare_external_diagnostic_text(
    text: String,
) -> Result<ExternalDiagnosticPreview, ApiError> {
    let preview =
        crate::services::diagnostic_input::prepare_text(crate::state::pool()?, &text).await?;
    Ok(ExternalDiagnosticPreview {
        preview_id: preview.preview_id,
        content: preview.content,
        sensitive_categories: preview.sensitive_categories,
    })
}

/// 受限读取外部诊断文件；路径不会进入返回 DTO。
pub async fn prepare_external_diagnostic_file(
    path: String,
) -> Result<ExternalDiagnosticPreview, ApiError> {
    let preview = crate::services::diagnostic_input::prepare_file(
        crate::state::pool()?,
        std::path::Path::new(&path),
    )
    .await?;
    Ok(ExternalDiagnosticPreview {
        preview_id: preview.preview_id,
        content: preview.content,
        sensitive_categories: preview.sensitive_categories,
    })
}

/// 一次最多返回的条数。
const MAX_LIMIT: u32 = 200;
const MAX_CORRELATION_ID_CHARS: usize = 128;

#[derive(Debug, Clone)]
pub struct DiagnosticEventQuery {
    /// 返回条数，限制在 1..=200。
    pub limit: u32,
    /// "info" | "warn" | "error"，包含该级别及以上。
    pub min_level: String,
    /// Unicode trim 后为空表示不限；否则区分大小写精确匹配。
    /// trim 后最多 128 个 Unicode 标量，且不允许控制字符。
    pub correlation_id: String,
}

#[derive(Debug, Clone)]
pub struct DiagnosticEvent {
    /// UTC epoch 毫秒
    pub at: i64,
    /// "info" | "warn" | "error"
    pub level: String,
    /// 功能区域，如 "api"、"panic"
    pub area: String,
    /// 错误码，没有则为空
    pub code: String,
    /// 关联 ID，没有则为空
    pub correlation_id: String,
    /// 已脱敏的摘要
    pub summary: String,
}

/// 按级别和关联 ID 筛选后限量返回，最新的在前；不改变诊断包的采集范围。
pub fn recent_events(query: DiagnosticEventQuery) -> Result<Vec<DiagnosticEvent>, ApiError> {
    let level = Level::parse(&query.min_level)
        .ok_or_else(|| KeelError::Validation("level 需为 info / warn / error".into()))?;
    let correlation_id = query.correlation_id.trim();
    if correlation_id.chars().count() > MAX_CORRELATION_ID_CHARS
        || correlation_id.chars().any(char::is_control)
    {
        // 不将查询原文带入 ApiError、日志或诊断事件。
        return Err(KeelError::Validation(
            "correlation_id 最多 128 个 Unicode 标量且不能包含控制字符".into(),
        )
        .into());
    }
    let limit = query.limit.clamp(1, MAX_LIMIT) as usize;
    Ok(events::recent_filtered(limit, level, correlation_id)
        .into_iter()
        .map(|e| DiagnosticEvent {
            at: e.at,
            level: e.level.as_str().to_string(),
            area: e.area,
            code: e.code,
            correlation_id: e.correlation_id,
            summary: e.summary,
        })
        .collect())
}

/// 权限检查后准备脱敏快照。空/未知类别返回 KEEL-VALIDATION。
pub async fn prepare_diagnostic_pack(
    request: DiagnosticPackRequest,
) -> Result<DiagnosticPackPreview, ApiError> {
    Ok(crate::services::diagnostic_pack::prepare(
        crate::state::pool()?,
        request,
        env!("CARGO_PKG_VERSION"),
    )
    .await?)
}

/// 再查权限和 owner 后消费快照。失败后应重新 prepare；不重新读取事件。
pub async fn export_prepared_diagnostic_pack(preview_id: String) -> Result<String, ApiError> {
    let path = crate::services::diagnostic_pack::export_prepared(
        crate::state::pool()?,
        crate::state::db_path()?,
        &preview_id,
    )
    .await?;
    Ok(path.to_string_lossy().into_owned())
}

/// Bounded read-only search of this application's rolling log files. No paths accepted.
#[derive(Debug, Clone)]
pub struct DiagnosticHistoryQuery {
    /// Case-sensitive literal substring of redacted text; empty means any line.
    pub text: String,
}

#[derive(Debug, Clone, Default)]
pub struct DiagnosticHistoryPage {
    /// Original tracing text, redacted again; newest file first, file order within each.
    pub lines: Vec<String>,
    /// Any directory/file/byte/result/line bound, or skipped unsafe/invalid input.
    pub truncated: bool,
    pub scanned_files: u32,
    pub scanned_bytes: u32,
    pub skipped_lines: u32,
}

pub async fn search_diagnostic_history(
    query: DiagnosticHistoryQuery,
) -> Result<DiagnosticHistoryPage, ApiError> {
    Ok(crate::services::diagnostic_history::search(crate::state::pool()?, query).await?)
}
