//! 外部诊断/配置输入的只读筛查。
//!
//! 这里受控读取不可信文件/字节，不解压归档、不执行内容，也不写入正式配置。
//! 调用方必须先展示本结果并取得确认，才能在后续功能中实现真正的导入。

use crate::config::{self, AppConfig};
use crate::diagnostics::redact::redact;
use crate::errors::KeelError;
use serde_json::Value;
use std::fs::{File, Metadata, OpenOptions};
use std::io::Read;
use std::path::{Component, Path};

pub const MAX_SCREEN_BYTES: usize = config::MAX_CONFIG_BYTES as usize;
pub const MAX_PREVIEW_CHARS: usize = 16_000;

fn file_error() -> KeelError {
    // 不保留 OS 错误、路径或输入字节，避免 API 错误转换时进入诊断日志。
    KeelError::Import("外部文件不安全、不可读或读取期间发生变化".into())
}

fn validate_local_path(path: &Path) -> Result<(), KeelError> {
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir | Component::CurDir))
    {
        return Err(file_error());
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use std::path::Prefix;
        // 仅盘符绝对路径和 \\?\C:\...；拒绝 UNC、设备命名空间、ADS、DOS 设备名。
        let drive = match path.components().next() {
            Some(Component::Prefix(prefix)) => match prefix.kind() {
                Prefix::Disk(drive) | Prefix::VerbatimDisk(drive) => drive,
                _ => return Err(file_error()),
            },
            _ => return Err(file_error()),
        };
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetDriveTypeW(root: *const u16) -> u32;
        }
        let root = [u16::from(drive), 58, 92, 0];
        // SAFETY: 固定长度、NUL 结尾的 UTF-16 根路径，有效到调用返回。
        // 拒绝映射网络盘、未知设备和不存在的根。
        if !matches!(unsafe { GetDriveTypeW(root.as_ptr()) }, 2 | 3 | 5 | 6) {
            return Err(file_error());
        }
        for part in path.components() {
            if let Component::Normal(name) = part {
                if name
                    .encode_wide()
                    .any(|c| c < 32 || matches!(c, 58 | 47 | 92))
                {
                    return Err(file_error());
                }
                let name = name.to_string_lossy();
                if name.ends_with(['.', ' ']) {
                    return Err(file_error());
                }
                let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
                if matches!(
                    stem.as_str(),
                    "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
                ) || ((stem.starts_with("COM") || stem.starts_with("LPT"))
                    && stem.chars().count() == 4
                    && stem
                        .chars()
                        .last()
                        .is_some_and(|c| matches!(c, '1'..='9' | '¹' | '²' | '³')))
                {
                    return Err(file_error());
                }
            }
        }
    }
    #[cfg(target_os = "linux")]
    if path.as_os_str().as_encoded_bytes().starts_with(b"//") {
        return Err(file_error());
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Err(file_error())
    }
    #[cfg(any(windows, target_os = "linux"))]
    Ok(())
}

fn unlinked(metadata: &Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // FILE_ATTRIBUTE_REPARSE_POINT：包括 junction，而不仅是 symlink。
        metadata.file_attributes() & 0x400 == 0 && !metadata.file_type().is_symlink()
    }
    #[cfg(not(windows))]
    {
        !metadata.file_type().is_symlink()
    }
}

fn check_regular(metadata: &Metadata) -> Result<(), KeelError> {
    if !unlinked(metadata) || !metadata.is_file() || metadata.len() > MAX_SCREEN_BYTES as u64 {
        return Err(file_error());
    }
    Ok(())
}

fn unchanged(before: &Metadata, after: &Metadata) -> bool {
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::MetadataExt;
        before.dev() == after.dev()
            && before.ino() == after.ino()
            && before.mode() == after.mode()
            && before.mtime() == after.mtime()
            && before.mtime_nsec() == after.mtime_nsec()
            && before.ctime() == after.ctime()
            && before.ctime_nsec() == after.ctime_nsec()
            && before.len() == after.len()
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        before.creation_time() == after.creation_time()
            && before.last_write_time() == after.last_write_time()
            && before.file_attributes() == after.file_attributes()
            && before.len() == after.len()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (before, after);
        false
    }
}

