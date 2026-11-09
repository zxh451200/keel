//! 往来单位（参考实体）的业务规则：校验、权限与审计在同一事务。
//! 这是二开示例：不写审计日志之外的业务表，也不把客户模型塞进底座公共 DTO。

use crate::data::audit as audit_data;
use crate::data::customer::{self, CustomerListParams, CustomerRow};
use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::access;
use crate::services::audit::now_ms;
use sqlx::SqlitePool;

pub const MAX_PAGE_SIZE: u32 = 200;
pub const MAX_BATCH: usize = 200;
pub const MAX_CODE_CHARS: usize = 32;
pub const MAX_NAME_CHARS: usize = 80;
pub const MAX_PHONE_CHARS: usize = 32;
pub const MAX_EMAIL_CHARS: usize = 128;
pub const MAX_NOTE_CHARS: usize = 500;
pub const KINDS: [&str; 3] = ["customer", "supplier", "both"];

#[derive(Debug, Clone)]
pub struct CustomerInput {
    pub code: String,
    pub name: String,
    pub kind: String,
    pub phone: String,
    pub email: String,
    pub active: bool,
    pub note: String,
}

fn validate_code(raw: &str) -> Result<String, KeelError> {
    let code = raw.trim().to_ascii_uppercase();
    if code.is_empty() || code.chars().count() > MAX_CODE_CHARS {
        return Err(KeelError::Validation(format!(
            "编号需为 1 到 {MAX_CODE_CHARS} 个字符"
        )));
    }
    if !code
        .chars()
        .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_' || c == '-')
    {
        return Err(KeelError::Validation(
            "编号只能包含字母、数字、下划线和短横线".into(),
        ));
    }
    Ok(code)
}

fn validate_name(raw: &str) -> Result<String, KeelError> {
    let name = raw.trim();
    let count = name.chars().count();
    if count == 0 || count > MAX_NAME_CHARS {
        return Err(KeelError::Validation(format!(
            "名称需为 1 到 {MAX_NAME_CHARS} 个字符"
        )));
    }
    if name.chars().any(char::is_control) {
        return Err(KeelError::Validation("名称不能包含控制字符".into()));
    }
    Ok(name.to_string())
}

fn validate_kind(raw: &str) -> Result<String, KeelError> {
    let kind = raw.trim().to_ascii_lowercase();
    if !KINDS.contains(&kind.as_str()) {
        return Err(KeelError::Validation(
            "类型需为 customer / supplier / both".into(),
        ));
    }
    Ok(kind)
}

fn validate_phone(raw: &str) -> Result<String, KeelError> {
    let phone = raw.trim();
    if phone.chars().count() > MAX_PHONE_CHARS {
        return Err(KeelError::Validation(format!(
            "联系电话最多 {MAX_PHONE_CHARS} 个字符"
        )));
    }
    if !phone
        .chars()
        .all(|c| c.is_ascii_digit() || matches!(c, ' ' | '+' | '-' | '(' | ')'))
    {
        return Err(KeelError::Validation(
            "联系电话只能包含数字、空格、+、- 和括号".into(),
        ));
    }
    Ok(phone.to_string())
}

fn validate_email(raw: &str) -> Result<String, KeelError> {
    let email = raw.trim();
    if email.chars().count() > MAX_EMAIL_CHARS {
        return Err(KeelError::Validation(format!(
            "邮箱最多 {MAX_EMAIL_CHARS} 个字符"
        )));
    }
    if email.is_empty() {
        return Ok(String::new());
    }
    if email.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(KeelError::Validation("邮箱不能包含空白或控制字符".into()));
    }
    let mut parts = email.split('@');
    let (Some(local), Some(domain), None) = (parts.next(), parts.next(), parts.next()) else {
        return Err(KeelError::Validation("邮箱需包含一个 @".into()));
    };
    if local.is_empty()
        || domain.is_empty()
        || !domain.contains('.')
        || domain.starts_with('.')
        || domain.ends_with('.')
    {
        return Err(KeelError::Validation("邮箱格式不正确".into()));
    }
    Ok(email.to_string())
}

fn validate_note(raw: &str) -> Result<String, KeelError> {
    let note = raw.trim();
    if note.chars().count() > MAX_NOTE_CHARS {
        return Err(KeelError::Validation(format!(
            "备注最多 {MAX_NOTE_CHARS} 个字符"
        )));
    }
    if note.chars().any(|c| c.is_control() && c != '\n') {
        return Err(KeelError::Validation(
            "备注只能换行，不能包含其他控制字符".into(),
        ));
    }
    Ok(note.to_string())
}

/// 返回规范化后的输入；错误信息不回显原始值。
pub fn validate(input: &CustomerInput) -> Result<CustomerInput, KeelError> {
    Ok(CustomerInput {
        code: validate_code(&input.code)?,
        name: validate_name(&input.name)?,
        kind: validate_kind(&input.kind)?,
        phone: validate_phone(&input.phone)?,
        email: validate_email(&input.email)?,
        active: input.active,
        note: validate_note(&input.note)?,
    })
}

pub fn validate_query(params: &CustomerListParams) -> Result<(), KeelError> {
    customer::validate_sort(&params.sort)?;
    if params.page == 0 {
        return Err(KeelError::Validation("page 从 1 开始".into()));
    }
    if params.page_size == 0 || params.page_size > MAX_PAGE_SIZE {
        return Err(KeelError::Validation(format!(
            "page_size 需在 1 到 {MAX_PAGE_SIZE} 之间"
        )));
    }
    if let Some(kind) = &params.kind {
        validate_kind(kind)?;
    }
    Ok(())
}

