//! 版本化的用户配置（语言、主题、显示区域、工作区导航），JSON 文件放在系统用户数据目录。
//!
//! - 文件不存在：返回默认配置。
//! - 文件损坏或版本比程序新：返回错误且不覆盖原文件，避免丢用户设置。
//! - 保存先完整写入并同步临时文件，再同目录改名替换正式配置。
//! - 配置里不放密码、令牌等敏感信息（需求文档 §4.1，凭据走系统凭据存储）。
//! - 偏好与待写审计在同一 JSON 中原子替换；仅支持单进程应用写者，
//!   不承诺跨多进程配置并发写或本机防篡改。应用写入须经过 settings 服务的锁。

use crate::errors::KeelError;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

/// 程序当前认识的配置版本。字段含义变化时加 1，并在 `load` 里写迁移。
pub const CURRENT_VERSION: u32 = 5;

pub const SETTINGS_FIELDS: [&str; 5] = [
    "language",
    "theme",
    "format_locale",
    "time_zone",
    "currency",
];
pub const SUPPORTED_TIME_ZONES: &[&str] = &["UTC"];
pub const SUPPORTED_CURRENCIES: &[&str] = &["CNY", "USD", "EUR", "GBP", "JPY"];

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RegionalPreferences {
    pub time_zone: Option<String>,
    pub currency: Option<String>,
}

impl RegionalPreferences {
    pub fn validate(&self) -> Result<(), KeelError> {
        if self
            .time_zone
            .as_deref()
            .is_some_and(|v| !SUPPORTED_TIME_ZONES.contains(&v))
            || self
                .currency
                .as_deref()
                .is_some_and(|v| !SUPPORTED_CURRENCIES.contains(&v))
        {
            return Err(KeelError::Validation(
                "Unsupported regional preference".into(),
            ));
        }
        Ok(())
    }
}

/// settings.change 与 settings.import 共用此总容量，防止离线失败无限增长。
pub const MAX_PENDING_SETTINGS_AUDIT: usize = 200;
/// 在解析不可信 JSON 前限制读取量；额外读取一个字节以检测读取期间的增长。
pub const MAX_CONFIG_BYTES: u64 = 1024 * 1024;

/// 有序的工作区 kind 列表；同一个 kind 可以同时出现在最近访问与收藏中。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct WorkspaceNavigation {
    pub recent_kinds: Vec<String>,
    pub favorite_kinds: Vec<String>,
    #[serde(default)]
    pub nav_collapsed: bool,
}

impl WorkspaceNavigation {
    pub fn validate(&self) -> Result<(), KeelError> {
        for (kinds, limit) in [(&self.recent_kinds, 10), (&self.favorite_kinds, 50)] {
            if kinds.len() > limit {
                return Err(KeelError::Validation("工作区导航列表超过上限".into()));
            }
            let mut seen = HashSet::new();
            for kind in kinds {
                if !(1..=64).contains(&kind.len())
                    || !kind
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_'))
                    || !seen.insert(kind)
                {
                    return Err(KeelError::Validation("工作区导航 kind 不合法或重复".into()));
                }
            }
        }
        Ok(())
    }
}

/// 只记录字段名，不存偏好原值/新值、路径或配置快照。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PendingSettingsAudit {
    pub id: String,
    /// UTC epoch 毫秒；重放不得改成重放时间。
    pub at: i64,
    pub actor: String,
    pub changed_fields: Vec<String>,
}

impl PendingSettingsAudit {
    pub fn validate(&self) -> Result<(), KeelError> {
        if !(32..=128).contains(&self.id.len())
            || !self
                .id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_'))
            || self.at < 0
            || self.actor.trim().is_empty()
            || self.actor.chars().count() > 32
            || self.actor.chars().any(char::is_control)
            || self.changed_fields.is_empty()
            || self.changed_fields.len() > SETTINGS_FIELDS.len()
            || self
                .changed_fields
                .iter()
                .any(|field| !SETTINGS_FIELDS.contains(&field.as_str()))
            || self.changed_fields.iter().collect::<HashSet<_>>().len() != self.changed_fields.len()
        {
            return Err(KeelError::Validation("配置待写审计字段不合法".into()));
        }
        Ok(())
    }
}

/// 导入结果不含输入、路径或偏好值；与变更事件分开，避免重放时错误归类。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PendingSettingsImportAudit {
    pub id: String,
    pub at: i64,
    pub actor: String,
    pub result: String,
}

impl PendingSettingsImportAudit {
    pub fn validate(&self) -> Result<(), KeelError> {
        // 复用相同的 ID/时间/操作者约束，不让任意错误文本进入持久队列。
        PendingSettingsAudit {
            id: self.id.clone(),
            at: self.at,
            actor: self.actor.clone(),
            changed_fields: vec!["language".into()],
        }
        .validate()?;
        if self.result != "ok"
            && !self.result.strip_prefix("failed:").is_some_and(|code| {
                matches!(
                    code,
                    "KEEL-VALIDATION"
                        | "KEEL-NOT-FOUND"
                        | "KEEL-DUPLICATE"
                        | "KEEL-DB"
                        | "KEEL-DB-MIGRATION"
                        | "KEEL-IO"
                        | "KEEL-IMPORT"
                        | "KEEL-BACKUP"
                        | "KEEL-UNINITIALIZED"
                        | "KEEL-PERMISSION"
                        | "KEEL-INTERNAL"
                        | "KEEL-CANCELLED"
                )
            })
        {
            return Err(KeelError::Validation("配置导入待写审计结果不合法".into()));
        }
        Ok(())
    }
}

