//! 审计日志的读写。SQL 都在这里，参数一律绑定；排序列走白名单。

use crate::errors::KeelError;
use sqlx::{SqliteConnection, SqlitePool};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct AuditRow {
    pub id: i64,
    pub at: i64,
    pub actor: String,
    pub action: String,
    pub target: String,
    pub result: String,
    pub correlation_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SortKey {
    /// "at" | "actor" | "action"
    pub field: String,
    pub descending: bool,
}

pub struct ListParams {
    /// 在 actor / action / target 里模糊匹配；空串表示不过滤。
    pub keyword: String,
    /// UTC epoch 毫秒，包含此时间点；None 表示无下界。
    pub start_at_ms: Option<i64>,
    /// UTC epoch 毫秒，不包含此时间点；None 表示无上界。
    pub end_at_ms_exclusive: Option<i64>,
    /// 依次生效的排序键；空表示默认 `at DESC`。最多 3 个且字段不重复。
    pub sort: Vec<SortKey>,
    /// 从 1 开始
    pub page: u32,
    pub page_size: u32,
}

/// 排序键数量上限；与检查顺序保持一致。
pub const MAX_SORT_KEYS: usize = 3;

/// 校验排序键：白名单、最多 3 个、字段不重复。
/// 返回的错误信息不回显输入内容。
pub fn validate_sort(sort: &[SortKey]) -> Result<(), KeelError> {
    if sort.len() > MAX_SORT_KEYS {
        return Err(KeelError::Validation(format!(
            "排序最多 {MAX_SORT_KEYS} 列"
        )));
    }
    let mut seen = std::collections::HashSet::new();
    for key in sort {
        if !matches!(key.field.as_str(), "at" | "actor" | "action") {
            return Err(KeelError::Validation(
                "排序字段需为 at / actor / action".into(),
            ));
        }
        if !seen.insert(key.field.as_str()) {
            return Err(KeelError::Validation("排序字段不能重复".into()));
        }
    }
    Ok(())
}

/// 由已验证的排序键拼出 ORDER BY；列名只来自固定白名单。
/// 末尾用 id 补稳定次序，方向取最后一列。
pub fn order_clause(sort: &[SortKey]) -> Result<String, KeelError> {
    validate_sort(sort)?;
    if sort.is_empty() {
        return Ok("ORDER BY at DESC, id DESC".into());
    }
    let mut parts = Vec::with_capacity(sort.len() + 1);
    for key in sort {
        let column = match key.field.as_str() {
            "at" => "at",
            "actor" => "actor",
            "action" => "action",
            _ => unreachable!("validate_sort 已限制字段"),
        };
        parts.push(format!(
            "{column} {}",
            if key.descending { "DESC" } else { "ASC" }
        ));
    }
    let tie = if sort.last().is_some_and(|key| key.descending) {
        "DESC"
    } else {
        "ASC"
    };
    parts.push(format!("id {tie}"));
    Ok(format!("ORDER BY {}", parts.join(", ")))
}

/// 把用户输入里的 LIKE 通配符转义，让 `%` 和 `_` 按字面匹配。
pub fn like_pattern(keyword: &str) -> String {
    let mut out = String::with_capacity(keyword.len() + 2);
    out.push('%');
    for c in keyword.chars() {
        if matches!(c, '\\' | '%' | '_') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('%');
    out
}

const FILTER: &str = "(?1 = '' OR actor LIKE ?2 ESCAPE '\\' \
                      OR action LIKE ?2 ESCAPE '\\' OR target LIKE ?2 ESCAPE '\\') \
                      AND (?3 IS NULL OR at >= ?3) AND (?4 IS NULL OR at < ?4)";

/// sqlx 0.9 的 query*() 只默认接受 `&'static str`；FILTER 是常量文本，直接内联成完整字面量
/// （concat! 不接受 const 标识符，故与 FILTER 各存一份，改动时需同步）。
const COUNT_BYTES_SQL: &str = "SELECT COUNT(*), COALESCE(SUM(\
     length(CAST(actor AS BLOB)) + length(CAST(action AS BLOB)) + \
     length(CAST(target AS BLOB)) + length(CAST(result AS BLOB))), 0) \
     FROM audit_log WHERE (?1 = '' OR actor LIKE ?2 ESCAPE '\\' \
     OR action LIKE ?2 ESCAPE '\\' OR target LIKE ?2 ESCAPE '\\') \
     AND (?3 IS NULL OR at >= ?3) AND (?4 IS NULL OR at < ?4)";
const COUNT_SQL: &str =
    "SELECT COUNT(*) FROM audit_log WHERE (?1 = '' OR actor LIKE ?2 ESCAPE '\\' \
     OR action LIKE ?2 ESCAPE '\\' OR target LIKE ?2 ESCAPE '\\') \
     AND (?3 IS NULL OR at >= ?3) AND (?4 IS NULL OR at < ?4)";

/// 导出持有一个只读事务，COUNT、体积预检与所有批次共享同一 SQLite 快照。
pub struct ExportSnapshot {
    transaction: sqlx::Transaction<'static, sqlx::Sqlite>,
    params: ListParams,
    pub total: i64,
    pub raw_bytes: i64,
    offset: i64,
}

impl ExportSnapshot {
    pub async fn begin(pool: &SqlitePool, params: ListParams) -> Result<Self, KeelError> {
        let mut transaction = pool.begin().await?;
        // 原始 UTF-8 总字节预检，避免把单个超大字段或整批巨量内容读进 Rust。
        let (total, raw_bytes): (i64, i64) = sqlx::query_as(COUNT_BYTES_SQL)
            .bind(&params.keyword)
            .bind(like_pattern(&params.keyword))
            .bind(params.start_at_ms)
            .bind(params.end_at_ms_exclusive)
            .fetch_one(transaction.as_mut())
            .await?;
        Ok(Self {
            transaction,
            params,
            total,
            raw_bytes,
            offset: 0,
        })
    }

    pub async fn next_batch(&mut self) -> Result<Vec<AuditRow>, KeelError> {
        let order = order_clause(&self.params.sort)?;
        // ORDER BY 无法参数化；order_clause 只输出白名单列名（audit.rs 内 validate_sort 限定），
        // 不含用户输入，因此用 AssertSqlSafe 显式声明这条动态拼接语句是安全的。
        let sql = format!(
            "SELECT id, at, actor, action, target, result, '' AS correlation_id FROM audit_log \
             WHERE {FILTER} {order} LIMIT 200 OFFSET ?5"
        );
        let rows = sqlx::query_as::<_, AuditRow>(sqlx::AssertSqlSafe(sql))
            .bind(&self.params.keyword)
            .bind(like_pattern(&self.params.keyword))
            .bind(self.params.start_at_ms)
            .bind(self.params.end_at_ms_exclusive)
            .bind(self.offset)
            .fetch_all(self.transaction.as_mut())
            .await?;
        self.offset += rows.len() as i64;
        Ok(rows)
    }

    /// 显式释放只读事务；丢弃时的延迟后台回滚可能与连接复用竞态。
    pub(crate) async fn release(self) -> Result<(), sqlx::Error> {
        self.transaction.rollback().await
    }
}

/// 返回当前页的记录和满足条件的总数。
pub async fn list(
    pool: &SqlitePool,
    params: &ListParams,
) -> Result<(Vec<AuditRow>, i64), KeelError> {
    // 排序列只能取白名单里的固定文本，绝不把界面传来的字符串拼进 SQL。
    let order = order_clause(&params.sort)?;
    let pattern = like_pattern(&params.keyword);
    let offset = i64::from(params.page.saturating_sub(1)) * i64::from(params.page_size);

    let total: i64 = sqlx::query_scalar(COUNT_SQL)
        .bind(&params.keyword)
        .bind(&pattern)
        .bind(params.start_at_ms)
        .bind(params.end_at_ms_exclusive)
        .fetch_one(pool)
        .await?;

    let sql = format!(
        "SELECT id, at, actor, action, target, result, correlation_id FROM audit_log \
         WHERE {FILTER} {order} LIMIT ?5 OFFSET ?6"
    );
    // 同 next_batch：order_clause 只拼白名单列名，AssertSqlSafe 声明安全。
    let rows = sqlx::query_as::<_, AuditRow>(sqlx::AssertSqlSafe(sql))
        .bind(&params.keyword)
        .bind(&pattern)
        .bind(params.start_at_ms)
        .bind(params.end_at_ms_exclusive)
        .bind(i64::from(params.page_size))
        .bind(offset)
        .fetch_all(pool)
        .await?;
    Ok((rows, total))
}

pub async fn insert(
    pool: &SqlitePool,
    at: i64,
    actor: &str,
    action: &str,
    target: &str,
    result: &str,
    correlation_id: &str,
) -> Result<(), KeelError> {
    let mut connection = pool.acquire().await?;
    insert_conn(
        &mut connection,
        at,
        actor,
        action,
        target,
        result,
        correlation_id,
    )
    .await
}

/// 单条参数化语句幂等重放设置事件；不需要额外迁移或先查再写。
/// 应用 settings 服务串行调用；事件时间/操作者取自首次配置提交。
pub async fn insert_settings_change(
    pool: &SqlitePool,
    at: i64,
    actor: &str,
    result: &str,
    event_id: &str,
) -> Result<(), KeelError> {
    sqlx::query(
        "INSERT INTO audit_log (at, actor, action, target, result, correlation_id) \
         SELECT ?1, ?2, 'settings.change', 'application', ?3, ?4 \
         WHERE NOT EXISTS (SELECT 1 FROM audit_log \
         WHERE action = 'settings.change' AND correlation_id = ?4)",
    )
    .bind(at)
    .bind(actor)
    .bind(result)
    .bind(event_id)
    .execute(pool)
    .await?;
    // 混合 outbox 只有所有事件确认入库才能清理；IGNORE 或冲突记录均保留队列。
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM audit_log WHERE action = 'settings.change' \
         AND correlation_id = ?1 AND at = ?2 AND actor = ?3 \
         AND target = 'application' AND result = ?4)",
    )
    .bind(event_id)
    .bind(at)
    .bind(actor)
    .bind(result)
    .fetch_one(pool)
    .await?;
    if !exists {
        return Err(KeelError::internal("配置变更审计未确认写入"));
    }
    Ok(())
}

