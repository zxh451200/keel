//! 外部诊断只读文本：不解析配置，不执行内容，不保存原文。
//! 文件读取、脱敏与类别规则复用已有实现；预览就是完整导出快照。

use crate::diagnostics::{import_screen, redact::redact};
use crate::errors::KeelError;
use std::path::Path;

pub(crate) const MAX_INPUT_BYTES: usize = 1024 * 1024;

pub(crate) struct ScreenedDiagnostic {
    pub(crate) content: String,
    pub(crate) sensitive_categories: Vec<String>,
}

fn invalid() -> KeelError {
    // 错误中不携带原始内容、文件路径或 OS 错误。
    KeelError::Validation("外部诊断必须是至多 1 MiB 的 UTF-8 文本，不支持二进制或归档".into())
}

fn archive_or_binary(input: &[u8]) -> bool {
    // 格式检查独立于扩展名；不尝试解压。控制字符检查另覆盖 NUL/常见二进制。
    let signatures: &[&[u8]] = &[
        b"PK\x03\x04",
        b"PK\x05\x06",
        b"PK\x07\x08",
        b"\x1f\x8b",
        b"BZh",
        b"\xfd7zXZ\0",
        b"7z\xbc\xaf\x27\x1c",
        b"Rar!\x1a\x07",
        b"!<arch>\n",
        b"MSCF",
        b"070701",
        b"070702",
        b"070707",
        b"\x28\xb5\x2f\xfd",
        b"\x04\x22\x4d\x18",
        b"\x7fELF",
        b"MZ",
        b"%PDF-",
        b"SQLite format 3\0",
    ];
    signatures
        .iter()
        .any(|signature| input.starts_with(signature))
        || input.get(257..262) == Some(b"ustar".as_slice())
}

pub(crate) fn screen_bytes(input: &[u8]) -> Result<ScreenedDiagnostic, KeelError> {
    if input.len() > MAX_INPUT_BYTES || archive_or_binary(input) {
        return Err(invalid());
    }
    let text = std::str::from_utf8(input).map_err(|_| invalid())?;
    // 保留文本换行/制表，拒绝 NUL、转义及其他控制字符（含 C1）。
    if text
        .chars()
        .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
    {
        return Err(invalid());
    }
    let content = redact(text);
    // 脱敏替换可能增大内容；必须在完整脱敏后检查，不得截短成功返回。
    if content.len() > MAX_INPUT_BYTES {
        return Err(invalid());
    }
    let sensitive_categories = import_screen::sensitive_categories(text, &content);
    Ok(ScreenedDiagnostic {
        content,
        sensitive_categories,
    })
}

pub(crate) fn screen_file(path: &Path) -> Result<ScreenedDiagnostic, KeelError> {
    let bytes = import_screen::read_file(path)?;
    screen_bytes(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_versions_and_malformed_json_are_ordinary_diagnostic_text() {
        for text in [
            r#"{"version":999,"message":"failure"}"#,
            "{not-json",
            "[1,2]",
        ] {
            assert_eq!(screen_bytes(text.as_bytes()).unwrap().content, text);
        }
    }

    #[test]
    fn full_text_and_shared_sensitive_categories_are_preserved() {
        let text = format!(
            "{}\npassword=private token=hidden /home/alice/app a@corp.example\nEND",
            "正常\n".repeat(20_000)
        );
        let result = screen_bytes(text.as_bytes()).unwrap();
        assert_eq!(result.content, redact(&text));
        assert!(result.content.ends_with("\nEND"));
        assert!(result.content.chars().count() > 16_000);
        assert_eq!(
            result.sensitive_categories,
            import_screen::screen_text(&text)
                .unwrap()
                .sensitive_categories
        );
        assert!(!result.content.contains("private"));
    }

    #[test]
    fn encoding_binary_archives_and_limits_are_rejected() {
        for bytes in [
            b"\xff".as_slice(),
            b"a\0b",
            b"PK\x03\x04text",
            b"!<arch>\ntext",
            b"070701text",
            b"MZtext",
            b"\x1f\x8btext",
            b"\x1b[31mtext",
        ] {
            assert!(screen_bytes(bytes).is_err());
        }
        let mut tar = vec![b' '; 300];
        tar[257..262].copy_from_slice(b"ustar");
        assert!(screen_bytes(&tar).is_err());
        assert_eq!(
            screen_bytes(&vec![b'x'; MAX_INPUT_BYTES])
                .unwrap()
                .content
                .len(),
            MAX_INPUT_BYTES
        );
        assert!(screen_bytes(&vec![b'x'; MAX_INPUT_BYTES + 1]).is_err());
        // 很短的用户名被 <user> 替换后变长；输入合法也不能越过输出上限。
        let mut expands = "/home/a ".repeat(MAX_INPUT_BYTES / 8);
        expands.truncate(MAX_INPUT_BYTES);
        assert!(screen_bytes(expands.as_bytes()).is_err());
    }
}
