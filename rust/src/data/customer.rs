//! 往来单位（参考实体）的读写。SQL 只在这里；排序列走白名单。

use crate::errors::KeelError;
use sqlx::{SqliteConnection, SqlitePool};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct CustomerRow {
    pub id: i64,
    pub code: String,
    pub name: String,
    pub kind: String,
    pub phone: String,
    pub email: String,
    pub active: bool,
    pub note: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub updated_by: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustomerSortKey {
    /// "code" | "name" | "kind" | "updated_at"
    pub field: String,
    pub descending: bool,
}

pub struct CustomerListParams {
    /// 在 code / name / phone / email 里模糊匹配；空串表示不过滤。
    pub keyword: String,
    /// customer / supplier / both；None 表示不限。
    pub kind: Option<String>,
    /// None 表示不限。
    pub active: Option<bool>,
    pub sort: Vec<CustomerSortKey>,
    /// 从 1 开始
    pub page: u32,
    pub page_size: u32,
}

pub const MAX_SORT_KEYS: usize = 2;

pub fn validate_sort(sort: &[CustomerSortKey]) -> Result<(), KeelError> {
    if sort.len() > MAX_SORT_KEYS {
        return Err(KeelError::Validation(format!(
            "排序最多 {MAX_SORT_KEYS} 列"
        )));
    }
    let mut seen = std::collections::HashSet::new();
    for key in sort {
        if !matches!(key.field.as_str(), "code" | "name" | "kind" | "updated_at") {
            return Err(KeelError::Validation(
                "排序字段需为 code / name / kind / updated_at".into(),
            ));
        }
        if !seen.insert(key.field.as_str()) {
            return Err(KeelError::Validation("排序字段不能重复".into()));
        }
    }
    Ok(())
}

/// 由已验证的排序键拼 ORDER BY；列名只来自白名单，末尾用 id 补稳定次序。
pub fn order_clause(sort: &[CustomerSortKey]) -> Result<String, KeelError> {
    validate_sort(sort)?;
    if sort.is_empty() {
        return Ok("ORDER BY code ASC, id ASC".into());
    }
    let mut parts = Vec::with_capacity(sort.len() + 1);
    for key in sort {
        let column = match key.field.as_str() {
            "code" => "code",
            "name" => "name",
            "kind" => "kind",
            "updated_at" => "updated_at",
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

/// LIKE 通配符按字面匹配（与审计列表同一规则）。
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

const SELECT: &str = "SELECT id, code, name, kind, phone, email, active, note, \
                      created_at, updated_at, updated_by FROM customer";

const MATCH: &str = "(?1 = '' OR code LIKE ?2 ESCAPE '\\' OR name LIKE ?2 ESCAPE '\\' \
                     OR phone LIKE ?2 ESCAPE '\\' OR email LIKE ?2 ESCAPE '\\') \
                     AND (?3 IS NULL OR kind = ?3) AND (?4 IS NULL OR active = ?4)";

// sqlx 0.9 的 query*() 只默认接受 &'static str，这里两条都是常量文本。
const COUNT_SQL: &str = "SELECT COUNT(*) FROM customer WHERE (?1 = '' OR code LIKE ?2 ESCAPE '\\' \
     OR name LIKE ?2 ESCAPE '\\' OR phone LIKE ?2 ESCAPE '\\' OR email LIKE ?2 ESCAPE '\\') \
     AND (?3 IS NULL OR kind = ?3) AND (?4 IS NULL OR active = ?4)";

pub async fn list(
    pool: &SqlitePool,
    params: &CustomerListParams,
) -> Result<(Vec<CustomerRow>, i64), KeelError> {
    let (total,): (i64,) = sqlx::query_as(COUNT_SQL)
        .bind(&params.keyword)
        .bind(like_pattern(&params.keyword))
        .bind(&params.kind)
        .bind(params.active)
        .fetch_one(pool)
        .await?;
    let order = order_clause(&params.sort)?;
    let offset = i64::from(params.page.saturating_sub(1)) * i64::from(params.page_size);
    // ORDER BY 无法参数化；order_clause 只输出白名单列名，不含用户输入。
    let sql = format!("{SELECT} WHERE {MATCH} {order} LIMIT ?5 OFFSET ?6");
    let rows = sqlx::query_as::<_, CustomerRow>(sqlx::AssertSqlSafe(sql))
        .bind(&params.keyword)
        .bind(like_pattern(&params.keyword))
        .bind(&params.kind)
        .bind(params.active)
        .bind(i64::from(params.page_size))
        .bind(offset)
        .fetch_all(pool)
        .await?;
    Ok((rows, total))
}

pub async fn find(pool: &SqlitePool, id: i64) -> Result<Option<CustomerRow>, KeelError> {
    let mut connection = pool.acquire().await?;
    find_conn(&mut connection, id).await
}

/// 在已有连接/事务上按 id 读取，供服务层在写事务内复查。
pub async fn find_conn(
    connection: &mut SqliteConnection,
    id: i64,
) -> Result<Option<CustomerRow>, KeelError> {
    let sql = format!("{SELECT} WHERE id = ?1");
    let row = sqlx::query_as::<_, CustomerRow>(sqlx::AssertSqlSafe(sql))
        .bind(id)
        .fetch_optional(&mut *connection)
        .await?;
    Ok(row)
}

pub async fn find_by_code(pool: &SqlitePool, code: &str) -> Result<Option<CustomerRow>, KeelError> {
    let sql = format!("{SELECT} WHERE code = ?1");
    let row = sqlx::query_as::<_, CustomerRow>(sqlx::AssertSqlSafe(sql))
        .bind(code)
        .fetch_optional(pool)
        .await?;
    Ok(row)
}

/// 新建。code 重复时由唯一约束转换成 `KEEL-DUPLICATE`。
pub async fn insert_conn(
    connection: &mut SqliteConnection,
    row: &CustomerRow,
) -> Result<i64, KeelError> {
    let result = sqlx::query(
        "INSERT INTO customer \
         (code, name, kind, phone, email, active, note, created_at, updated_at, updated_by) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
    )
    .bind(&row.code)
    .bind(&row.name)
    .bind(&row.kind)
    .bind(&row.phone)
    .bind(&row.email)
    .bind(row.active)
    .bind(&row.note)
    .bind(row.created_at)
    .bind(row.updated_at)
    .bind(&row.updated_by)
    .execute(&mut *connection)
    .await?;
    Ok(result.last_insert_rowid())
}

/// 按 id 更新；返回受影响行数，0 表示记录不存在。
pub async fn update_conn(
    connection: &mut SqliteConnection,
    id: i64,
    row: &CustomerRow,
) -> Result<u64, KeelError> {
    let result = sqlx::query(
        "UPDATE customer SET code = ?2, name = ?3, kind = ?4, phone = ?5, email = ?6, \
         active = ?7, note = ?8, updated_at = ?9, updated_by = ?10 WHERE id = ?1",
    )
    .bind(id)
    .bind(&row.code)
    .bind(&row.name)
    .bind(&row.kind)
    .bind(&row.phone)
    .bind(&row.email)
    .bind(row.active)
    .bind(&row.note)
    .bind(row.updated_at)
    .bind(&row.updated_by)
    .execute(&mut *connection)
    .await?;
    Ok(result.rows_affected())
}

/// 删除单条；返回受影响行数。
pub async fn delete_conn(connection: &mut SqliteConnection, id: i64) -> Result<u64, KeelError> {
    let result = sqlx::query("DELETE FROM customer WHERE id = ?1")
        .bind(id)
        .execute(&mut *connection)
        .await?;
    Ok(result.rows_affected())
}
