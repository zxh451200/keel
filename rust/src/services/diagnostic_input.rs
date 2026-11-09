//! 外部诊断准备服务。仅内部使用；公开 API/Dart 接线须另行正常生成桥接。
//! 使用 diagnostics.export，不导入设置；缓存只保存完整脱敏快照。

use crate::diagnostics::external_input::{self, ScreenedDiagnostic, MAX_INPUT_BYTES};
use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::{access, diagnostic_pack};
use sqlx::SqlitePool;
use std::path::Path;

pub(crate) struct DiagnosticInputPreview {
    pub(crate) preview_id: String,
    pub(crate) content: String,
    pub(crate) sensitive_categories: Vec<String>,
}

fn check_current(owner: &access::CurrentUser) -> Result<(), KeelError> {
    let current = access::current()?;
    if current != *owner || !current.role.allows(Permission::DiagnosticsExport) {
        return Err(KeelError::PermissionDenied(
            "diagnostics.preview.owner".into(),
        ));
    }
    Ok(())
}

async fn prepare_with(
    pool: &SqlitePool,
    owner: access::CurrentUser,
    read: impl FnOnce() -> Result<ScreenedDiagnostic, KeelError> + Send + 'static,
) -> Result<DiagnosticInputPreview, KeelError> {
    let worker_owner = owner.clone();
    let result = tokio::task::spawn_blocking(move || {
        // 阻塞任务排队期间可能切换身份；在受限文件读取前重新检查。
        check_current(&worker_owner)?;
        read()
    })
    .await;
    let current = access::require(pool, Permission::DiagnosticsExport).await?;
    if current != owner {
        return Err(KeelError::PermissionDenied(
            "diagnostics.preview.owner".into(),
        ));
    }
    let screened =
        result.map_err(|_| KeelError::internal("diagnostic input worker unavailable"))??;
    // 注册函数在缓存锁内再检查身份；没有 await/文件读取后才返回原始路径的步骤。
    let preview_id = diagnostic_pack::register_redacted_snapshot(&owner, &screened.content)?;
    Ok(DiagnosticInputPreview {
        preview_id,
        content: screened.content,
        sensitive_categories: screened.sensitive_categories,
    })
}

pub(crate) async fn prepare_text(
    pool: &SqlitePool,
    text: &str,
) -> Result<DiagnosticInputPreview, KeelError> {
    let owner = access::require(pool, Permission::DiagnosticsExport).await?;
    if text.len() > MAX_INPUT_BYTES {
        return Err(KeelError::Validation("外部诊断文本超过 1 MiB".into()));
    }
    let text = text.to_owned();
    prepare_with(pool, owner, move || {
        external_input::screen_bytes(text.as_bytes())
    })
    .await
}

pub(crate) async fn prepare_file(
    pool: &SqlitePool,
    path: &Path,
) -> Result<DiagnosticInputPreview, KeelError> {
    let owner = access::require(pool, Permission::DiagnosticsExport).await?;
    let path = path.to_owned();
    prepare_with(pool, owner, move || external_input::screen_file(&path)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::permissions::Role;

    // 独立子进程隔离 CURRENT，避免与其他库内权限测试并行互扰。
    #[tokio::test]
    async fn frozen_file_snapshot_owner_permission_and_consumption() {
        const CHILD: &str = "KEEL_DIAGNOSTIC_INPUT_TEST_CHILD";
        if std::env::var_os(CHILD).is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "services::diagnostic_input::tests::frozen_file_snapshot_owner_permission_and_consumption", "--nocapture"])
                .env(CHILD, "1")
                .status()
                .unwrap();
            assert!(status.success());
            return;
        }
        let dir = std::env::temp_dir().join(format!(
            "keel-external-diagnostic-{}-{}",
            std::process::id(),
            crate::diagnostics::correlation::new_correlation_id()
        ));
        std::fs::create_dir(&dir).unwrap();
        let db = dir.join("main.db");
        let pool = crate::data::open(&db).await.unwrap();
        let previous = access::current().ok();
        access::init(&pool).await.unwrap();
        let owner = access::current().unwrap();
        let source = dir.join("external.txt");
        let raw = format!("{}\npassword=private\nEND", "长文本\n".repeat(20_000));
        std::fs::write(&source, &raw).unwrap();
        let preview = prepare_file(&pool, &source).await.unwrap();
        assert_eq!(preview.content, crate::diagnostics::redact::redact(&raw));
        assert!(preview.content.ends_with("END"));
        assert!(preview
            .sensitive_categories
            .contains(&"password-or-secret".into()));
        std::fs::write(&source, "replacement password=new-secret").unwrap();
        std::fs::remove_file(&source).unwrap();
        for user in [
            access::CurrentUser {
                name: "other".into(),
                role: owner.role,
            },
            access::CurrentUser {
                name: owner.name.clone(),
                role: Role::Operator,
            },
            access::CurrentUser {
                name: owner.name.clone(),
                role: Role::Viewer,
            },
        ] {
            access::set_current(user);
            assert!(check_current(&owner).is_err());
            assert!(
                diagnostic_pack::export_prepared(&pool, &db, &preview.preview_id)
                    .await
                    .is_err()
            );
        }
        assert!(prepare_file(&pool, &source).await.is_err());
        assert!(prepare_text(&pool, "{\"version\":999}").await.is_err());
        access::set_current(owner.clone());
        let path = diagnostic_pack::export_prepared(&pool, &db, &preview.preview_id)
            .await
            .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), preview.content.as_bytes());
        assert!(
            diagnostic_pack::export_prepared(&pool, &db, &preview.preview_id)
                .await
                .is_err()
        );
        let json = prepare_text(&pool, "{\"version\":999}").await.unwrap();
        assert_eq!(json.content, "{\"version\":999}");
        diagnostic_pack::export_prepared(&pool, &db, &json.preview_id)
            .await
            .unwrap();
        let mut ids = Vec::new();
        for _ in 0..7 {
            ids.push(
                prepare_text(&pool, "bounded snapshot")
                    .await
                    .unwrap()
                    .preview_id,
            );
        }
        assert!(diagnostic_pack::export_prepared(&pool, &db, &ids[0])
            .await
            .is_err());
        diagnostic_pack::export_prepared(&pool, &db, &ids[6])
            .await
            .unwrap();
        // 排队后的身份变化必须在读取前拒绝，读取闭包不得执行。
        let read_started = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_started = read_started.clone();
        let stale_owner = access::CurrentUser {
            name: "stale-owner".into(),
            role: Role::Admin,
        };
        let stale = prepare_with(&pool, stale_owner, move || {
            worker_started.store(true, std::sync::atomic::Ordering::SeqCst);
            external_input::screen_bytes(b"must not read")
        })
        .await;
        assert!(matches!(stale, Err(KeelError::PermissionDenied(_))));
        assert!(!read_started.load(std::sync::atomic::Ordering::SeqCst));
        // 读取结束后切换为另一个同角色用户，必须拒绝注册。
        let switched = prepare_with(&pool, owner.clone(), move || {
            access::set_current(access::CurrentUser {
                name: "changed".into(),
                role: Role::Admin,
            });
            external_input::screen_bytes(b"private snapshot")
        })
        .await;
        assert!(matches!(switched, Err(KeelError::PermissionDenied(_))));
        access::set_current(previous.unwrap_or(owner));
        pool.close().await;
        std::fs::remove_dir_all(dir).unwrap();
    }
}
