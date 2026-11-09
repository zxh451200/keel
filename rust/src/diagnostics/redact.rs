//! 脱敏：日志、诊断事件、返回给界面的错误文案在输出前都先过这里。
//! 只用标准库，规则是“宁可多遮”：识别 `key=value` 形式的密钥、Bearer 令牌、URL 里的账号密码、
//! 邮箱、用户目录名、其他绝对路径与电话号码。它是规则匹配，不保证识别出所有敏感内容或业务名称
//! （需求文档 §4.2）。

pub const MASK: &str = "***";

const SECRET_KEYS: &[&str] = &[
    "password",
    "passwd",
    "pwd",
    "secret",
    "token",
    "api_key",
    "apikey",
    "access_key",
    "authorization",
];

pub fn redact(input: &str) -> String {
    let s = mask_url_userinfo(input);
    let s = mask_after(&s, "bearer ", &[], MASK);
    let s = mask_secret_values(&s);
    let s = mask_emails(&s);
    let s = mask_after(&s, "\\users\\", &['\\', '/', ':'], "<user>");
    let s = mask_after(&s, "/users/", &['\\', '/', ':'], "<user>");
    let s = mask_after(&s, "/home/", &['\\', '/', ':'], "<user>");
    let s = mask_abs_paths(&s);
    mask_phones(&s)
}

/// 值的结束位置：遇到空白或这些分隔符为止。
fn is_value_end(c: char) -> bool {
    c.is_whitespace() || matches!(c, ',' | ';' | '&' | '"' | '\'' | ')' | ']' | '}')
}

/// 在 `marker`（不区分大小写，只含 ASCII）之后，把接下来的一段替换成 `mask`。
/// 这一段到空白、引号、`stops` 里的字符或常见分隔符为止。
fn mask_after(s: &str, marker: &str, stops: &[char], mask: &str) -> String {
    let lower = s.to_ascii_lowercase();
    let mut out = String::with_capacity(s.len());
    let mut pos = 0;
    while let Some(found) = lower[pos..].find(marker) {
        let start = pos + found + marker.len();
        out.push_str(&s[pos..start]);
        let rest = &s[start..];
        let len = rest
            .find(|c: char| is_value_end(c) || stops.contains(&c))
            .unwrap_or(rest.len());
        if len > 0 {
            out.push_str(mask);
        }
        pos = start + len;
    }
    out.push_str(&s[pos..]);
    out
}

/// `password=xxx`、`token: xxx`、`"secret":"xxx"` 这类写法：遮住值。
fn mask_secret_values(s: &str) -> String {
    let lower = s.to_ascii_lowercase();
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let key_len = SECRET_KEYS
            .iter()
            .find(|k| lower[i..].starts_with(**k))
            .map(|k| k.len());
        if let Some(key_len) = key_len {
            // 键名后可以跟引号和空格，然后是 = 或 :，再是可选的引号。
            let mut k = i + key_len;
            while k < bytes.len() && matches!(bytes[k], b'"' | b'\'' | b' ') {
                k += 1;
            }
            if k < bytes.len() && matches!(bytes[k], b'=' | b':') {
                k += 1;
                while k < bytes.len() && matches!(bytes[k], b' ' | b'"' | b'\'') {
                    k += 1;
                }
                let rest = &s[k..];
                let len = rest.find(is_value_end).unwrap_or(rest.len());
                out.push_str(&s[i..k]);
                if len > 0 {
                    out.push_str(MASK);
                }
                i = k + len;
                continue;
            }
        }
        match s[i..].chars().next() {
            Some(ch) => {
                out.push(ch);
                i += ch.len_utf8();
            }
            None => break,
        }
    }
    out
}

/// `scheme://user:pass@host/...` 里的账号密码。
fn mask_url_userinfo(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut pos = 0;
    while let Some(found) = s[pos..].find("://") {
        let start = pos + found + 3;
        out.push_str(&s[pos..start]);
        let rest = &s[start..];
        let authority_len = rest
            .find(|c: char| c.is_whitespace() || matches!(c, '/' | '?' | '#' | '"' | '\''))
            .unwrap_or(rest.len());
        let authority = &rest[..authority_len];
        match authority.rfind('@') {
            Some(at) => {
                out.push_str(MASK);
                out.push_str(&authority[at..]);
            }
            None => out.push_str(authority),
        }
        pos = start + authority_len;
    }
    out.push_str(&s[pos..]);
    out
}

fn is_local_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'%' | b'+' | b'-')
}

fn is_domain_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-')
}

fn mask_emails(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'@' {
            let mut start = i;
            while start > last && is_local_char(bytes[start - 1]) {
                start -= 1;
            }
            let mut end = i + 1;
            while end < bytes.len() && is_domain_char(bytes[end]) {
                end += 1;
            }
            while end > i + 1 && bytes[end - 1] == b'.' {
                end -= 1;
            }
            if start < i && s[i + 1..end].contains('.') {
                out.push_str(&s[last..start]);
                out.push_str("***@***");
                last = end;
                i = end;
                continue;
            }
        }
        i += 1;
    }
    out.push_str(&s[last..]);
    out
}

