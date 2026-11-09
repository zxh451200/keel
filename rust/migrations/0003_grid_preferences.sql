-- Layout belongs to an application user, never to the global config file.
CREATE TABLE grid_preferences (
    owner_id INTEGER NOT NULL REFERENCES app_user(id) ON DELETE RESTRICT,
    list_id TEXT NOT NULL CHECK(list_id IN ('audit_log', 'grid_poc_fixture')),
    revision INTEGER NOT NULL CHECK(revision > 0),
    layout_json TEXT NOT NULL CHECK(length(layout_json) BETWEEN 1 AND 4096),
    PRIMARY KEY(owner_id, list_id)
);
