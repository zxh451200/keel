//! 统一错误。界面只按 `code()` 判断，不解析 message。
//! 新增错误码前先在 AGENTS.md §6 登记；那里列出的码对应功能还没建时，这里不提前定义。

use std::fmt;

#[derive(Debug)]
pub enum KeelError {
    /// 输入参数不合法。
    Validation(String),
    /// 记录或文件不存在。
    NotFound,
    /// 文件读写失败。
    Io(std::io::Error),
    /// 非预期的内部状态。细节只进诊断，界面只显示通用提示。
    Internal(String),
    /// 用户取消了操作。
    Cancelled,
    /// 依赖的资源（如数据库）还没初始化。
    Uninitialized,
    /// 数据库操作失败。具体原因只进日志，界面只显示通用提示。
    Db(sqlx::Error),
    /// 数据库迁移失败。
    DbMigration(sqlx::migrate::MigrateError),
    /// 备份失败（含迁移前的自动备份）。
    Backup(String),
    /// 外部配置导入失败。
    Import(String),
    /// 唯一约束冲突，如用户名已存在。
    Duplicate,
    /// 当前用户没有权限做这件事。
    PermissionDenied(String),
    /// 登录口令不正确或尚未设置（不区分原因，避免探测）。
    Auth,
}

impl KeelError {
    pub fn code(&self) -> &'static str {
        match self {
            KeelError::Validation(_) => "KEEL-VALIDATION",
            KeelError::NotFound => "KEEL-NOT-FOUND",
            KeelError::Io(_) => "KEEL-IO",
            KeelError::Internal(_) => "KEEL-INTERNAL",
            KeelError::Cancelled => "KEEL-CANCELLED",
            KeelError::Uninitialized => "KEEL-UNINITIALIZED",
            KeelError::Db(_) => "KEEL-DB",
            KeelError::DbMigration(_) => "KEEL-DB-MIGRATION",
            KeelError::Backup(_) => "KEEL-BACKUP",
            KeelError::Import(_) => "KEEL-IMPORT",
            KeelError::Duplicate => "KEEL-DUPLICATE",
            KeelError::PermissionDenied(_) => "KEEL-PERMISSION",
            KeelError::Auth => "KEEL-AUTH",
        }
    }

    /// 非预期状态：记成内部错误，细节不要拼进给用户的文案。
    pub fn internal(detail: impl fmt::Display) -> Self {
        KeelError::Internal(detail.to_string())
    }

    /// 技术详情：沿 `source()` 链把底层原因拼起来，只进日志和诊断，不当界面文案。
    /// 调用方要先过 `redact`；这里只限制长度，防止单条错误撑爆日志。
    pub fn detail(&self) -> String {
        const MAX: usize = 600;
        let mut out = self.to_string();
        let mut cause = std::error::Error::source(self);
        while let Some(e) = cause {
            out.push_str(" <- ");
            out.push_str(&e.to_string());
            if out.len() >= MAX {
                break;
            }
            cause = e.source();
        }
        if out.len() > MAX {
            let mut end = MAX;
            while !out.is_char_boundary(end) {
                end -= 1;
            }
            out.truncate(end);
            out.push('…');
        }
        out
    }
}

impl fmt::Display for KeelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            KeelError::Validation(msg) => write!(f, "输入无效：{msg}"),
            KeelError::NotFound => write!(f, "记录不存在"),
            KeelError::Io(_) => write!(f, "文件读写失败"),
            KeelError::Internal(msg) => write!(f, "内部错误：{msg}"),
            KeelError::Cancelled => write!(f, "操作已取消"),
            KeelError::Uninitialized => write!(f, "尚未初始化"),
            KeelError::Db(_) => write!(f, "数据库错误"),
            KeelError::DbMigration(_) => write!(f, "数据库迁移失败"),
            KeelError::Backup(msg) => write!(f, "备份失败：{msg}"),
            KeelError::Import(msg) => write!(f, "导入失败：{msg}"),
            KeelError::Duplicate => write!(f, "记录已存在"),
            KeelError::PermissionDenied(what) => write!(f, "没有权限：{what}"),
            KeelError::Auth => write!(f, "认证失败"),
        }
    }
}

impl std::error::Error for KeelError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            KeelError::Io(e) => Some(e),
            KeelError::Db(e) => Some(e),
            KeelError::DbMigration(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for KeelError {
    fn from(e: std::io::Error) -> Self {
        if e.kind() == std::io::ErrorKind::NotFound {
            KeelError::NotFound
        } else {
            KeelError::Io(e)
        }
    }
}

impl From<sqlx::Error> for KeelError {
    fn from(e: sqlx::Error) -> Self {
        // 唯一约束冲突转成业务错误，其余归为 KEEL-DB。
        if let sqlx::Error::Database(db) = &e
            && db.is_unique_violation()
        {
            return KeelError::Duplicate;
        }
        KeelError::Db(e)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_variant_has_its_own_code() {
        let codes = [
            KeelError::Validation(String::new()).code(),
            KeelError::NotFound.code(),
            KeelError::Io(std::io::Error::other("x")).code(),
            KeelError::Internal(String::new()).code(),
            KeelError::Cancelled.code(),
            KeelError::Uninitialized.code(),
            KeelError::Db(sqlx::Error::PoolClosed).code(),
            KeelError::Backup(String::new()).code(),
            KeelError::Import(String::new()).code(),
            KeelError::Duplicate.code(),
            KeelError::PermissionDenied(String::new()).code(),
            KeelError::Auth.code(),
        ];
        let unique: std::collections::HashSet<_> = codes.iter().collect();
        assert_eq!(unique.len(), codes.len());
        assert!(codes.iter().all(|c| c.starts_with("KEEL-")));
    }

    #[test]
    fn missing_file_becomes_not_found() {
        let e: KeelError = std::io::Error::from(std::io::ErrorKind::NotFound).into();
        assert_eq!(e.code(), "KEEL-NOT-FOUND");
    }

    #[test]
    fn detail_includes_the_cause_but_display_does_not() {
        let e = KeelError::Io(std::io::Error::other("disk full"));
        assert_eq!(e.to_string(), "文件读写失败");
        assert!(e.detail().contains("disk full"));
    }

    #[test]
    fn detail_is_length_limited() {
        let e = KeelError::Validation("长".repeat(5000));
        assert!(e.detail().chars().count() <= 601);
    }
}