/// 绝对路径（Windows 盘符或 POSIX 多段路径）。已经是 `<user>` 的已知路径保持原样，
/// 用户目录由上游规则先处理。URL 里的路径因为前面紧挨主机名，不会被当成 token 起点。
fn mask_abs_paths(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let boundary = i == 0 || {
            let prev = bytes[i - 1];
            prev.is_ascii_whitespace()
                || matches!(
                    prev,
                    b'"' | b'\'' | b'(' | b'[' | b'{' | b'=' | b',' | b';' | b':'
                )
        };
        if boundary {
            if let Some(len) = path_len(&s[i..]) {
                if !s[i..i + len].contains("<user>") {
                    out.push_str("<path>");
                    i += len;
                    continue;
                }
            }
        }
        match s[i..].chars().next() {
            Some(ch) => {
                out.push(ch);
                i += ch.len_utf8();
            }
            None => break,
        }
    }
    out
}

fn path_len(s: &str) -> Option<usize> {
    let bytes = s.as_bytes();
    let windows = bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/');
    // `//host` 是协议相对 URL，`/*` 是注释。
    let posix = bytes.len() >= 2 && bytes[0] == b'/' && !matches!(bytes[1], b'/' | b'*');
    if !windows && !posix {
        return None;
    }
    let lower_prefix = |prefix: &str| {
        s.len() >= prefix.len()
            && s.as_bytes()[..prefix.len()].eq_ignore_ascii_case(prefix.as_bytes())
    };
    if posix && (lower_prefix("/home/") || lower_prefix("/users/")) {
        return None;
    }
    let len = s
        .find(|c: char| {
            c.is_whitespace() || matches!(c, '"' | '\'' | ')' | ']' | '}' | ',' | ';' | '?' | '#')
        })
        .unwrap_or(s.len());
    let candidate = &s[..len];
    if posix {
        // 单段 `/x` 更像运算符或参数，不当作路径。
        if candidate.matches('/').count() < 2 {
            return None;
        }
    } else if !candidate.contains('\\') && !candidate.contains('/') {
        return None;
    }
    Some(len)
}

/// 电话号码：带 `+`、括号或分隔符的号码，以及中国大陆手机号形态。
fn mask_phones(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let boundary = i == 0 || {
            let prev = bytes[i - 1];
            prev.is_ascii_whitespace()
                || matches!(
                    prev,
                    b'"' | b'\'' | b'(' | b'[' | b'{' | b',' | b';' | b'=' | b':'
                )
        };
        if boundary {
            if let Some(len) = phone_len(&s[i..]) {
                out.push_str(MASK);
                i += len;
                continue;
            }
        }
        match s[i..].chars().next() {
            Some(ch) => {
                out.push(ch);
                i += ch.len_utf8();
            }
            None => break,
        }
    }
    out
}