const FILE_NAME: &str = "config.json";

/// 设置了这个环境变量就用它作为数据目录（便携模式、测试、开发时隔离数据）。必须是绝对路径。
pub const DATA_DIR_ENV: &str = "KEEL_DATA_DIR";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AppConfig {
    pub version: u32,
    /// "zh" / "en"；None 表示跟随系统。
    pub language: Option<String>,
    /// "light" / "dark"；None 表示跟随系统。
    pub theme: Option<String>,
    /// "en_US" / "en_GB" / "zh_CN"；None 表示显示格式跟随系统，与界面语言独立。
    pub format_locale: Option<String>,
    pub time_zone: Option<String>,
    pub currency: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pending_settings_audit: Vec<PendingSettingsAudit>,
    /// v4 的兼容新增字段；旧文件缺失时为空，不改变既有变更事件格式。
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pending_settings_import_audit: Vec<PendingSettingsImportAudit>,
    #[serde(default)]
    pub workspace_navigation: WorkspaceNavigation,
}

impl Default for AppConfig {
    fn default() -> Self {
        AppConfig {
            version: CURRENT_VERSION,
            language: None,
            theme: None,
            format_locale: None,
            time_zone: None,
            currency: None,
            pending_settings_audit: Vec::new(),
            pending_settings_import_audit: Vec::new(),
            workspace_navigation: WorkspaceNavigation::default(),
        }
    }
}

impl AppConfig {
    pub fn pending_audit_len(&self) -> usize {
        self.pending_settings_audit.len() + self.pending_settings_import_audit.len()
    }

    /// 检查取值。保存前和读取后都会调用，避免坏值进入程序。
    pub fn validate(&self) -> Result<(), KeelError> {
        if !(1..=CURRENT_VERSION).contains(&self.version) {
            return Err(KeelError::Validation("配置文件版本不支持".into()));
        }
        if let Some(language) = &self.language {
            if !matches!(language.as_str(), "zh" | "en") {
                return Err(KeelError::Validation("language 需为 zh 或 en".into()));
            }
        }
        if let Some(theme) = &self.theme {
            if !matches!(theme.as_str(), "light" | "dark") {
                return Err(KeelError::Validation("theme 需为 light 或 dark".into()));
            }
        }
        if let Some(locale) = &self.format_locale {
            if !matches!(locale.as_str(), "en_US" | "en_GB" | "zh_CN") {
                return Err(KeelError::Validation(
                    "format_locale 需为 en_US、en_GB 或 zh_CN".into(),
                ));
            }
        }
        RegionalPreferences {
            time_zone: self.time_zone.clone(),
            currency: self.currency.clone(),
        }
        .validate()?;
        if self.pending_audit_len() > MAX_PENDING_SETTINGS_AUDIT {
            return Err(KeelError::Validation("配置待写审计队列超过上限".into()));
        }
        let mut ids = HashSet::new();
        for event in &self.pending_settings_audit {
            event.validate()?;
            if !ids.insert(&event.id) {
                return Err(KeelError::Validation("配置待写审计 ID 重复".into()));
            }
        }
        for event in &self.pending_settings_import_audit {
            event.validate()?;
            if !ids.insert(&event.id) {
                return Err(KeelError::Validation("配置待写审计 ID 重复".into()));
            }
        }
        self.workspace_navigation.validate()?;
        Ok(())
    }

    /// 先校验再迁移；旧版没有独立显示区域，统一跟随系统。
    pub(crate) fn migrate(&mut self) -> Result<(), KeelError> {
        self.validate()?;
        if self.version < 4 {
            self.format_locale = None;
        }
        if self.version < 5 {
            self.time_zone = None;
            self.currency = None;
        }
        self.version = CURRENT_VERSION;
        Ok(())
    }
}

#[cfg(windows)]
fn platform_data_dir() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|dir| PathBuf::from(dir).join("Keel"))
}

#[cfg(not(windows))]
fn platform_data_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_DATA_HOME") {
        if !dir.is_empty() {
            return Some(PathBuf::from(dir).join("keel"));
        }
    }
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share/keel"))
}

/// 用户数据目录：Windows `%APPDATA%\Keel`，Linux `~/.local/share/keel`。
/// 数据库、日志、备份以后也放在这里；程序安装目录只放只读资源。
pub fn data_dir() -> Result<PathBuf, KeelError> {
    if let Some(dir) = std::env::var_os(DATA_DIR_ENV) {
        let dir = PathBuf::from(dir);
        if !dir.is_absolute() {
            return Err(KeelError::Validation(format!(
                "{DATA_DIR_ENV} 必须是绝对路径"
            )));
        }
        return Ok(dir);
    }
    platform_data_dir().ok_or_else(|| KeelError::internal("无法确定用户数据目录"))
}

