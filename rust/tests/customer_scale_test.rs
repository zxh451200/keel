//! 手工规模测试：100 万条往来单位的分页、过滤与排序（真实 SQLite + 服务层）。
//!
//! 默认不随 `cargo test` 执行，避免每次套件都写约 100 MB 临时库：
//! `cargo test --locked --test customer_scale_test -- --ignored --nocapture`
//! 数据由测试夹具直接插入，不写审计；本测试只证明查询/分页在 1M 行下的行为与耗时，
//! 不代表 UI 渲染或平台验收。

use std::time::Instant;

use rust_lib_keel::data;
use rust_lib_keel::data::customer::{CustomerListParams, CustomerSortKey};
use rust_lib_keel::services::customer;

const TOTAL: i64 = 1_000_000;

fn params(page: u32) -> CustomerListParams {
    CustomerListParams {
        keyword: String::new(),
        kind: None,
        active: None,
        sort: Vec::new(),
        page,
        page_size: 50,
    }
}

#[tokio::test]
#[ignore = "manual 1M-row scale run: add --ignored --nocapture"]
async fn one_million_customers_page_filter_and_sort() {
    let dir = std::env::temp_dir().join(format!("keel-customer-scale-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let pool = data::open(&dir.join("main.db")).await.unwrap();

    let started = Instant::now();
    sqlx::query(
        "WITH RECURSIVE seq(x) AS (
             SELECT 1
             UNION ALL
             SELECT x + 1 FROM seq WHERE x < 1000000
         )
         INSERT INTO customer
             (code, name, kind, phone, email, active, note, created_at, updated_at, updated_by)
         SELECT
             'C-' || printf('%07d', x),
             'Name ' || printf('%05d', x % 50000),
             CASE x % 3 WHEN 0 THEN 'customer' WHEN 1 THEN 'supplier' ELSE 'both' END,
             '', '',
             CASE WHEN x % 10 = 0 THEN 0 ELSE 1 END,
             '',
             1762500000000, 1762500000000, 'seed'
         FROM seq",
    )
    .execute(&pool)
    .await
    .unwrap();
    let seeded_in = started.elapsed();

    let first = params(1);
    let started = Instant::now();
    let (rows, total) = customer::list(&pool, &first).await.unwrap();
    let first_page_in = started.elapsed();
    assert_eq!(total, TOTAL);
    assert_eq!(rows.len(), 50);
    assert_eq!(rows.first().unwrap().code, "C-0000001");

    let last = params((TOTAL / 50) as u32);
    let started = Instant::now();
    let (rows, total) = customer::list(&pool, &last).await.unwrap();
    let last_page_in = started.elapsed();
    assert_eq!(total, TOTAL);
    assert_eq!(rows.len(), 50);
    assert_eq!(rows.first().unwrap().code, "C-0999951");

    let started = Instant::now();
    let (rows, total) = customer::list(
        &pool,
        &CustomerListParams {
            keyword: "C-0000001".into(),
            ..params(1)
        },
    )
    .await
    .unwrap();
    let filter_in = started.elapsed();
    assert_eq!(total, 1);
    assert_eq!(rows[0].code, "C-0000001");

    let started = Instant::now();
    let (_, total) = customer::list(
        &pool,
        &CustomerListParams {
            active: Some(true),
            ..params(1)
        },
    )
    .await
    .unwrap();
    let active_count_in = started.elapsed();
    assert_eq!(total, TOTAL / 10 * 9);

    let started = Instant::now();
    let (rows, _) = customer::list(
        &pool,
        &CustomerListParams {
            sort: vec![CustomerSortKey {
                field: "name".into(),
                descending: true,
            }],
            ..params(1)
        },
    )
    .await
    .unwrap();
    let sort_in = started.elapsed();
    assert_eq!(rows.len(), 50);

    eprintln!(
        "[scale] rows={TOTAL} seed={seeded_in:?} first_page={first_page_in:?} \
         last_page={last_page_in:?} keyword={filter_in:?} count_active={active_count_in:?} \
         sort_name_desc={sort_in:?}"
    );

    pool.close().await;
    drop(pool);
    let _ = std::fs::remove_dir_all(&dir);
}
