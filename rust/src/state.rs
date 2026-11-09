//! 进程级状态：数据库连接池与首次实际启动恢复结果。

use crate::errors::KeelError;
use sqlx::SqlitePool;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

static POOL: OnceLock<SqlitePool> = OnceLock::new();
static DB_PATH: OnceLock<PathBuf> = OnceLock::new();
static STARTUP_RESTORE: OnceLock<StartupRestoreResult> = OnceLock::new();

/// 仅缓存恢复结论和安全定位信息，不保留备份名、路径或原始错误。
pub(crate) enum StartupRestoreResult {
    Restored,
    Failed {
        error_code: &'static str,
        correlation_id: String,
    },
}

/// 只记录首次实际尝试；无待恢复项时不调用，不占用缓存。
pub(crate) fn record_startup_restore(result: StartupRestoreResult) {
    let _ = STARTUP_RESTORE.set(result);
}

/// 借用读取，不消费结果，也不将默认的 none 写入缓存。
pub(crate) fn startup_restore() -> Option<&'static StartupRestoreResult> {
    STARTUP_RESTORE.get()
}

/// 记下数据库文件路径（备份和恢复要用）。只有第一次生效。
pub fn set_db_path(path: &Path) {
    let _ = DB_PATH.set(path.to_path_buf());
}

pub fn db_path() -> Result<&'static Path, KeelError> {
    DB_PATH
        .get()
        .map(PathBuf::as_path)
        .ok_or(KeelError::Uninitialized)
}

/// 设置连接池。已经设置过则忽略（只有第一次生效）。
pub fn set_pool(pool: SqlitePool) {
    let _ = POOL.set(pool);
}

/// 取连接池；数据库还没初始化时返回 `KEEL-UNINITIALIZED`。
pub fn pool() -> Result<&'static SqlitePool, KeelError> {
    POOL.get().ok_or(KeelError::Uninitialized)
}
