//! Bounded, versioned per-user layouts. No SQL or global settings mutations.
use crate::api::grid_preferences::{GridColumnPreference, GridPreferences, SaveGridPreferences};
use crate::data::{grid_preferences as storage, user};
use crate::errors::KeelError;
use crate::services::access;
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;
use std::collections::HashSet;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Layout {
    schema: u32,
    columns: Vec<GridColumnPreference>,
}

fn invalid() -> KeelError {
    KeelError::Validation("布局无效或已改变，请重新读取列设置".into())
}

fn column_ids(list_id: &str) -> Result<[&'static str; 5], KeelError> {
    match list_id {
        "audit_log" => Ok(["at", "actor", "action", "target", "result"]),
        "grid_poc_fixture" => Ok(["id", "text", "quantity", "date", "kind"]),
        _ => Err(invalid()),
    }
}

fn validate(list_id: &str, columns: &[GridColumnPreference]) -> Result<(), KeelError> {
    let ids = column_ids(list_id)?;
    if columns.len() != ids.len() {
        return Err(invalid());
    }
    let mut seen = HashSet::new();
    let mut any_visible = false;
    let mut previous_group = 0;
    for column in columns {
        if !ids.contains(&column.id.as_str())
            || !seen.insert(column.id.as_str())
            || !(80..=800).contains(&column.width)
        {
            return Err(invalid());
        }
        let group = match column.frozen.as_str() {
            "start" => 0,
            "none" => 1,
            "end" => 2,
            _ => return Err(invalid()),
        };
        if !column.visible && group != 1 {
            return Err(invalid());
        }
        if group < previous_group {
            return Err(invalid());
        }
        previous_group = group;
        if column.visible {
            any_visible = true;
        }
    }
    if !any_visible {
        return Err(invalid());
    }
    Ok(())
}

fn decode(list_id: &str, json: &str) -> Result<Vec<GridColumnPreference>, KeelError> {
    if json.len() > 4096 {
        return Err(invalid());
    }
    let layout: Layout = serde_json::from_str(json).map_err(|_| invalid())?;
    if layout.schema != 1 {
        return Err(invalid());
    }
    validate(list_id, &layout.columns)?;
    Ok(layout.columns)
}

async fn owner(pool: &SqlitePool, identity: &access::CurrentUser) -> Result<i64, KeelError> {
    let row = user::find_by_name(pool, &identity.name)
        .await?
        .ok_or(KeelError::NotFound)?;
    if row.role != identity.role.as_str() {
        return Err(invalid());
    }
    Ok(row.id)
}

fn check_identity(identity: &access::CurrentUser, session: &str) -> Result<(), KeelError> {
    let (current, epoch) = access::identity_snapshot()?;
    if current != *identity || epoch != session {
        return Err(invalid());
    }
    Ok(())
}

pub async fn load(pool: &SqlitePool, list_id: &str) -> Result<GridPreferences, KeelError> {
    let ids = column_ids(list_id)?;
    let _guard = access::lock_identity().await;
    let (identity, session) = access::identity_snapshot()?;
    let owner_id = owner(pool, &identity).await?;
    let mut connection = pool.acquire().await?;
    let stored = storage::load(&mut connection, owner_id, list_id).await?;
    let (revision, columns) = match stored {
        Some(row) => {
            if row.revision <= 0 {
                return Err(invalid());
            }
            (row.revision, decode(list_id, &row.layout_json)?)
        }
        None => (
            0,
            ids.into_iter()
                .map(|id| GridColumnPreference {
                    id: id.into(),
                    width: 160,
                    visible: true,
                    frozen: "none".into(),
                })
                .collect(),
        ),
    };
    check_identity(&identity, &session)?;
    Ok(GridPreferences {
        list_id: list_id.into(),
        owner_id: owner_id.to_string(),
        session,
        revision,
        columns,
    })
}

