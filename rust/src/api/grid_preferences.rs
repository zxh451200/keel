//! User-owned layout contract. Owner/session tokens are comparisons, not authority.
use crate::api::error::ApiError;
use crate::services::grid_preferences;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GridColumnPreference {
    pub id: String,
    pub width: u32,
    pub visible: bool,
    /// none / start / end.
    pub frozen: String,
}

#[derive(Debug, Clone)]
pub struct GridPreferences {
    pub list_id: String,
    pub owner_id: String,
    pub session: String,
    /// Zero denotes defaults before the first save.
    pub revision: i64,
    pub columns: Vec<GridColumnPreference>,
}

#[derive(Debug, Clone)]
pub struct SaveGridPreferences {
    pub list_id: String,
    pub expected_owner_id: String,
    pub expected_session: String,
    pub expected_revision: i64,
    pub columns: Vec<GridColumnPreference>,
}

pub async fn load_grid_preferences(list_id: String) -> Result<GridPreferences, ApiError> {
    Ok(grid_preferences::load(crate::state::pool()?, &list_id).await?)
}

pub async fn save_grid_preferences(
    request: SaveGridPreferences,
) -> Result<GridPreferences, ApiError> {
    Ok(grid_preferences::save(crate::state::pool()?, request).await?)
}
