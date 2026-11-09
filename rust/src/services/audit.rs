//! 审计日志的业务规则：校验输入、限制分页，再调用 data 层。

use crate::data::audit::{self, AuditRow, ListParams, SortKey};
use crate::errors::KeelError;
use sqlx::SqlitePool;
use std::time::{SystemTime, UNIX_EPOCH};

/// 单页最多多少条。
pub const MAX_PAGE_SIZE: u32 = 200;

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

/// 便捷入口：单列排序。
pub async fn list(
    pool: &SqlitePool,
    keyword: String,
    sort_by: String,
    descending: bool,
    page: u32,
    page_size: u32,
) -> Result<(Vec<AuditRow>, i64), KeelError> {
    list_filtered(
        pool,
        &ListParams {
            keyword,
            start_at_ms: None,
            end_at_ms_exclusive: None,
            sort: vec![SortKey {
                field: sort_by,
                descending,
            }],
            page,
            page_size,
        },
    )
    .await
}

/// 列表与导出共用半开时间范围校验；不转换时区，也不对 i64 边界做算术。
pub fn validate_date_range(start: Option<i64>, end: Option<i64>) -> Result<(), KeelError> {
    if let (Some(start), Some(end)) = (start, end) {
        if start >= end {
            return Err(KeelError::Validation("审计开始时间必须早于结束时间".into()));
        }
    }
    Ok(())
}

pub async fn list_filtered(
    pool: &SqlitePool,
    params: &ListParams,
) -> Result<(Vec<AuditRow>, i64), KeelError> {
    validate_date_range(params.start_at_ms, params.end_at_ms_exclusive)?;
    audit::validate_sort(&params.sort)?;
    if params.page == 0 {
        return Err(KeelError::Validation("page 从 1 开始".into()));
    }
    if params.page_size == 0 || params.page_size > MAX_PAGE_SIZE {
        return Err(KeelError::Validation(format!(
            "page_size 需在 1 到 {MAX_PAGE_SIZE} 之间"
        )));
    }
    audit::list(pool, params).await
}

/// 记录一次操作，操作者是当前用户；还没有当前用户时记为 `local`。
pub async fn record(
    pool: &SqlitePool,
    action: &str,
    target: &str,
    result: &str,
) -> Result<(), KeelError> {
    let actor = crate::services::access::current_name();
    record_as(pool, &actor, action, target, result).await
}

/// 以明确的身份记录一次操作，避免身份切换等并发操作在写审计时读取到新用户。
pub async fn record_as(
    pool: &SqlitePool,
    actor: &str,
    action: &str,
    target: &str,
    result: &str,
) -> Result<(), KeelError> {
    audit::insert(pool, now_ms(), actor, action, target, result, "").await
}
