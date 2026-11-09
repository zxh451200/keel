//! 审计日志列表：通用的分页 / 排序 / 过滤样例，新增业务列表页可照此仿写。

use crate::api::error::ApiError;
use crate::domain::permissions::Permission;
use crate::{services, state};

/// 一个排序键；按列表顺序依次生效。
pub struct AuditSort {
    /// "at" | "actor" | "action"
    pub field: String,
    pub descending: bool,
}

pub struct AuditQuery {
    /// 在 actor / action / target 里模糊匹配；空串表示不过滤
    pub keyword: String,
    /// UTC epoch 毫秒，包含此时间点；None 表示无下界。
    pub start_at_ms: Option<i64>,
    /// UTC epoch 毫秒，不包含此时间点；None 表示无上界。
    pub end_at_ms_exclusive: Option<i64>,
    /// 依次生效的排序键，最多 3 列且字段不重复；空表示默认 `at DESC`。
    pub sort: Vec<AuditSort>,
    /// 从 1 开始
    pub page: u32,
    /// 1 到 200
    pub page_size: u32,
}

pub struct AuditItem {
    pub id: i64,
    /// UTC epoch 毫秒
    pub at: i64,
    pub actor: String,
    pub action: String,
    pub target: String,
    pub result: String,
}

pub struct AuditPage {
    pub items: Vec<AuditItem>,
    /// 满足条件的总条数（不只当前页）
    pub total: i64,
}

#[derive(Debug, Clone)]
pub struct AuditExportStatus {
    pub task_id: String,
    /// running / completed / cancelled / failed
    pub phase: String,
    pub completed_rows: u32,
    pub total_rows: u32,
    /// 只在 completed 时返回；位置固定为应用数据目录下 exports。
    pub output_path: Option<String>,
    /// 稳定 KEEL 错误码，不包含底层错误或筛选输入。
    pub error_code: Option<String>,
}

/// 忽略 page/page_size，导出全部匹配行；keyword 与排序由服务层校验。
pub async fn start_audit_export(query: AuditQuery) -> Result<AuditExportStatus, ApiError> {
    Ok(services::audit_export::start(state::pool()?, state::db_path()?, query).await?)
}

/// 仅集成测试使用；需要 KEEL_FRB_TEST_TOKEN，且仅在 Debug 构建可用。
#[flutter_rust_bridge::frb(sync)]
pub fn reset_audit_export_registry_for_tests() -> Result<(), ApiError> {
    #[cfg(debug_assertions)]
    if std::env::var("KEEL_FRB_TEST_TOKEN").is_ok_and(|token| !token.is_empty()) {
        services::audit_export::reset_for_tests();
        return Ok(());
    }
    Err(crate::errors::KeelError::PermissionDenied("test-only export registry reset".into()).into())
}

/// Read-only, newest first, only the current complete identity with audit.export.
/// Current process only; terminal handles expire five minutes after completion.
pub async fn list_audit_exports() -> Result<Vec<AuditExportStatus>, ApiError> {
    Ok(services::audit_export::list(state::pool()?).await?)
}

pub async fn audit_export_status(task_id: String) -> Result<AuditExportStatus, ApiError> {
    Ok(services::audit_export::status(state::pool()?, &task_id).await?)
}

pub async fn cancel_audit_export(task_id: String) -> Result<AuditExportStatus, ApiError> {
    Ok(services::audit_export::cancel(state::pool()?, &task_id).await?)
}

/// 将本人已完成且未过期的导出另存副本；目标必须为本地绝对路径，禁止覆盖。
pub async fn save_audit_export_copy(
    task_id: String,
    destination: String,
) -> Result<String, ApiError> {
    Ok(services::audit_export::save_copy(state::pool()?, &task_id, &destination).await?)
}

pub async fn list_audit_logs(query: AuditQuery) -> Result<AuditPage, ApiError> {
    let pool = state::pool()?;
    services::access::require(pool, Permission::AuditRead).await?;
    let (rows, total) = services::audit::list_filtered(
        pool,
        &crate::data::audit::ListParams {
            keyword: query.keyword,
            start_at_ms: query.start_at_ms,
            end_at_ms_exclusive: query.end_at_ms_exclusive,
            sort: query
                .sort
                .into_iter()
                .map(|key| crate::data::audit::SortKey {
                    field: key.field,
                    descending: key.descending,
                })
                .collect(),
            page: query.page,
            page_size: query.page_size,
        },
    )
    .await?;
    let items = rows
        .into_iter()
        .map(|row| AuditItem {
            id: row.id,
            at: row.at,
            actor: row.actor,
            action: row.action,
            target: row.target,
            result: row.result,
        })
        .collect();
    Ok(AuditPage { items, total })
}
