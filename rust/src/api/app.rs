//! 应用级入口：数据库初始化与状态。

use crate::api::error::ApiError;
use crate::{services, state};

/// 启动时调用一次：在用户数据目录打开（必要时创建）数据库并迁移。
/// 重复调用是安全的，已经初始化过就直接返回。
/// 失败时错误会写入日志和诊断中心；应用仍可启动，数据库相关页面会显示错误。
pub async fn init_database() -> Result<(), ApiError> {
    services::startup::initialize().await.map_err(Into::into)
}

/// 状态栏用：程序版本和数据库是否已就绪。
pub struct AppStatus {
    pub version: String,
    pub database_ready: bool,
}

#[flutter_rust_bridge::frb(sync)]
pub fn app_status() -> AppStatus {
    AppStatus {
        version: env!("CARGO_PKG_VERSION").to_string(),
        database_ready: state::pool().is_ok(),
    }
}

/// 本进程首次实际启动恢复的结果，独立于数据库是否就绪。
/// 不含原始错误、备份名或路径；失败时可用错误码与关联 ID 定位诊断事件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartupRestoreStatus {
    /// 仅为 "none" / "restored" / "failed"。
    pub outcome: String,
    pub error_code: Option<String>,
    pub correlation_id: Option<String>,
}

/// 可在初始化前后重复读取，不消费缓存；尚无实际恢复尝试时返回 none。
#[flutter_rust_bridge::frb(sync)]
pub fn startup_restore_status() -> StartupRestoreStatus {
    let (outcome, error_code, correlation_id) = match state::startup_restore() {
        None => ("none", None, None),
        Some(state::StartupRestoreResult::Restored) => ("restored", None, None),
        Some(state::StartupRestoreResult::Failed {
            error_code,
            correlation_id,
        }) => (
            "failed",
            Some((*error_code).to_string()),
            Some(correlation_id.clone()),
        ),
    };
    StartupRestoreStatus {
        outcome: outcome.to_string(),
        error_code,
        correlation_id,
    }
}
