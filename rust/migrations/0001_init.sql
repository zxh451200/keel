-- 审计日志：重要写入和用户操作的记录。时间是 UTC epoch 毫秒。
-- correlation_id 把一条记录和日志、诊断里的同一次操作关联起来。
CREATE TABLE audit_log (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    at             INTEGER NOT NULL,
    actor          TEXT    NOT NULL,
    action         TEXT    NOT NULL,
    target         TEXT    NOT NULL DEFAULT '',
    result         TEXT    NOT NULL,
    correlation_id TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX idx_audit_log_at ON audit_log (at);