pub async fn save(
    pool: &SqlitePool,
    request: SaveGridPreferences,
) -> Result<GridPreferences, KeelError> {
    validate(&request.list_id, &request.columns)?;
    if request.expected_revision < 0 || request.expected_revision == i64::MAX {
        return Err(invalid());
    }
    let _guard = access::lock_identity().await;
    let (identity, session) = access::identity_snapshot()?;
    let owner_id = owner(pool, &identity).await?;
    if request.expected_owner_id != owner_id.to_string() || request.expected_session != session {
        return Err(invalid());
    }
    let json = serde_json::to_string(&Layout {
        schema: 1,
        columns: request.columns.clone(),
    })
    .map_err(|_| invalid())?;
    if json.len() > 4096 {
        return Err(invalid());
    }
    let mut transaction = pool.begin().await?;
    let stored = storage::load(transaction.as_mut(), owner_id, &request.list_id).await?;
    if let Some(row) = stored {
        // Protect damaged and future-schema data even if a caller guesses its revision.
        decode(&request.list_id, &row.layout_json)?;
        if row.revision != request.expected_revision {
            return Err(invalid());
        }
    } else if request.expected_revision != 0 {
        return Err(invalid());
    }
    check_identity(&identity, &session)?;
    if !storage::save(
        transaction.as_mut(),
        owner_id,
        &request.list_id,
        request.expected_revision,
        &json,
    )
    .await?
    {
        return Err(invalid());
    }
    check_identity(&identity, &session)?;
    transaction.commit().await?;
    Ok(GridPreferences {
        list_id: request.list_id,
        owner_id: owner_id.to_string(),
        session,
        revision: request.expected_revision + 1,
        columns: request.columns,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn defaults(list_id: &str) -> Vec<GridColumnPreference> {
        column_ids(list_id)
            .unwrap()
            .into_iter()
            .map(|id| GridColumnPreference {
                id: id.into(),
                width: 160,
                visible: true,
                frozen: "none".into(),
            })
            .collect()
    }

    #[test]
    fn validates_layout_boundaries_for_both_lists() {
        for list_id in ["audit_log", "grid_poc_fixture"] {
            let mut valid = defaults(list_id);
            valid[0].width = 80;
            valid[0].frozen = "start".into();
            valid[1].visible = false;
            valid[4].width = 800;
            valid[4].frozen = "end".into();
            assert!(validate(list_id, &valid).is_ok());
            for case in 0..8 {
                let mut columns = defaults(list_id);
                match case {
                    0 => columns[0].width = 79,
                    1 => columns[0].width = 801,
                    2 => columns[0].frozen = "middle".into(),
                    3 => {
                        columns[0].visible = false;
                        columns[0].frozen = "end".into();
                    }
                    4 => columns[1].frozen = "start".into(),
                    5 => columns[0].frozen = "end".into(),
                    6 => {
                        columns.pop();
                    }
                    7 => columns[0].id = "unknown".into(),
                    _ => unreachable!(),
                }
                assert!(
                    validate(list_id, &columns).is_err(),
                    "{list_id}: case {case}"
                );
            }
            let mut json = serde_json::to_value(Layout {
                schema: 1,
                columns: defaults(list_id),
            })
            .unwrap();
            json["unexpected"] = serde_json::json!(true);
            assert!(decode(list_id, &json.to_string()).is_err());
            json.as_object_mut().unwrap().remove("unexpected");
            json["columns"][0]["unexpected"] = serde_json::json!(true);
            assert!(decode(list_id, &json.to_string()).is_err());
        }
    }

    #[test]
    fn rejects_future_schema_duplicate_and_unusable_layouts() {
        let columns: Vec<_> = column_ids("audit_log")
            .unwrap()
            .into_iter()
            .map(|id| GridColumnPreference {
                id: id.into(),
                width: 160,
                visible: true,
                frozen: "none".into(),
            })
            .collect();
        assert!(validate("audit_log", &columns).is_ok());
        let mut bad = columns.clone();
        bad[1].id = bad[0].id.clone();
        assert!(validate("audit_log", &bad).is_err());
        let mut bad = columns.clone();
        for column in &mut bad {
            column.visible = false;
        }
        assert!(validate("audit_log", &bad).is_err());
        let mut bad = columns.clone();
        bad[1].frozen = "start".into();
        assert!(validate("audit_log", &bad).is_err());
        let mut bad = columns.clone();
        bad[0].visible = false;
        bad[1].frozen = "start".into();
        assert!(validate("audit_log", &bad).is_err());
        let mut bad = columns.clone();
        bad[0].frozen = "start".into();
        bad[1].frozen = "end".into();
        bad[2].visible = false;
        assert!(validate("audit_log", &bad).is_err());
        let json = serde_json::to_string(&Layout { schema: 2, columns }).unwrap();
        assert!(decode("audit_log", &json).is_err());
        assert!(column_ids("../audit_log").is_err());
    }
}