fn phone_len(s: &str) -> Option<usize> {
    let bytes = s.as_bytes();
    let mut i = 0;
    let mut plus = false;
    let mut paren = false;
    let mut digits: Vec<u8> = Vec::new();
    let mut separators = 0;
    if i < bytes.len() && bytes[i] == b'+' {
        plus = true;
        i += 1;
    }
    if i + 1 < bytes.len() && bytes[i] == b'(' && bytes[i + 1].is_ascii_digit() {
        paren = true;
        i += 1;
    }
    loop {
        // 号码最长 15 位；超出即失败并立即退出，避免在超长数字串上退化为 O(n²)。
        if i >= bytes.len() || digits.len() > 15 || i > 64 {
            break;
        }
        match bytes[i] {
            b if b.is_ascii_digit() => {
                digits.push(b);
                i += 1;
            }
            b'(' if !digits.is_empty() && i + 1 < bytes.len() && bytes[i + 1].is_ascii_digit() => {
                paren = true;
                i += 1;
            }
            b')' if paren && i + 1 < bytes.len() && matches!(bytes[i + 1], b' ' | b'-') => {
                i += 1;
            }
            b'-' if i + 1 < bytes.len() && bytes[i + 1].is_ascii_digit() => {
                separators += 1;
                i += 1;
            }
            b' ' if i + 1 < bytes.len()
                && (bytes[i + 1].is_ascii_digit() || bytes[i + 1] == b'(') =>
            {
                separators += 1;
                i += 1;
            }
            _ => break,
        }
    }
    if !(7..=15).contains(&digits.len()) {
        return None;
    }
    if i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
        return None;
    }
    // `2026-11-06` 这类日期：四位数开头且只有 `-` 分隔。
    if !plus && !paren && separators >= 2 && digits.len() >= 8 && {
        let mut groups = s[..i].split(['-', ' ']);
        groups.next().is_some_and(|g| g.len() == 4)
    } {
        return None;
    }
    let mobile = digits.len() == 11 && digits[0] == b'1' && (b'3'..=b'9').contains(&digits[1]);
    // 真实号码最多 5 组；空格/短横线过多的长数字串是计数或日志，不是电话。
    let formatted = (plus || paren || separators > 0) && separators <= 4;
    if formatted || mobile {
        Some(i)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_key_value_secrets() {
        assert_eq!(redact("login password=hunter2 ok"), "login password=*** ok");
        assert_eq!(redact("Token: abc123, next"), "Token: ***, next");
        assert_eq!(redact(r#"{"secret":"s3cr3t"}"#), r#"{"secret":"***"}"#);
        assert_eq!(redact("api_key=AKIA1234&x=1"), "api_key=***&x=1");
    }

    #[test]
    fn masks_bearer_tokens() {
        // Authorization 本身也是密钥名，两条规则叠加后整行值都被遮住。
        assert_eq!(
            redact("Authorization: Bearer eyJabc.def"),
            "Authorization: *** ***"
        );
        assert_eq!(redact("bearer SECRETVALUE"), "bearer ***");
    }

    #[test]
    fn masks_credentials_in_urls_but_keeps_host() {
        let out = redact("connect postgres://admin:p4ss@db.local:5432/app failed");
        assert_eq!(out, "connect postgres://***@db.local:5432/app failed");
        assert_eq!(
            redact("see https://example.com/a?b=1"),
            "see https://example.com/a?b=1"
        );
    }

    #[test]
    fn masks_emails() {
        assert_eq!(
            redact("mail alice.b@corp.example.com now"),
            "mail ***@*** now"
        );
        assert_eq!(redact("not an email: @ or a@b"), "not an email: @ or a@b");
    }

    #[test]
    fn masks_user_directory_names() {
        assert_eq!(
            redact(r"C:\Users\alice\Documents\x.csv"),
            r"C:\Users\<user>\Documents\x.csv"
        );
        assert_eq!(
            redact("/home/bob/.config/keel"),
            "/home/<user>/.config/keel"
        );
        assert_eq!(redact("/Users/carol/Library"), "/Users/<user>/Library");
    }

    #[test]
    fn leaves_ordinary_text_alone_and_handles_unicode() {
        assert_eq!(redact("数据库打开失败 code=7"), "数据库打开失败 code=7");
        assert_eq!(
            redact("密码 password=口令值 结束"),
            "密码 password=*** 结束"
        );
        assert_eq!(redact(""), "");
    }

    #[test]
    fn masks_phone_numbers() {
        assert_eq!(redact("call +86 138 1234 5678 now"), "call *** now");
        assert_eq!(redact("tel 138-1234-5678"), "tel ***");
        assert_eq!(redact("fax (010) 8888-1234"), "fax ***");
        assert_eq!(redact("mobile 13812345678"), "mobile ***");
        assert_eq!(redact("intl +1 (555) 123-4567"), "intl ***");
    }

    #[test]
    fn keeps_dates_versions_and_plain_numbers() {
        assert_eq!(redact("at 2026-11-06"), "at 2026-11-06");
        assert_eq!(redact("at 2026-11-06 10:00"), "at 2026-11-06 10:00");
        assert_eq!(redact("v1.2.3"), "v1.2.3");
        assert_eq!(redact("count 12345"), "count 12345");
        assert_eq!(redact("id=1234567890123456"), "id=1234567890123456");
    }

    #[test]
    fn masks_project_absolute_paths() {
        assert_eq!(redact(r"db D:\work\keel\data\keel.db"), "db <path>");
        assert_eq!(redact("db /opt/keel/data/keel.db"), "db <path>");
        assert_eq!(
            redact(r#"{"config":"C:/work/keel/keel.json"}"#),
            r#"{"config":"<path>"}"#
        );
    }

    #[test]
    fn keeps_user_directories_urls_and_relative_paths() {
        assert_eq!(
            redact(r"C:\Users\alice\Documents\x.csv"),
            r"C:\Users\<user>\Documents\x.csv"
        );
        assert_eq!(redact("/home/bob/.config"), "/home/<user>/.config");
        assert_eq!(
            redact("see https://example.com/a/b?c=1"),
            "see https://example.com/a/b?c=1"
        );
        assert_eq!(redact("open src/main.rs"), "open src/main.rs");
        assert_eq!(redact("a/b"), "a/b");
    }

    #[test]
    fn no_sample_secret_survives_a_mixed_line() {
        let line = "user alice.b@corp.example.com password=hunter2 token=abc123 \
                    db postgres://admin:p4ss@db.local:5432/app \
                    path C:\\work\\keel\\data\\keel.db phone +86 138 1234 5678";
        let out = redact(line);
        for leaked in [
            "hunter2",
            "abc123",
            "p4ss",
            "alice.b",
            "corp.example.com",
            r"C:\work",
            "138 1234",
        ] {
            assert!(!out.contains(leaked), "leaked {leaked} in {out}");
        }
    }

    #[test]
    fn long_digit_runs_do_not_degrade() {
        // 日志里可能出现超长数字串；号码扫描必须有界，否则退化为 O(n²)。
        let input = "1 ".repeat(100_000);
        let out = redact(&input);
        assert_eq!(out.len(), input.len());
    }
}
