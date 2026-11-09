-- 本地用户。角色取值见 src/domain/permissions.rs（admin / operator / viewer）。
-- 这是应用内的权限，不是对本机管理员的安全隔离（AGENTS.md §11）。
CREATE TABLE app_user (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL UNIQUE,
    role       TEXT    NOT NULL CHECK (role IN ('admin', 'operator', 'viewer')),
    created_at INTEGER NOT NULL
);
