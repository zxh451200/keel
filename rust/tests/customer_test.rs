//! 往来单位（参考实体）：校验、唯一编号、分页/过滤/排序、权限与审计。
//! 当前用户是进程级状态，所有断言放在同一个测试里顺序执行。

use rust_lib_keel::data;
use rust_lib_keel::data::customer::{CustomerListParams, CustomerSortKey};
use rust_lib_keel::errors::KeelError;
use rust_lib_keel::services::customer::{self, CustomerInput};
use rust_lib_keel::services::{access, audit};

// 当前用户是进程级共享状态；同文件的 tokio 测试并行执行会互相覆盖身份，
// 让权限断言偶发拿到别人的用户。整个文件串行，避免把全局状态当成隔离夹具。
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn serial() -> tokio::sync::MutexGuard<'static, ()> {
    SERIAL.lock().await
}

fn input(code: &str, name: &str) -> CustomerInput {
    CustomerInput {
        code: code.into(),
        name: name.into(),
        kind: "customer".into(),
        phone: String::new(),
        email: String::new(),
        active: true,
        note: String::new(),
    }
}

fn params(keyword: &str) -> CustomerListParams {
    CustomerListParams {
        keyword: keyword.into(),
        kind: None,
        active: None,
        sort: Vec::new(),
        page: 1,
        page_size: 50,
    }
}

async fn audit_rows(pool: &sqlx::SqlitePool, keyword: &str) -> Vec<data::audit::AuditRow> {
    audit::list(pool, keyword.into(), "at".into(), true, 1, 100)
        .await
        .unwrap()
        .0
}