fn same_directory(before: &Metadata, after: &Metadata) -> bool {
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::MetadataExt;
        before.dev() == after.dev() && before.ino() == after.ino()
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        before.creation_time() == after.creation_time()
            && before.file_attributes() == after.file_attributes()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (before, after);
        false
    }
}

#[cfg(target_os = "linux")]
fn linux_open_flags() -> Result<i32, KeelError> {
    // Linux UAPI fcntl ABI，仅用于已知使用这些数值的架构。
    #[cfg(any(
        target_arch = "x86",
        target_arch = "x86_64",
        target_arch = "arm",
        target_arch = "aarch64",
        target_arch = "riscv64",
        target_arch = "loongarch64"
    ))]
    {
        Ok(0x20000 | 0x800) // O_NOFOLLOW | O_NONBLOCK（FIFO 不阻塞）
    }
    #[cfg(not(any(
        target_arch = "x86",
        target_arch = "x86_64",
        target_arch = "arm",
        target_arch = "aarch64",
        target_arch = "riscv64",
        target_arch = "loongarch64"
    )))]
    {
        Err(file_error())
    }
}

fn open_unlinked(path: &Path) -> Result<File, KeelError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // FILE_FLAG_OPEN_REPARSE_POINT；只共享读，读取期间拒绝新写者/删除者。
        options.custom_flags(0x00200000).share_mode(1);
    }
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(linux_open_flags()?);
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (path, options);
        Err(file_error())
    }
    #[cfg(any(windows, target_os = "linux"))]
    options.open(path).map_err(|_| file_error())
}

#[cfg(windows)]
fn windows_identity(file: &File) -> Result<(u32, u32, u32), KeelError> {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    // Win32 BY_HANDLE_FILE_INFORMATION：13 个 DWORD（FILETIME 各含两个 DWORD）。
    #[repr(C)]
    struct Information {
        attributes: u32,
        creation: [u32; 2],
        access: [u32; 2],
        write: [u32; 2],
        volume: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFileInformationByHandle(handle: *mut c_void, info: *mut Information) -> i32;
    }
    let mut info = std::mem::MaybeUninit::<Information>::uninit();
    // SAFETY: 借用有效 File 句柄，输出缓冲区符合 Win32 ABI；仅成功后读取。
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), info.as_mut_ptr()) } == 0 {
        return Err(file_error());
    }
    // SAFETY: Win32 成功返回已初始化的完整结构。
    let info = unsafe { info.assume_init() };
    Ok((info.volume, info.index_high, info.index_low))
}

/// 同一打开句柄限量读取；prepare 应缓存返回字节，确认时只重新校验该快照。
/// 逐级检查祖先链接并在读后复查，但不持有整条目录链的句柄：
/// 并发祖先目录替换/换回仍有边界，这不是文件系统沙箱。
pub fn read_file(path: &Path) -> Result<Vec<u8>, KeelError> {
    read_file_checked(path, || {}, || {})
}