pub async fn list(
    pool: &SqlitePool,
    params: &CustomerListParams,
) -> Result<(Vec<CustomerRow>, i64), KeelError> {
    validate_query(params)?;
    customer::list(pool, params).await
}

/// 新建；需要 `customers.manage`。编号重复返回 `KEEL-DUPLICATE`，事务整体回滚。
pub async fn create(pool: &SqlitePool, input: CustomerInput) -> Result<i64, KeelError> {
    let _guard = access::lock_identity().await;
    let me = access::require(pool, Permission::CustomerManage).await?;
    let value = validate(&input)?;
    let at = now_ms();
    let row = CustomerRow {
        id: 0,
        code: value.code.clone(),
        name: value.name,
        kind: value.kind,
        phone: value.phone,
        email: value.email,
        active: value.active,
        note: value.note,
        created_at: at,
        updated_at: at,
        updated_by: me.name.clone(),
    };
    let mut transaction = pool.begin().await?;
    let id = customer::insert_conn(transaction.as_mut(), &row).await?;
    audit_data::insert_conn(
        transaction.as_mut(),
        at,
        &me.name,
        "customer.create",
        &row.code,
        "ok",
        "",
    )
    .await?;
    transaction.commit().await?;
    Ok(id)
}

/// 更新；记录不存在返回 `KEEL-NOT-FOUND`，编号撞车返回 `KEEL-DUPLICATE`。
pub async fn update(pool: &SqlitePool, id: i64, input: CustomerInput) -> Result<(), KeelError> {
    let _guard = access::lock_identity().await;
    let me = access::require(pool, Permission::CustomerManage).await?;
    let value = validate(&input)?;
    let at = now_ms();
    let mut transaction = pool.begin().await?;
    let existing = customer::find_conn(transaction.as_mut(), id).await?;
    let Some(existing) = existing else {
        return Err(KeelError::NotFound);
    };
    let row = CustomerRow {
        id,
        code: value.code.clone(),
        name: value.name,
        kind: value.kind,
        phone: value.phone,
        email: value.email,
        active: value.active,
        note: value.note,
        created_at: existing.created_at,
        updated_at: at,
        updated_by: me.name.clone(),
    };
    customer::update_conn(transaction.as_mut(), id, &row).await?;
    audit_data::insert_conn(
        transaction.as_mut(),
        at,
        &me.name,
        "customer.update",
        &row.code,
        "ok",
        "",
    )
    .await?;
    transaction.commit().await?;
    Ok(())
}

fn normalize_ids(ids: &[i64]) -> Result<Vec<i64>, KeelError> {
    if ids.is_empty() {
        return Err(KeelError::Validation("请至少选择一条记录".into()));
    }
    if ids.len() > MAX_BATCH {
        return Err(KeelError::Validation(format!(
            "一次最多处理 {MAX_BATCH} 条记录"
        )));
    }
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(ids.len());
    for &id in ids {
        if id <= 0 {
            return Err(KeelError::Validation("记录 ID 无效".into()));
        }
        if seen.insert(id) {
            out.push(id);
        }
    }
    Ok(out)
}

/// 批量删除：权限只检查一次，全部记录存在才提交；否则整批回滚。
pub async fn delete_many(pool: &SqlitePool, ids: &[i64]) -> Result<u32, KeelError> {
    let _guard = access::lock_identity().await;
    let me = access::require(pool, Permission::CustomerManage).await?;
    let ids = normalize_ids(ids)?;
    let at = now_ms();
    let mut transaction = pool.begin().await?;
    for id in &ids {
        let row = customer::find_conn(transaction.as_mut(), *id)
            .await?
            .ok_or(KeelError::NotFound)?;
        customer::delete_conn(transaction.as_mut(), *id).await?;
        audit_data::insert_conn(
            transaction.as_mut(),
            at,
            &me.name,
            "customer.delete",
            &row.code,
            "ok",
            "",
        )
        .await?;
    }
    transaction.commit().await?;
    Ok(ids.len() as u32)
}

/// 批量启用/停用：与删除相同的“全有或全无”语义，并逐条写审计。
pub async fn set_active_many(
    pool: &SqlitePool,
    ids: &[i64],
    active: bool,
) -> Result<u32, KeelError> {
    let _guard = access::lock_identity().await;
    let me = access::require(pool, Permission::CustomerManage).await?;
    let ids = normalize_ids(ids)?;
    let at = now_ms();
    let action = if active {
        "customer.activate"
    } else {
        "customer.deactivate"
    };
    let mut transaction = pool.begin().await?;
    for id in &ids {
        let existing = customer::find_conn(transaction.as_mut(), *id)
            .await?
            .ok_or(KeelError::NotFound)?;
        let row = CustomerRow {
            id: *id,
            code: existing.code.clone(),
            name: existing.name,
            kind: existing.kind,
            phone: existing.phone,
            email: existing.email,
            active,
            note: existing.note,
            created_at: existing.created_at,
            updated_at: at,
            updated_by: me.name.clone(),
        };
        customer::update_conn(transaction.as_mut(), *id, &row).await?;
        audit_data::insert_conn(
            transaction.as_mut(),
            at,
            &me.name,
            action,
            &row.code,
            "ok",
            "",
        )
        .await?;
    }
    transaction.commit().await?;
    Ok(ids.len() as u32)
}
