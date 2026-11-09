use crate::api::error::ApiError;

/// Read-only metadata; entries do not grant cancel or save-copy handles.
#[derive(Debug, Clone)]
pub struct AuditExportHistoryEntry {
    pub task_id: String,
    pub created_at_ms: i64,
    pub finished_at_ms: Option<i64>,
    pub phase: String,
    pub completed_rows: u32,
    pub total_rows: u32,
    /// Basename only, deliberately not an openable path.
    pub result_name: Option<String>,
    pub error_code: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AuditExportHistoryPage {
    pub entries: Vec<AuditExportHistoryEntry>,
    pub total: i64,
    pub page: u32,
    pub page_size: u32,
}

pub async fn list_audit_export_history(
    page: u32,
    page_size: u32,
) -> Result<AuditExportHistoryPage, ApiError> {
    Ok(crate::services::audit_export_history::list(crate::state::pool()?, page, page_size).await?)
}