#[tokio::test]
async fn customers_validate_persist_page_and_audit() {
    let _serial = serial().await;
    let dir = std::env::temp_dir().join(format!("keel-customer-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let pool = data::open(&dir.join("main.db")).await.unwrap();
    access::init(&pool).await.unwrap();

    // 新建：编号去空白并统一大写。
    let acme = customer::create(&pool, input(" acme-01 ", "Acme 贸易"))
        .await
        .unwrap();
    customer::create(
        &pool,
        CustomerInput {
            kind: "supplier".into(),
            phone: "+86 21 5555 0101".into(),
            email: "sales@acme.example".into(),
            note: "月结 30 天".into(),
            ..input("SUP-02", "华东供应")
        },
    )
    .await
    .unwrap();
    customer::create(
        &pool,
        CustomerInput {
            kind: "both".into(),
            active: false,
            ..input("BOTH-03", "联合往来")
        },
    )
    .await
    .unwrap();

    let row = data::customer::find(&pool, acme).await.unwrap().unwrap();
    assert_eq!(row.code, "ACME-01");
    assert_eq!(row.name, "Acme 贸易");
    assert_eq!(row.kind, "customer");
    assert!(row.active);
    assert_eq!(row.updated_by, access::DEFAULT_USER);
    assert_eq!(row.created_at, row.updated_at);

    // 唯一编号大小写无关（已规范化），重复被拒绝。
    assert!(matches!(
        customer::create(&pool, input("acme-01", "另一个"))
            .await
            .unwrap_err(),
        KeelError::Duplicate
    ));

    // 校验失败不落库。
    let long_name = "长".repeat(81);
    let long_note = "x".repeat(501);
    for (bad, label) in [
        (input("BAD 1", "含空格编号"), "code"),
        (input("", "空编号"), "code"),
        (input("OK-1", "   "), "name"),
        (input("OK-2", &long_name), "name"),
        (
            CustomerInput {
                kind: "partner".into(),
                ..input("OK-3", "未知类型")
            },
            "kind",
        ),
        (
            CustomerInput {
                phone: "123-abc".into(),
                ..input("OK-4", "电话非法")
            },
            "phone",
        ),
        (
            CustomerInput {
                email: "no-at-sign".into(),
                ..input("OK-5", "邮箱非法")
            },
            "email",
        ),
        (
            CustomerInput {
                email: "user@localhost".into(),
                ..input("OK-6", "邮箱缺域名点")
            },
            "email",
        ),
        (
            CustomerInput {
                note: long_note.clone(),
                ..input("OK-7", "备注过长")
            },
            "note",
        ),
    ] {
        let error = customer::create(&pool, bad).await.unwrap_err();
        assert!(
            matches!(error, KeelError::Validation(_)),
            "{label} should be rejected, got {error:?}"
        );
    }
    assert_eq!(customer::list(&pool, &params("")).await.unwrap().1, 3);

    // 过滤：关键词命中编号或名称（SQLite LIKE 对 ASCII 大小写不敏感）。
    assert_eq!(
        customer::list(&pool, &params("acme-01")).await.unwrap().1,
        1
    );
    assert_eq!(customer::list(&pool, &params("贸易")).await.unwrap().1, 1);
    assert_eq!(customer::list(&pool, &params("acme")).await.unwrap().1, 2);
    assert_eq!(
        customer::list(
            &pool,
            &CustomerListParams {
                kind: Some("supplier".into()),
                ..params("")
            }
        )
        .await
        .unwrap()
        .1,
        1
    );
    assert_eq!(
        customer::list(
            &pool,
            &CustomerListParams {
                active: Some(false),
                ..params("")
            }
        )
        .await
        .unwrap()
        .1,
        1
    );

    // 排序与分页：按名称降序，每页 2 条。
    let (first, total) = customer::list(
        &pool,
        &CustomerListParams {
            sort: vec![CustomerSortKey {
                field: "name".into(),
                descending: true,
            }],
            page_size: 2,
            ..params("")
        },
    )
    .await
    .unwrap();
    assert_eq!(total, 3);
    assert_eq!(
        first.iter().map(|r| r.code.as_str()).collect::<Vec<_>>(),
        // TEXT 排序是 SQLite 的 BINARY 比较（CJK 按码点，不做拼音/本地化排序）。
        ["BOTH-03", "SUP-02"]
    );
    let (second, _) = customer::list(
        &pool,
        &CustomerListParams {
            sort: vec![CustomerSortKey {
                field: "name".into(),
                descending: true,
            }],
            page: 2,
            page_size: 2,
            ..params("")
        },
    )
    .await
    .unwrap();
    assert_eq!(second.len(), 1);
    assert_eq!(second[0].code, "ACME-01");

    // 非法排序/分页被拒绝。
    assert!(matches!(
        customer::list(
            &pool,
            &CustomerListParams {
                sort: vec![CustomerSortKey {
                    field: "phone".into(),
                    descending: true
                }],
                ..params("")
            }
        )
        .await
        .unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        customer::list(
            &pool,
            &CustomerListParams {
                page: 0,
                ..params("")
            }
        )
        .await
        .unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        customer::list(
            &pool,
            &CustomerListParams {
                page_size: 201,
                ..params("")
            }
        )
        .await
        .unwrap_err(),
        KeelError::Validation(_)
    ));

    // 更新：改名并停用；创建时间保持不变。
    customer::update(
        &pool,
        acme,
        CustomerInput {
            name: "Acme 控股".into(),
            active: false,
            email: "ops@acme.example".into(),
            ..input("ACME-01", "Acme 控股")
        },
    )
    .await
    .unwrap();
    let updated = data::customer::find(&pool, acme).await.unwrap().unwrap();
    assert_eq!(updated.name, "Acme 控股");
    assert!(!updated.active);
    assert_eq!(updated.email, "ops@acme.example");
    assert_eq!(updated.created_at, row.created_at);
    assert!(updated.updated_at >= row.updated_at);

    // 更新成已存在的编号：拒绝且原记录不变。
    assert!(matches!(
        customer::update(&pool, acme, input("SUP-02", "撞号"))
            .await
            .unwrap_err(),
        KeelError::Duplicate
    ));
    let unchanged = data::customer::find(&pool, acme).await.unwrap().unwrap();
    assert_eq!(unchanged.code, "ACME-01");
    assert_eq!(unchanged.name, "Acme 控股");

    // 不存在的记录。
    assert!(matches!(
        customer::update(&pool, 9_999, input("NONE", "不存在"))
            .await
            .unwrap_err(),
        KeelError::NotFound
    ));

    // 审计：创建 3 条、更新 1 条；失败的操作不写成功审计。
    let created = audit_rows(&pool, "customer.create").await;
    assert_eq!(created.len(), 3);
    assert!(created.iter().all(|r| r.result == "ok"));
    let updated_audit = audit_rows(&pool, "customer.update").await;
    assert_eq!(updated_audit.len(), 1);
    assert_eq!(updated_audit[0].target, "ACME-01");

    // 批量停用：一次事务内逐条写审计。
    let sup = data::customer::find_by_code(&pool, "SUP-02")
        .await
        .unwrap()
        .unwrap();
    let both = data::customer::find_by_code(&pool, "BOTH-03")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer::set_active_many(&pool, &[sup.id, both.id], false)
            .await
            .unwrap(),
        2
    );
    assert!(
        !data::customer::find(&pool, sup.id)
            .await
            .unwrap()
            .unwrap()
            .active
    );
    assert_eq!(audit_rows(&pool, "customer.deactivate").await.len(), 2);

    // 任一记录不存在：整批回滚，不删除、不写审计。
    let before_delete = customer::list(&pool, &params("")).await.unwrap().1;
    let deletes_before = audit_rows(&pool, "customer.delete").await.len();
    assert!(matches!(
        customer::delete_many(&pool, &[sup.id, 9_999])
            .await
            .unwrap_err(),
        KeelError::NotFound
    ));
    assert_eq!(
        customer::list(&pool, &params("")).await.unwrap().1,
        before_delete
    );
    assert!(data::customer::find(&pool, sup.id).await.unwrap().is_some());
    assert_eq!(
        audit_rows(&pool, "customer.delete").await.len(),
        deletes_before
    );

    // 批量删除；空列表与超过上限被拒绝。
    assert_eq!(customer::delete_many(&pool, &[sup.id]).await.unwrap(), 1);
    assert!(data::customer::find(&pool, sup.id).await.unwrap().is_none());
    assert_eq!(
        audit_rows(&pool, "customer.delete").await.len(),
        deletes_before + 1
    );
    assert!(matches!(
        customer::delete_many(&pool, &[]).await.unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        customer::delete_many(&pool, &vec![both.id; 201])
            .await
            .unwrap_err(),
        KeelError::Validation(_)
    ));

    // 权限：viewer 不能维护，operator 可以；拒绝会留 `permission.denied`。
    access::create_user(&pool, "olive", "operator")
        .await
        .unwrap();
    access::create_user(&pool, "vic", "viewer").await.unwrap();
    access::switch_user(&pool, "vic").await.unwrap();
    assert!(matches!(
        customer::create(&pool, input("VIC-1", "只读")).await.unwrap_err(),
        KeelError::PermissionDenied(what) if what == "customers.manage"
    ));
    assert!(matches!(
        customer::update(&pool, acme, input("ACME-01", "只读改"))
            .await
            .unwrap_err(),
        KeelError::PermissionDenied(_)
    ));
    assert!(matches!(
        customer::delete_many(&pool, &[both.id]).await.unwrap_err(),
        KeelError::PermissionDenied(_)
    ));
    assert!(matches!(
        customer::set_active_many(&pool, &[both.id], true)
            .await
            .unwrap_err(),
        KeelError::PermissionDenied(_)
    ));
    // 读取不分角色（ACME-01 与 BOTH-03 仍在，SUP-02 已删除）。
    assert_eq!(customer::list(&pool, &params("")).await.unwrap().1, 2);
    let denied = audit_rows(&pool, "permission.denied").await;
    assert!(denied.len() >= 2);
    assert_eq!(denied[0].actor, "vic");

    access::switch_user(&pool, "olive").await.unwrap();
    let by_operator = customer::create(&pool, input("OPS-9", "运营创建"))
        .await
        .unwrap();
    let ops = data::customer::find(&pool, by_operator)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(ops.updated_by, "olive");
    let last = audit_rows(&pool, "customer.create").await;
    assert_eq!(last.len(), 4);
    assert_eq!(last[0].actor, "olive");
    assert_eq!(last[0].target, "OPS-9");

    let _ = std::fs::remove_dir_all(&dir);
}

/// 区域粘贴后的一次提交：整批校验、整批事务、逐条审计，任一条失败全部回滚。
#[tokio::test]
async fn customers_update_many_is_atomic_and_audited() {
    let _serial = serial().await;
    let dir = std::env::temp_dir().join(format!("keel-customer-many-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let pool = data::open(&dir.join("main.db")).await.unwrap();
    access::init(&pool).await.unwrap();

    let a = customer::create(&pool, input("A-01", "甲")).await.unwrap();
    let b = customer::create(&pool, input("B-02", "乙")).await.unwrap();
    let c = customer::create(&pool, input("C-03", "丙")).await.unwrap();
    let d = customer::create(&pool, input("D-04", "丁")).await.unwrap();

    let before_a = data::customer::find(&pool, a).await.unwrap().unwrap();
    let before_b = data::customer::find(&pool, b).await.unwrap().unwrap();
    let before_c = data::customer::find(&pool, c).await.unwrap().unwrap();
    assert_eq!(before_a.updated_by, access::DEFAULT_USER);

    // 写入前的拒绝：权限、空列表、超上限、重复 id、非法 id、校验失败。
    access::create_user(&pool, "vic", "viewer").await.unwrap();
    access::create_user(&pool, "olive", "operator")
        .await
        .unwrap();
    access::switch_user(&pool, "vic").await.unwrap();
    assert!(matches!(
        customer::update_many(&pool, &[(a, input("A-01", "只读改"))])
            .await
            .unwrap_err(),
        KeelError::PermissionDenied(what) if what == "customers.manage"
    ));

    access::switch_user(&pool, "olive").await.unwrap();
    assert!(matches!(
        customer::update_many(&pool, &[]).await.unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        customer::update_many(&pool, &vec![(a, input("A-01", "超量")); 201])
            .await
            .unwrap_err(),
        KeelError::Validation(_)
    ));
    // 与批量删除不同：同一个 id 出现两次直接拒绝，不静默去重。
    assert!(matches!(
        customer::update_many(
            &pool,
            &[(a, input("A-01", "甲一")), (a, input("A-01", "甲二"))]
        )
        .await
        .unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        customer::update_many(&pool, &[(0, input("A-01", "坏 id"))])
            .await
            .unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        customer::update_many(&pool, &[(-7, input("A-01", "坏 id"))])
            .await
            .unwrap_err(),
        KeelError::Validation(_)
    ));
    // 一条合法一条非法：整批拒绝且零写入（第一条已通过校验也不能落库）。
    assert!(matches!(
        customer::update_many(
            &pool,
            &[
                (c, input("C-03", "丙先改")),
                (
                    b,
                    CustomerInput {
                        name: "   ".into(),
                        ..input("B-02", "乙")
                    }
                ),
            ]
        )
        .await
        .unwrap_err(),
        KeelError::Validation(_)
    ));
    assert!(matches!(
        customer::update_many(
            &pool,
            &[
                (c, input("C-03", "丙先改")),
                (
                    b,
                    CustomerInput {
                        kind: "partner".into(),
                        ..input("B-02", "乙")
                    }
                ),
            ]
        )
        .await
        .unwrap_err(),
        KeelError::Validation(_)
    ));
    for id in [a, b, c] {
        let row = data::customer::find(&pool, id).await.unwrap().unwrap();
        let before = match id {
            x if x == a => &before_a,
            x if x == b => &before_b,
            _ => &before_c,
        };
        assert_eq!(row.name, before.name);
        assert_eq!(row.updated_at, before.updated_at);
    }
    assert_eq!(audit_rows(&pool, "customer.update").await.len(), 0);

    // 成功批量更新 3 条：字段落库，创建时间保留，更新人与更新时间刷新。
    assert_eq!(
        customer::update_many(
            &pool,
            &[
                (
                    a,
                    CustomerInput {
                        email: "a@acme.example".into(),
                        note: "批量改名".into(),
                        ..input("A-01", "甲控股")
                    }
                ),
                (
                    b,
                    CustomerInput {
                        kind: "supplier".into(),
                        active: false,
                        ..input("B-02", "乙供应")
                    }
                ),
                (c, input("C-03", "丙改")),
            ]
        )
        .await
        .unwrap(),
        3
    );
    let after_a = data::customer::find(&pool, a).await.unwrap().unwrap();
    assert_eq!(after_a.name, "甲控股");
    assert_eq!(after_a.email, "a@acme.example");
    assert_eq!(after_a.note, "批量改名");
    assert_eq!(after_a.created_at, before_a.created_at);
    assert!(after_a.updated_at >= before_a.updated_at);
    assert_eq!(after_a.updated_by, "olive");
    let after_b = data::customer::find(&pool, b).await.unwrap().unwrap();
    assert_eq!(after_b.name, "乙供应");
    assert_eq!(after_b.kind, "supplier");
    assert!(!after_b.active);
    assert_eq!(after_b.updated_by, "olive");
    let after_c = data::customer::find(&pool, c).await.unwrap().unwrap();
    assert_eq!(after_c.name, "丙改");
    assert_eq!(after_c.kind, before_c.kind);
    assert_eq!(after_c.updated_by, "olive");

    // 审计：每条一次 customer.update，操作者为当前用户。
    let audits = audit_rows(&pool, "customer.update").await;
    assert_eq!(audits.len(), 3);
    assert!(audits
        .iter()
        .all(|r| r.result == "ok" && r.actor == "olive"));
    let mut targets: Vec<&str> = audits.iter().map(|r| r.target.as_str()).collect();
    targets.sort_unstable();
    assert_eq!(targets, ["A-01", "B-02", "C-03"]);

    // 一条 id 不存在：整批回滚，其余行保持旧值，不新增审计。
    let audits_before = audit_rows(&pool, "customer.update").await.len();
    assert!(matches!(
        customer::update_many(
            &pool,
            &[
                (b, input("B-02", "乙先改")),
                (9_999, input("NONE", "不存在"))
            ]
        )
        .await
        .unwrap_err(),
        KeelError::NotFound
    ));
    let rolled_back_b = data::customer::find(&pool, b).await.unwrap().unwrap();
    assert_eq!(rolled_back_b.name, "乙供应");
    assert_eq!(rolled_back_b.updated_at, after_b.updated_at);
    assert_eq!(
        audit_rows(&pool, "customer.update").await.len(),
        audits_before
    );

    // 编号撞车（B-02 已被占用）：前面那条已执行的更新也要回滚。
    assert!(matches!(
        customer::update_many(
            &pool,
            &[(c, input("C-03", "丙撞号")), (d, input("B-02", "丁"))]
        )
        .await
        .unwrap_err(),
        KeelError::Duplicate
    ));
    let rolled_back_c = data::customer::find(&pool, c).await.unwrap().unwrap();
    assert_eq!(rolled_back_c.name, after_c.name);
    assert_eq!(rolled_back_c.updated_at, after_c.updated_at);
    let rolled_back_d = data::customer::find(&pool, d).await.unwrap().unwrap();
    assert_eq!(rolled_back_d.code, "D-04");
    assert_eq!(rolled_back_d.name, "丁");
    assert_eq!(rolled_back_d.updated_at, rolled_back_d.created_at);
    assert_eq!(
        audit_rows(&pool, "customer.update").await.len(),
        audits_before
    );

    let _ = std::fs::remove_dir_all(&dir);
}