fn read_file_checked(
    path: &Path,
    before_open: impl FnOnce(),
    after_read: impl FnOnce(),
) -> Result<Vec<u8>, KeelError> {
    validate_local_path(path)?;
    let mut ancestors = Vec::new();
    for ancestor in path.ancestors().skip(1) {
        let metadata = std::fs::symlink_metadata(ancestor).map_err(|_| file_error())?;
        if !metadata.is_dir() || !unlinked(&metadata) {
            return Err(file_error());
        }
        ancestors.push((ancestor, metadata));
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|_| file_error())?;
    check_regular(&metadata)?;
    // Windows std Metadata 的稳定 API 没有 file index；用只读 probe 句柄绑定预检身份。
    #[cfg(windows)]
    let probe = open_unlinked(path)?;
    #[cfg(windows)]
    if !unchanged(&metadata, &probe.metadata().map_err(|_| file_error())?) {
        return Err(file_error());
    }
    before_open();
    let mut file = open_unlinked(path)?;
    let opened = file.metadata().map_err(|_| file_error())?;
    check_regular(&opened)?;
    if !unchanged(&metadata, &opened) {
        return Err(file_error());
    }
    #[cfg(windows)]
    if windows_identity(&probe)? != windows_identity(&file)? {
        return Err(file_error());
    }
    let mut input = Vec::with_capacity(opened.len() as usize);
    (&mut file)
        .take((MAX_SCREEN_BYTES + 1) as u64)
        .read_to_end(&mut input)
        .map_err(|_| file_error())?;
    after_read();
    let after = file.metadata().map_err(|_| file_error())?;
    check_regular(&after)?;
    let path_after = std::fs::symlink_metadata(path).map_err(|_| file_error())?;
    check_regular(&path_after)?;
    if input.len() > MAX_SCREEN_BYTES
        || input.len() as u64 != opened.len()
        || !unchanged(&opened, &after)
        || !unchanged(&opened, &path_after)
    {
        return Err(file_error());
    }
    #[cfg(windows)]
    if windows_identity(&file)? != windows_identity(&open_unlinked(path)?)? {
        return Err(file_error());
    }
    for (ancestor, before) in ancestors {
        let after = std::fs::symlink_metadata(ancestor).map_err(|_| file_error())?;
        if !after.is_dir() || !unlinked(&after) || !same_directory(&before, &after) {
            return Err(file_error());
        }
    }
    Ok(input)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScreenKind {
    Text,
    Config,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenedInput {
    pub kind: ScreenKind,
    pub parseable: bool,
    pub config_version: Option<u32>,
    pub config_importable: bool,
    pub sensitive_categories: Vec<String>,
    pub preview: String,
}

const CONFIG_FIELDS: [&str; 9] = [
    "version",
    "language",
    "theme",
    "format_locale",
    "time_zone",
    "currency",
    "pending_settings_audit",
    "pending_settings_import_audit",
    "workspace_navigation",
];

/// 在确认写入前重新解析并校验配置；调用方不得把第一次筛查结果当作写入凭据。
pub fn parse_importable_config(input: &[u8]) -> Result<AppConfig, KeelError> {
    if input.len() > MAX_SCREEN_BYTES {
        return Err(KeelError::Import("外部配置超过大小上限".into()));
    }
    let text = std::str::from_utf8(input)
        .map_err(|_| KeelError::Import("外部配置不是有效的 UTF-8 文本".into()))?;
    let value: Value = serde_json::from_str(text.trim())
        .map_err(|_| KeelError::Import("外部配置 JSON 格式不正确".into()))?;
    let object = value
        .as_object()
        .ok_or_else(|| KeelError::Import("外部配置必须是 JSON 对象".into()))?;
    if !object
        .keys()
        .all(|key| CONFIG_FIELDS.contains(&key.as_str()))
    {
        return Err(KeelError::Import("外部配置包含不允许的字段".into()));
    }
    let version = object
        .get("version")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| KeelError::Import("外部配置版本不支持".into()))?;
    if version > config::CURRENT_VERSION {
        return Err(KeelError::Import("外部配置来自更新版本的程序".into()));
    }
    let mut config: AppConfig = serde_json::from_value(value)
        .map_err(|_| KeelError::Import("外部配置格式不正确".into()))?;
    config
        .migrate()
        .map_err(|_| KeelError::Import("外部配置校验失败".into()))?;
    Ok(config)
}

/// 筛查外部文本或配置候选，只返回脱敏后的预览。
pub fn screen_bytes(input: &[u8]) -> Result<ScreenedInput, KeelError> {
    if input.len() > MAX_SCREEN_BYTES {
        return Err(KeelError::Validation("外部输入超过大小上限".into()));
    }
    let text = std::str::from_utf8(input)
        .map_err(|_| KeelError::Validation("外部输入不是有效的 UTF-8 文本".into()))?;
    screen_text(text)
}

pub fn screen_text(text: &str) -> Result<ScreenedInput, KeelError> {
    if text.len() > MAX_SCREEN_BYTES {
        return Err(KeelError::Validation("外部输入超过大小上限".into()));
    }

    let redacted = redact(text);
    let preview = bounded_preview(&redacted);
    let categories = sensitive_categories(text, &redacted);
    let trimmed = text.trim();
    let looks_like_json = trimmed.starts_with('{') || trimmed.starts_with('[');

    if !looks_like_json {
        return Ok(ScreenedInput {
            kind: ScreenKind::Text,
            parseable: true,
            config_version: None,
            config_importable: false,
            sensitive_categories: categories,
            preview,
        });
    }

    let value: Value = serde_json::from_str(trimmed)
        .map_err(|_| KeelError::Validation("外部 JSON 格式不正确".into()))?;
    let object = value
        .as_object()
        .ok_or_else(|| KeelError::Validation("外部配置必须是 JSON 对象".into()))?;

    if object.contains_key("version") {
        let version = object
            .get("version")
            .and_then(Value::as_u64)
            .ok_or_else(|| KeelError::Validation("外部配置版本不支持".into()))?;
        let version = u32::try_from(version)
            .map_err(|_| KeelError::Validation("外部配置版本不支持".into()))?;
        if version > config::CURRENT_VERSION {
            return Err(KeelError::Validation("外部配置来自更新版本的程序".into()));
        }
        let has_unknown = object
            .keys()
            .any(|key| !CONFIG_FIELDS.contains(&key.as_str()));
        let config: AppConfig = serde_json::from_value(value)
            .map_err(|_| KeelError::Validation("外部配置格式不正确".into()))?;
        config.validate()?;
        return Ok(ScreenedInput {
            kind: ScreenKind::Config,
            parseable: true,
            config_version: Some(version),
            config_importable: !has_unknown,
            sensitive_categories: categories,
            preview,
        });
    }

    Ok(ScreenedInput {
        kind: ScreenKind::Text,
        parseable: true,
        config_version: None,
        config_importable: false,
        sensitive_categories: categories,
        preview,
    })
}

fn bounded_preview(text: &str) -> String {
    text.chars().take(MAX_PREVIEW_CHARS).collect()
}

pub(crate) fn sensitive_categories(raw: &str, redacted: &str) -> Vec<String> {
    let mut categories = Vec::new();
    let lower = raw.to_ascii_lowercase();
    if raw != redacted {
        categories.push("redacted-content".into());
    }
    if ["password", "passwd", "pwd", "secret"]
        .iter()
        .any(|key| lower.contains(key))
    {
        categories.push("password-or-secret".into());
    }
    if ["token", "authorization", "api_key", "apikey", "access_key"]
        .iter()
        .any(|key| lower.contains(key))
    {
        categories.push("token-or-access-key".into());
    }
    if raw.contains("://") && raw.contains('@') {
        categories.push("url-credentials".into());
    }
    if redacted.contains("***@***") || lower.contains('@') {
        categories.push("email-or-contact".into());
    }
    if lower.contains("\\users\\") || lower.contains("/users/") || lower.contains("/home/") {
        categories.push("user-path".into());
    }
    categories.sort();
    categories.dedup();
    categories
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_config() -> String {
        r#"{"version":3,"language":"en","theme":"dark","workspace_navigation":{"recent_kinds":[],"favorite_kinds":[],"nav_collapsed":false}}"#.into()
    }

    #[test]
    fn screens_text_without_returning_raw_secrets() {
        let result = screen_text(
            "password=private-secret token=private-token mail=a@corp.example /home/alice/app",
        )
        .unwrap();
        assert_eq!(result.kind, ScreenKind::Text);
        assert!(result.parseable);
        assert!(result.config_version.is_none());
        assert!(!result.config_importable);
        assert!(result
            .sensitive_categories
            .contains(&"password-or-secret".into()));
        assert!(result
            .sensitive_categories
            .contains(&"token-or-access-key".into()));
        assert!(result
            .sensitive_categories
            .contains(&"email-or-contact".into()));
        assert!(result.sensitive_categories.contains(&"user-path".into()));
        assert!(!result.preview.contains("private-secret"));
        assert!(!result.preview.contains("private-token"));
        assert!(!result.preview.contains("alice"));
    }

    #[test]
    fn screens_valid_config_without_writing_or_importing_it() {
        let result = screen_text(&valid_config()).unwrap();
        assert_eq!(result.kind, ScreenKind::Config);
        assert_eq!(result.config_version, Some(3));
        assert!(result.parseable);
        assert!(result.config_importable);
    }

    #[test]
    fn unknown_config_fields_are_marked_not_importable() {
        let result = screen_text(r#"{"version":3,"future_setting":"ignored"}"#).unwrap();
        assert_eq!(result.kind, ScreenKind::Config);
        assert!(!result.config_importable);
    }

    #[test]
    fn rejects_invalid_encoding_size_json_and_future_versions() {
        assert_eq!(screen_bytes(&[0xff]).unwrap_err().code(), "KEEL-VALIDATION");
        assert_eq!(
            screen_bytes(&vec![b'a'; MAX_SCREEN_BYTES + 1])
                .unwrap_err()
                .code(),
            "KEEL-VALIDATION"
        );
        assert_eq!(
            screen_text("{not-json").unwrap_err().code(),
            "KEEL-VALIDATION"
        );
        assert_eq!(
            screen_text(r#"{"version":99}"#).unwrap_err().code(),
            "KEEL-VALIDATION"
        );
    }

    #[test]
    fn bounds_preview_without_leaking_unbounded_input() {
        let result = screen_text(&format!("token={}", "x".repeat(MAX_SCREEN_BYTES - 10))).unwrap();
        assert!(result.preview.chars().count() <= MAX_PREVIEW_CHARS);
        assert!(!result.preview.contains(&"x".repeat(64)));
    }

    #[test]
    fn reparses_only_importable_config_and_rejects_unknown_fields() {
        let config = parse_importable_config(valid_config().as_bytes()).unwrap();
        assert_eq!(config.language.as_deref(), Some("en"));
        assert_eq!(
            parse_importable_config(br#"{"version":3,"command":"run"}"#)
                .unwrap_err()
                .code(),
            "KEEL-IMPORT"
        );
    }

    #[test]
    fn format_locale_screening_validates_values_types_and_legacy_migration() {
        for locale in [
            Value::Null,
            Value::from("en_US"),
            Value::from("en_GB"),
            Value::from("zh_CN"),
        ] {
            let input = serde_json::to_vec(&serde_json::json!({
                "version": 4, "language": "zh", "format_locale": locale
            }))
            .unwrap();
            let screened = screen_bytes(&input).unwrap();
            assert_eq!(screened.config_version, Some(4));
            assert!(screened.config_importable);
            let parsed = parse_importable_config(&input).unwrap();
            assert_eq!(serde_json::to_value(parsed.format_locale).unwrap(), locale);
            assert_eq!(parsed.language.as_deref(), Some("zh"));
        }
        for version in 1..=3 {
            let input = serde_json::to_vec(&serde_json::json!({
                "version": version, "language": "en", "format_locale": "zh_CN"
            }))
            .unwrap();
            assert!(screen_bytes(&input).unwrap().config_importable);
            let parsed = parse_importable_config(&input).unwrap();
            assert_eq!(parsed.version, config::CURRENT_VERSION);
            assert_eq!(parsed.format_locale, None);
        }
        for locale in [
            serde_json::json!(""),
            serde_json::json!("en"),
            serde_json::json!("en-US"),
            serde_json::json!("en_us"),
            serde_json::json!("fr_FR"),
            serde_json::json!(" en_GB"),
            serde_json::json!("zh_CN\n"),
            serde_json::json!(123),
            serde_json::json!(false),
            serde_json::json!([]),
            serde_json::json!({}),
        ] {
            let input = serde_json::to_vec(&serde_json::json!({
                "version": 4, "format_locale": locale
            }))
            .unwrap();
            assert_eq!(screen_bytes(&input).unwrap_err().code(), "KEEL-VALIDATION");
            assert_eq!(
                parse_importable_config(&input).unwrap_err().code(),
                "KEEL-IMPORT"
            );
        }
        let future = serde_json::to_vec(&serde_json::json!({
            "version": config::CURRENT_VERSION + 1, "format_locale": "en_US"
        }))
        .unwrap();
        assert!(screen_bytes(&future).is_err());
        assert!(parse_importable_config(&future).is_err());
    }

    #[test]
    fn reads_only_regular_files_with_the_size_limit() {
        let dir = std::env::temp_dir().join(format!("keel-import-screen-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("config.json");
        std::fs::write(&file, valid_config()).unwrap();
        assert_eq!(read_file(&file).unwrap(), valid_config().as_bytes());
        assert_eq!(read_file(&dir).unwrap_err().code(), "KEEL-IMPORT");
        std::fs::write(&file, vec![b'x'; MAX_SCREEN_BYTES + 1]).unwrap();
        assert_eq!(read_file(&file).unwrap_err().code(), "KEEL-IMPORT");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(unix)]
    #[test]
    fn rejects_file_symlinks_without_reading_the_target() {
        use std::os::unix::fs::symlink;

        let dir =
            std::env::temp_dir().join(format!("keel-import-screen-symlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("target.json");
        let link = dir.join("config.json");
        std::fs::write(&target, valid_config()).unwrap();
        symlink(&target, &link).unwrap();
        assert_eq!(read_file(&link).unwrap_err().code(), "KEEL-IMPORT");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn rejects_ancestor_links_replacements_fifo_and_changes_during_read() {
        use std::os::unix::fs::symlink;

        let dir = std::env::temp_dir().join(format!("keel-import-races-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("config.json");
        let other = dir.join("other.json");
        let parked = dir.join("parked.json");
        std::fs::write(&file, valid_config()).unwrap();
        std::fs::write(&other, valid_config()).unwrap();
        let linked_dir = dir.join("linked");
        symlink(&dir, &linked_dir).unwrap();
        assert_eq!(
            read_file(&linked_dir.join("config.json"))
                .unwrap_err()
                .code(),
            "KEEL-IMPORT"
        );
        assert_eq!(
            read_file(Path::new("relative.json")).unwrap_err().code(),
            "KEEL-IMPORT"
        );
        // 即使替换后的普通文件大小和内容相同，也必须拒绝新 inode。
        let error = read_file_checked(
            &file,
            || {
                std::fs::rename(&file, &parked).unwrap();
                std::fs::copy(&other, &file).unwrap();
            },
            || {},
        )
        .unwrap_err();
        assert_eq!(error.code(), "KEEL-IMPORT");
        std::fs::remove_file(&parked).unwrap();
        let error = read_file_checked(
            &file,
            || {
                std::fs::remove_file(&file).unwrap();
                symlink(&other, &file).unwrap();
            },
            || {},
        )
        .unwrap_err();
        assert_eq!(error.code(), "KEEL-IMPORT");
        std::fs::remove_file(&file).unwrap();
        std::fs::write(&file, valid_config()).unwrap();
        // 使用系统测试工具创建 FIFO，无生产依赖；O_NONBLOCK 保证替换竞态不会挂住 open。
        let fifo = dir.join("fifo");
        assert!(std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success());
        assert_eq!(read_file(&fifo).unwrap_err().code(), "KEEL-IMPORT");
        let error = read_file_checked(
            &file,
            || {
                std::fs::remove_file(&file).unwrap();
                std::fs::rename(&fifo, &file).unwrap();
            },
            || {},
        )
        .unwrap_err();
        assert_eq!(error.code(), "KEEL-IMPORT");
        std::fs::remove_file(&file).unwrap();
        std::fs::write(&file, valid_config()).unwrap();
        for content in [b"short".to_vec(), vec![b'x'; MAX_SCREEN_BYTES + 1]] {
            let error = read_file_checked(
                &file,
                || {},
                || {
                    std::fs::write(&file, &content).unwrap();
                },
            )
            .unwrap_err();
            assert_eq!(error.code(), "KEEL-IMPORT");
            assert!(!error.detail().contains(file.to_string_lossy().as_ref()));
            std::fs::write(&file, valid_config()).unwrap();
        }
        std::fs::write(&file, vec![b' '; MAX_SCREEN_BYTES]).unwrap();
        assert_eq!(read_file(&file).unwrap().len(), MAX_SCREEN_BYTES);

        // 末级仍指向同一个 inode 时，读后也必须检查祖先是否变成了链接。
        let parent = dir.join("parent");
        let moved_parent = dir.join("moved-parent");
        std::fs::create_dir(&parent).unwrap();
        let nested_file = parent.join("config.json");
        std::fs::write(&nested_file, valid_config()).unwrap();
        let error = read_file_checked(
            &nested_file,
            || {},
            || {
                std::fs::rename(&parent, &moved_parent).unwrap();
                symlink(&moved_parent, &parent).unwrap();
            },
        )
        .unwrap_err();
        assert_eq!(error.code(), "KEEL-IMPORT");
        std::fs::remove_file(&parent).unwrap();
        assert_eq!(
            read_file(&dir.join("moved-parent/../config.json"))
                .unwrap_err()
                .code(),
            "KEEL-IMPORT"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn windows_local_path_allowlist_excludes_devices_unc_and_streams() {
        for path in [r"C:\folder\config.json", r"\\?\C:\folder\config.json"] {
            assert!(validate_local_path(Path::new(path)).is_ok());
        }
        for path in [
            r"config.json",
            r"C:config.json",
            r"\config.json",
            r"\\host\share\config.json",
            r"\\?\UNC\host\share\config.json",
            r"\\.\C:\config.json",
            r"\\?\GLOBALROOT\Device\config.json",
            r"C:\folder\NUL",
            r"\\?\C:\folder\COM1.json",
            r"C:\folder\config.json:stream",
            r"C:\folder\..\config.json",
        ] {
            assert!(validate_local_path(Path::new(path)).is_err());
        }
    }

    #[cfg(windows)]
    #[test]
    fn rejects_windows_junction_ancestors_and_reparse_handles() {
        use std::os::windows::fs::symlink_file;

        let dir = std::env::temp_dir().join(format!("keel-import-reparse-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let target_dir = dir.join("target");
        std::fs::create_dir(&target_dir).unwrap();
        let target = target_dir.join("config.json");
        std::fs::write(&target, valid_config()).unwrap();
        let junction = dir.join("junction");
        // Junction 不要求 symlink 特权，确保 Windows CI 始终覆盖祖先 reparse。
        assert!(std::process::Command::new("cmd")
            .args(["/D", "/C", "mklink", "/J"])
            .arg(&junction)
            .arg(&target_dir)
            .status()
            .unwrap()
            .success());
        assert_eq!(
            read_file(&junction.join("config.json")).unwrap_err().code(),
            "KEEL-IMPORT"
        );
        std::fs::remove_dir(&junction).unwrap();
        let link = dir.join("link.json");
        match symlink_file(&target, &link) {
            Ok(()) => {
                assert_eq!(read_file(&link).unwrap_err().code(), "KEEL-IMPORT");
                let handle = open_unlinked(&link).unwrap();
                assert_eq!(
                    check_regular(&handle.metadata().unwrap())
                        .unwrap_err()
                        .code(),
                    "KEEL-IMPORT"
                );
                drop(handle);
                std::fs::remove_file(&link).unwrap();
            }
            // ERROR_PRIVILEGE_NOT_HELD；junction 断言仍必须执行，不能整项跳过。
            Err(error) if error.raw_os_error() == Some(1314) => {}
            Err(error) => panic!("symlink fixture failed: {error}"),
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