pub fn config_path() -> Result<PathBuf, KeelError> {
    Ok(data_dir()?.join(FILE_NAME))
}

pub fn load(path: &Path) -> Result<AppConfig, KeelError> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(AppConfig::default()),
        Err(e) => return Err(e.into()),
    };
    if file.metadata()?.len() > MAX_CONFIG_BYTES {
        return Err(KeelError::Validation("配置文件超过大小上限".into()));
    }
    let mut text = String::new();
    file.take(MAX_CONFIG_BYTES + 1).read_to_string(&mut text)?;
    if text.len() as u64 > MAX_CONFIG_BYTES {
        return Err(KeelError::Validation("配置文件超过大小上限".into()));
    }
    let mut config: AppConfig = serde_json::from_str(&text)
        .map_err(|_| KeelError::Validation("配置文件格式不正确".into()))?;
    if config.version > CURRENT_VERSION {
        return Err(KeelError::Validation("配置文件来自更新版本的程序".into()));
    }
    // v1 缺失的队列、v1/v2 缺失的导航默认为空；v1-v3 显示区域跟随系统。
    // 只在内存中升级，下次实际变更保存写当前版本；旧程序应拒绝新版本。
    config.migrate()?;
    Ok(config)
}

pub fn save(path: &Path, config: &AppConfig) -> Result<(), KeelError> {
    config.validate()?;
    if config.version != CURRENT_VERSION {
        return Err(KeelError::Validation("保存配置必须使用当前版本".into()));
    }
    // Rust 边界保护：直接调用 save 也不得覆盖损坏或未来版本的文件。
    // 这是单进程约定下的检查，不是跨进程 compare-and-swap。
    load(path)?;
    let text = serde_json::to_string_pretty(config).map_err(KeelError::internal)?;
    if text.len() as u64 > MAX_CONFIG_BYTES {
        return Err(KeelError::Validation("配置文件超过大小上限".into()));
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // 同目录随机临时文件，create_new 避免跟随已有临时文件/符号链接。
    let nonce = std::collections::hash_map::RandomState::new();
    let suffix = std::hash::BuildHasher::hash_one(&nonce, std::process::id());
    let tmp = path.with_extension(format!("json.{suffix:016x}.tmp"));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp)?;
    let written = (|| -> Result<(), std::io::Error> {
        file.write_all(text.as_bytes())?;
        file.sync_all()
    })();
    // Windows rename 前关闭文件；绝不先删除正式配置。
    drop(file);
    if let Err(e) = written.and_then(|()| std::fs::rename(&tmp, path)) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("keel-config-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn config(language: Option<&str>, theme: Option<&str>) -> AppConfig {
        AppConfig {
            language: language.map(str::to_string),
            theme: theme.map(str::to_string),
            ..AppConfig::default()
        }
    }

    #[test]
    fn missing_file_gives_defaults() {
        let dir = temp_dir("missing");
        let loaded = load(&dir.join("config.json")).unwrap();
        assert_eq!(loaded, AppConfig::default());
    }

    #[test]
    fn save_then_load_round_trips_and_leaves_no_temp_file() {
        let dir = temp_dir("roundtrip");
        let path = dir.join("nested").join("config.json");
        let saved = config(Some("zh"), Some("dark"));
        save(&path, &saved).unwrap();
        assert_eq!(load(&path).unwrap(), saved);
        assert!(!path.with_extension("json.tmp").exists());
    }

    #[test]
    fn corrupt_file_is_rejected_and_left_untouched() {
        let dir = temp_dir("corrupt");
        let path = dir.join("config.json");
        std::fs::write(&path, "{ not json").unwrap();
        let err = load(&path).unwrap_err();
        assert_eq!(err.code(), "KEEL-VALIDATION");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "{ not json");
    }

    #[test]
    fn file_from_a_newer_version_is_rejected() {
        let dir = temp_dir("newer");
        let path = dir.join("config.json");
        std::fs::write(&path, r#"{"version": 99}"#).unwrap();
        assert_eq!(load(&path).unwrap_err().code(), "KEEL-VALIDATION");
    }

    #[test]
    fn missing_and_unknown_fields_are_tolerated() {
        let dir = temp_dir("tolerant");
        let path = dir.join("config.json");
        std::fs::write(&path, r#"{"language": "en", "future_field": 1}"#).unwrap();
        let loaded = load(&path).unwrap();
        assert_eq!(loaded.language.as_deref(), Some("en"));
        assert_eq!(loaded.theme, None);
        assert_eq!(loaded.version, CURRENT_VERSION);
    }

    #[test]
    fn invalid_values_are_rejected_on_save_and_on_load() {
        let dir = temp_dir("invalid");
        let path = dir.join("config.json");
        assert!(save(&path, &config(Some("fr"), None)).is_err());
        assert!(save(&path, &config(None, Some("blue"))).is_err());
        assert!(!path.exists());

        std::fs::write(&path, r#"{"language": "fr"}"#).unwrap();
        assert!(load(&path).is_err());
    }
}