/// 与 change 使用相同的单语句幂等重放；动作独立，不能写成 settings.change。
pub async fn insert_settings_import(
    pool: &SqlitePool,
    at: i64,
    actor: &str,
    result: &str,
    event_id: &str,
) -> Result<(), KeelError> {
    sqlx::query(
        "INSERT INTO audit_log (at, actor, action, target, result, correlation_id) \
         SELECT ?1, ?2, 'settings.import', 'application', ?3, ?4 \
         WHERE NOT EXISTS (SELECT 1 FROM audit_log \
         WHERE action = 'settings.import' AND correlation_id = ?4)",
    )
    .bind(at)
    .bind(actor)
    .bind(result)
    .bind(event_id)
    .execute(pool)
    .await?;
    // RAISE(IGNORE) 可能返回成功但没有插入；不得因此清掉 outbox。
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM audit_log WHERE action = 'settings.import' \
         AND correlation_id = ?1 AND at = ?2 AND actor = ?3 \
         AND target = 'application' AND result = ?4)",
    )
    .bind(event_id)
    .bind(at)
    .bind(actor)
    .bind(result)
    .fetch_one(pool)
    .await?;
    if !exists {
        return Err(KeelError::internal("配置导入审计未确认写入"));
    }
    Ok(())
}

/// 在已有连接上写入审计，供事务和连接池包装复用。
pub async fn insert_conn(
    connection: &mut SqliteConnection,
    at: i64,
    actor: &str,
    action: &str,
    target: &str,
    result: &str,
    correlation_id: &str,
) -> Result<(), KeelError> {
    sqlx::query(
        "INSERT INTO audit_log (at, actor, action, target, result, correlation_id) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .bind(at)
    .bind(actor)
    .bind(action)
    .bind(target)
    .bind(result)
    .bind(correlation_id)
    .execute(&mut *connection)
    .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn like_pattern_escapes_wildcards() {
        assert_eq!(like_pattern("abc"), "%abc%");
        assert_eq!(like_pattern("50%_off"), "%50\\%\\_off%");
        assert_eq!(like_pattern("a\\b"), "%a\\\\b%");
    }

    fn key(field: &str, descending: bool) -> SortKey {
        SortKey {
            field: field.into(),
            descending,
        }
    }

    #[test]
    fn order_clause_joins_keys_in_order_with_id_tiebreak() {
        assert_eq!(
            order_clause(&[key("actor", false), key("at", true)]).unwrap(),
            "ORDER BY actor ASC, at DESC, id DESC"
        );
        assert_eq!(
            order_clause(&[key("at", true), key("action", false)]).unwrap(),
            "ORDER BY at DESC, action ASC, id ASC"
        );
        assert_eq!(order_clause(&[]).unwrap(), "ORDER BY at DESC, id DESC");
    }

    #[test]
    fn order_clause_rejects_unknown_duplicate_and_too_many_keys() {
        for sort in [
            vec![key("target", true)],
            vec![key("at", true), key("at", false)],
            vec![
                key("at", true),
                key("actor", true),
                key("action", true),
                key("at", false),
            ],
            vec![key("at; DROP TABLE audit_log", true)],
        ] {
            assert!(matches!(order_clause(&sort), Err(KeelError::Validation(_))));
        }
    }
}
