//! 用户设置（语言、主题、显示区域）的读取与保存。文件位置由 Rust 自己按系统用户数据目录算出，
//! 正式配置位置由 Rust 决定；外部文件仅接受系统选择器传入的受控只读路径。

use crate::api::error::ApiError;
use crate::config;
use crate::services::settings as settings_service;

#[derive(Debug, Clone)]
pub struct Settings {
    /// "zh" | "en"；None 表示跟随系统
    pub language: Option<String>,
    /// "light" | "dark"；None 表示跟随系统
    pub theme: Option<String>,
    /// "en_US" | "en_GB" | "zh_CN"；None 表示显示格式跟随系统，与 language 独立
    pub format_locale: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceNavigationPreferences {
    pub recent_kinds: Vec<String>,
    pub favorite_kinds: Vec<String>,
    pub nav_collapsed: bool,
}

/// Independent display preferences. Currency never converts existing amounts.
#[derive(Debug, Clone)]
pub struct RegionalSettings {
    pub time_zone: Option<String>,
    pub currency: Option<String>,
}

pub fn load_regional_settings() -> Result<RegionalSettings, ApiError> {
    let config = config::load(&config::config_path()?)?;
    Ok(RegionalSettings {
        time_zone: config.time_zone,
        currency: config.currency,
    })
}

pub async fn save_regional_settings(settings: RegionalSettings) -> Result<(), ApiError> {
    settings_service::save_regional(config::RegionalPreferences {
        time_zone: settings.time_zone,
        currency: settings.currency,
    })
    .await?;
    Ok(())
}

#[derive(Debug, Clone)]
pub struct ExternalConfigPreview {
    pub preview_id: String,
    pub kind: String,
    pub config_version: Option<u32>,
    pub sensitive_categories: Vec<String>,
    pub preview: String,
}

/// 文件不存在或旧配置缺失导航时返回空列表和未折叠状态；损坏/未来配置返回错误。
pub fn load_workspace_navigation_preferences() -> Result<WorkspaceNavigationPreferences, ApiError> {
    let preferences = settings_service::load_navigation()?;
    Ok(WorkspaceNavigationPreferences {
        recent_kinds: preferences.recent_kinds,
        favorite_kinds: preferences.favorite_kinds,
        nav_collapsed: preferences.nav_collapsed,
    })
}

/// 仅保存导航；保持列表顺序，不新增偏好审计事件。
pub async fn save_workspace_navigation_preferences(
    preferences: WorkspaceNavigationPreferences,
) -> Result<(), ApiError> {
    settings_service::save_navigation(config::WorkspaceNavigation {
        recent_kinds: preferences.recent_kinds,
        favorite_kinds: preferences.favorite_kinds,
        nav_collapsed: preferences.nav_collapsed,
    })
    .await?;
    Ok(())
}

/// 读取设置。文件不存在返回默认值；文件损坏或来自更新版本返回 `KEEL-VALIDATION`，且不会覆盖原文件。
pub fn load_settings() -> Result<Settings, ApiError> {
    let config = config::load(&config::config_path()?)?;
    Ok(Settings {
        language: config.language,
        theme: config.theme,
        format_locale: config.format_locale,
    })
}

/// 保存设置及待写审计。无实际变化不新增事件；DB 补写失败只告警，
/// 不把已经成功落盘的设置误报为失败。坏配置/未来版本/满队列拒绝变更。
pub async fn save_settings(settings: Settings) -> Result<(), ApiError> {
    settings_service::save(settings.language, settings.theme, settings.format_locale).await?;
    Ok(())
}

/// 筛查并缓存受限快照；不修改配置。调用方展示预览并取得确认后才能提交句柄。
pub fn prepare_external_config(input: Vec<u8>) -> Result<ExternalConfigPreview, ApiError> {
    let (preview_id, screened) = settings_service::prepare_external_config(input)?;
    Ok(ExternalConfigPreview {
        preview_id,
        kind: format!("{:?}", screened.kind),
        config_version: screened.config_version,
        sensitive_categories: screened.sensitive_categories,
        preview: screened.preview,
    })
}

/// 只读准备本地配置文件，确认时消费同一次内容快照，不重新读取源路径。
pub fn prepare_external_config_file(path: String) -> Result<ExternalConfigPreview, ApiError> {
    let (preview_id, screened) =
        settings_service::prepare_external_config_file(std::path::Path::new(&path))?;
    Ok(ExternalConfigPreview {
        preview_id,
        kind: format!("{:?}", screened.kind),
        config_version: screened.config_version,
        sensitive_categories: screened.sensitive_categories,
        preview: screened.preview,
    })
}

/// 仅消费 Rust 准备的单次快照；写入失败也须重新准备预览，不接受替换内容。
pub async fn import_prepared_external_config(preview_id: String) -> Result<(), ApiError> {
    settings_service::import_prepared_external_config_at(&config::config_path()?, &preview_id)
        .await?;
    Ok(())
}
