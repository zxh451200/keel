-- Task metadata is separate from append-only audit events.
CREATE TABLE audit_export_history (
    task_id TEXT PRIMARY KEY NOT NULL CHECK(length(task_id) BETWEEN 1 AND 128),
    owner_id INTEGER NOT NULL REFERENCES app_user(id) ON DELETE RESTRICT,
    created_at_ms INTEGER NOT NULL,
    finished_at_ms INTEGER,
    phase TEXT NOT NULL CHECK(phase IN ('running','completed','cancelled','failed','interrupted')),
    completed_rows INTEGER NOT NULL DEFAULT 0 CHECK(completed_rows BETWEEN 0 AND 100000),
    total_rows INTEGER NOT NULL DEFAULT 0 CHECK(total_rows BETWEEN 0 AND 100000),
    result_name TEXT,
    error_code TEXT,
    CHECK(completed_rows <= total_rows),
    CHECK((phase = 'running' AND finished_at_ms IS NULL)
       OR (phase <> 'running' AND finished_at_ms IS NOT NULL)),
    CHECK((phase = 'completed' AND result_name IS NOT NULL
           AND result_name = 'audit-' || task_id || '.csv'
           AND completed_rows = total_rows AND error_code IS NULL)
       OR (phase <> 'completed' AND result_name IS NULL))
);
CREATE INDEX audit_export_history_owner_time
    ON audit_export_history(owner_id, created_at_ms DESC, task_id DESC);
CREATE INDEX audit_export_history_terminal_time
    ON audit_export_history(finished_at_ms DESC, task_id DESC) WHERE phase <> 'running';
