//! 角色与权限。权限不能只靠隐藏菜单：敏感操作在 Rust 边界再校验（需求文档 §1.5）。
//! 这是应用内的权限，不是对本机管理员的安全隔离（AGENTS.md §11）。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Permission {
    /// 查看审计日志
    AuditRead,
    /// 导出审计日志
    AuditExport,
    /// 创建和管理用户
    UserManage,
    /// 手动创建数据库备份
    BackupCreate,
    /// 从备份恢复（会替换当前数据库，影响最大）
    BackupRestore,
    /// 导出诊断包
    DiagnosticsExport,
    /// 导入外部配置并修改本机偏好
    SettingsImport,
    /// 维护往来单位（参考实体，非底座业务范围）
    CustomerManage,
}

impl Permission {
    /// 给界面和审计用的稳定名字。
    pub fn as_str(self) -> &'static str {
        match self {
            Permission::AuditRead => "audit.read",
            Permission::AuditExport => "audit.export",
            Permission::UserManage => "users.manage",
            Permission::BackupCreate => "backup.create",
            Permission::BackupRestore => "backup.restore",
            Permission::DiagnosticsExport => "diagnostics.export",
            Permission::SettingsImport => "settings.import",
            Permission::CustomerManage => "customers.manage",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Admin,
    Operator,
    Viewer,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Admin => "admin",
            Role::Operator => "operator",
            Role::Viewer => "viewer",
        }
    }

    pub fn parse(s: &str) -> Option<Role> {
        match s {
            "admin" => Some(Role::Admin),
            "operator" => Some(Role::Operator),
            "viewer" => Some(Role::Viewer),
            _ => None,
        }
    }

    pub fn allows(self, permission: Permission) -> bool {
        match permission {
            Permission::AuditRead => true,
            Permission::UserManage | Permission::BackupRestore => self == Role::Admin,
            Permission::BackupCreate
            | Permission::AuditExport
            | Permission::DiagnosticsExport
            | Permission::SettingsImport
            | Permission::CustomerManage => self != Role::Viewer,
        }
    }

    pub fn permissions(self) -> Vec<Permission> {
        [
            Permission::AuditRead,
            Permission::AuditExport,
            Permission::UserManage,
            Permission::BackupCreate,
            Permission::BackupRestore,
            Permission::DiagnosticsExport,
            Permission::SettingsImport,
            Permission::CustomerManage,
        ]
        .into_iter()
        .filter(|p| self.allows(*p))
        .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn everyone_can_read_audit_but_only_admin_manages_users() {
        for role in [Role::Admin, Role::Operator, Role::Viewer] {
            assert!(role.allows(Permission::AuditRead));
        }
        assert!(Role::Admin.allows(Permission::UserManage));
        assert!(!Role::Operator.allows(Permission::UserManage));
        assert!(!Role::Viewer.allows(Permission::UserManage));
    }

    #[test]
    fn backup_and_diagnostics_permissions_by_role() {
        assert!(Role::Admin.allows(Permission::BackupRestore));
        assert!(!Role::Operator.allows(Permission::BackupRestore));
        assert!(Role::Operator.allows(Permission::BackupCreate));
        assert!(Role::Operator.allows(Permission::DiagnosticsExport));
        assert!(Role::Operator.allows(Permission::SettingsImport));
        assert!(Role::Admin.allows(Permission::AuditExport));
        assert!(Role::Operator.allows(Permission::AuditExport));
        assert!(!Role::Viewer.allows(Permission::BackupCreate));
        assert!(!Role::Viewer.allows(Permission::DiagnosticsExport));
        assert!(!Role::Viewer.allows(Permission::SettingsImport));
        assert!(!Role::Viewer.allows(Permission::AuditExport));
    }

    #[test]
    fn permissions_list_matches_allows() {
        assert_eq!(Role::Admin.permissions().len(), 8);
        assert_eq!(Role::Viewer.permissions(), vec![Permission::AuditRead]);
        assert!(Role::Operator.allows(Permission::CustomerManage));
        assert!(!Role::Viewer.allows(Permission::CustomerManage));
    }

    #[test]
    fn role_names_round_trip() {
        for role in [Role::Admin, Role::Operator, Role::Viewer] {
            assert_eq!(Role::parse(role.as_str()), Some(role));
        }
        assert_eq!(Role::parse("root"), None);
    }
}
