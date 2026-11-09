//! 往来单位（参考实体）的跨语言入口。列表不分角色，维护需要 `customers.manage`。

use crate::api::error::ApiError;
use crate::data::customer::CustomerListParams;
use crate::services::customer;
use crate::state;

pub struct CustomerSort {
    /// "code" | "name" | "kind" | "updated_at"
    pub field: String,
    pub descending: bool,
}

pub struct CustomerQuery {
    /// 在编号 / 名称 / 电话 / 邮箱里模糊匹配；空串表示不过滤。
    pub keyword: String,
    /// customer / supplier / both；None 表示不限。
    pub kind: Option<String>,
    /// None 表示不限。
    pub active: Option<bool>,
    /// 依次生效；最多 2 列且字段不重复。空表示按编号升序。
    pub sort: Vec<CustomerSort>,
    /// 从 1 开始
    pub page: u32,
    /// 1 到 200
    pub page_size: u32,
}

pub struct CustomerItem {
    pub id: i64,
    pub code: String,
    pub name: String,
    /// customer / supplier / both
    pub kind: String,
    pub phone: String,
    pub email: String,
    pub active: bool,
    pub note: String,
    /// UTC epoch 毫秒
    pub updated_at: i64,
    pub updated_by: String,
}

pub struct CustomerPage {
    pub items: Vec<CustomerItem>,
    /// 满足条件的总条数（不只当前页）
    pub total: i64,
}

pub struct SaveCustomerRequest {
    pub code: String,
    pub name: String,
    /// customer / supplier / both
    pub kind: String,
    pub phone: String,
    pub email: String,
    pub active: bool,
    pub note: String,
}

impl From<customer::CustomerInput> for SaveCustomerRequest {
    fn from(value: customer::CustomerInput) -> Self {
        Self {
            code: value.code,
            name: value.name,
            kind: value.kind,
            phone: value.phone,
            email: value.email,
            active: value.active,
            note: value.note,
        }
    }
}

fn input(request: SaveCustomerRequest) -> customer::CustomerInput {
    customer::CustomerInput {
        code: request.code,
        name: request.name,
        kind: request.kind,
        phone: request.phone,
        email: request.email,
        active: request.active,
        note: request.note,
    }
}

/// 读取不分角色：这是本地参考数据，界面按角色只控制“能不能改”。
pub async fn list_customers(query: CustomerQuery) -> Result<CustomerPage, ApiError> {
    let params = CustomerListParams {
        keyword: query.keyword,
        kind: query.kind,
        active: query.active,
        sort: query
            .sort
            .into_iter()
            .map(|key| crate::data::customer::CustomerSortKey {
                field: key.field,
                descending: key.descending,
            })
            .collect(),
        page: query.page,
        page_size: query.page_size,
    };
    let (rows, total) = customer::list(state::pool()?, &params).await?;
    Ok(CustomerPage {
        items: rows
            .into_iter()
            .map(|row| CustomerItem {
                id: row.id,
                code: row.code,
                name: row.name,
                kind: row.kind,
                phone: row.phone,
                email: row.email,
                active: row.active,
                note: row.note,
                updated_at: row.updated_at,
                updated_by: row.updated_by,
            })
            .collect(),
        total,
    })
}

/// 新建；需要 `customers.manage`。编号重复返回 `KEEL-DUPLICATE`。
pub async fn create_customer(request: SaveCustomerRequest) -> Result<i64, ApiError> {
    Ok(customer::create(state::pool()?, input(request)).await?)
}

/// 更新；记录不存在返回 `KEEL-NOT-FOUND`。
pub async fn update_customer(id: i64, request: SaveCustomerRequest) -> Result<(), ApiError> {
    Ok(customer::update(state::pool()?, id, input(request)).await?)
}

/// 批量删除；需要 `customers.manage`。任一记录不存在则整批回滚（`KEEL-NOT-FOUND`）。
pub async fn delete_customers(ids: Vec<i64>) -> Result<u32, ApiError> {
    Ok(customer::delete_many(state::pool()?, &ids).await?)
}

/// 批量启用/停用；同样的“全有或全无”事务语义。
pub async fn set_customers_active(ids: Vec<i64>, active: bool) -> Result<u32, ApiError> {
    Ok(customer::set_active_many(state::pool()?, &ids, active).await?)
}
