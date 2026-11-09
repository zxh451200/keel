//! 备份与恢复。界面只能使用备份的"名字"，不能传路径。

use crate::api::error::ApiError;
use crate::services::backup;
use crate::state;

pub struct BackupInfo {
    /// 形如 `keel-1730000000000.db`
    pub name: String,
    pub size_bytes: i64,
    /// UTC epoch 毫秒
    pub modified_at: i64,
}

fn info(file: backup::BackupFile) -> BackupInfo {
    BackupInfo {
        name: file.name,
        size_bytes: i64::try_from(file.size_bytes).unwrap_or(i64::MAX),
        modified_at: file.modified_ms,
    }
}

/// 立即备份。需要"创建备份"权限（`KEEL-PERMISSION`）。
pub async fn create_backup() -> Result<BackupInfo, ApiError> {
    Ok(info(
        backup::create(state::pool()?, state::db_path()?).await?,
    ))
}

/// 备份列表，最新的在前。
pub async fn list_backups() -> Result<Vec<BackupInfo>, ApiError> {
    Ok(backup::list(state::db_path()?)?
        .into_iter()
        .map(info)
        .collect())
}

/// 登记一次恢复：校验备份后写标记，**下次启动时**才真正替换数据库，旧数据库会保留。
/// 需要"恢复"权限（`KEEL-PERMISSION`）。
pub async fn schedule_restore(name: String) -> Result<(), ApiError> {
    backup::schedule_restore(state::pool()?, state::db_path()?, &name).await?;
    Ok(())
}

/// 取消已登记的恢复，需要"恢复"权限（`KEEL-PERMISSION`）。
/// 无标记时幂等；实际取消写审计。删除后审计失败会明确报告已取消。
pub async fn cancel_scheduled_restore() -> Result<(), ApiError> {
    backup::cancel_restore(state::pool()?, state::db_path()?).await?;
    Ok(())
}

/// 已登记、等待下次启动执行的恢复（备份名）。
pub async fn pending_restore() -> Result<Option<String>, ApiError> {
    Ok(backup::pending_restore(state::db_path()?))
}
