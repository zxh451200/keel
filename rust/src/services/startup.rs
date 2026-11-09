//! 串行启动/重试：迁移、用户与启动审计都完成后才发布连接池。

use crate::diagnostics::{
    correlation::new_correlation_id,
    events::{self, Level},
    redact::redact,
};
use crate::errors::KeelError;
use crate::services::{access, audit, backup, settings};
use crate::{config, data, state};
use tokio::sync::Mutex;

// 异步锁不阻塞 FRB runtime 的工作线程，覆盖恢复文件操作到发布池的整个过程。
static INITIALIZING: Mutex<()> = Mutex::const_new(());

pub async fn initialize() -> Result<(), KeelError> {
    let _guard = INITIALIZING.lock().await;
    if state::pool().is_ok() {
        return Ok(());
    }
    let dir = config::data_dir()?;
    std::fs::create_dir_all(&dir)?;
    let db_path = dir.join("keel.db");
    state::set_db_path(&db_path);
    // 恢复失败仍保留原库启动，错误会进入诊断中心。
    match backup::apply_pending(&db_path) {
        Ok(Some(_)) => {
            state::record_startup_restore(state::StartupRestoreResult::Restored);
            tracing::info!("database restored from backup");
        }
        Ok(None) => {}
        Err(error) => {
            let correlation_id = new_correlation_id();
            state::record_startup_restore(state::StartupRestoreResult::Failed {
                error_code: error.code(),
                correlation_id: correlation_id.clone(),
            });
            let detail = redact(&error.detail());
            tracing::error!(code = error.code(), correlation_id = %correlation_id, "{detail}");
            events::record(
                Level::Error,
                "startup",
                error.code(),
                &correlation_id,
                &detail,
            );
        }
    }
    let pool = data::open(&db_path).await?;
    let prepared = async {
        crate::services::audit_export_history::recover_on_startup(&pool).await?;
        let user = access::load_default(&pool).await?;
        // 登录保护开启时不发布当前用户，界面先停在登录页；签名后才能使用。
        let locked = crate::services::auth::required(&pool).await?;
        // 不依赖尚未发布的全局当前用户；SQL 仍由 data 层执行。
        data::audit::insert(
            &pool,
            audit::now_ms(),
            &user.name,
            "app.start",
            "keel",
            if locked { "locked" } else { "ok" },
            "",
        )
        .await?;
        Ok::<_, KeelError>((user, locked))
    }
    .await;
    let (user, locked) = match prepared {
        Ok(prepared) => prepared,
        Err(error) => {
            pool.close().await;
            return Err(error);
        }
    };
    // 所有必要准备成功后同步发布；失败或被登录保护拦住时不发布当前用户。
    if !locked {
        access::set_current(user);
    }
    state::set_pool(pool.clone());
    // 发布后再重放：与并发 save 共用锁。早于发布的保存由本次重放覆盖，
    // 晚于发布的保存自行取得全局池，避免「重放完成但尚未发布」间隙漏补写。
    // 此后只有尽力补写，不会将已就绪的数据库重新报告为启动失败。
    if let Err(error) = settings::flush_pending(&pool).await {
        settings::warn_pending(&error);
    }
    tracing::info!("database ready");
    Ok(())
}
