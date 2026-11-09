-- 参考实体：往来单位（客户/供应商）。
-- 这是二开示例，不是 Keel 底座自带的业务范围；审计日志仍是底座的首选示例列表。
-- 金额、库存等业务字段不属于本示例，需要时在自己的业务模块里另建表。
CREATE TABLE customer (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    code       TEXT    NOT NULL UNIQUE,
    name       TEXT    NOT NULL,
    kind       TEXT    NOT NULL CHECK (kind IN ('customer', 'supplier', 'both')),
    phone      TEXT    NOT NULL DEFAULT '',
    email      TEXT    NOT NULL DEFAULT '',
    active     INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    note       TEXT    NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    updated_by TEXT    NOT NULL
);

CREATE INDEX customer_name_idx ON customer (name);
CREATE INDEX customer_kind_idx ON customer (kind);
