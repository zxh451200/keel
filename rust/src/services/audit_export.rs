//! 审计 CSV 后台导出。操作句柄终态五分钟后回收；历史另存于独立表。
//! 另存副本只接受内存任务 ID；重启只恢复历史状态，不重放快照或断点续传。

use crate::api::audit::{AuditExportStatus, AuditQuery};
use crate::data::audit::{self as audit_data, ExportSnapshot, ListParams};
use crate::diagnostics::{
    correlation::new_correlation_id,
    events::{self, Level},
};
use crate::domain::permissions::Permission;
use crate::errors::KeelError;
use crate::services::{access, audit};
use sqlx::SqlitePool;
use std::collections::{hash_map::RandomState, HashMap};
use std::fs::{self, File, OpenOptions};
use std::hash::{BuildHasher, DefaultHasher, Hasher};
use std::io::{BufWriter, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

pub const MAX_ROWS: u32 = 100_000;
pub const MAX_BYTES: u64 = 64 * 1024 * 1024;
const MAX_TASKS: usize = 6;
const TTL: Duration = Duration::from_secs(300);

struct Task {
    owner: access::CurrentUser,
    created: Instant,
    status: AuditExportStatus,
    cancel: bool,
    finished: Option<Instant>,
    source: Option<SourceStamp>,
}

#[derive(Clone)]
struct SourceStamp {
    metadata: fs::Metadata,
    #[cfg(windows)]
    identity: (u32, u32, u32),
    // 仅检测普通损坏/变化，不是密码学完整性保证。
    hash: u64,
}

impl SourceStamp {
    fn from_file(file: &File, hash: u64) -> Result<Self, KeelError> {
        Ok(Self {
            metadata: file.metadata().map_err(KeelError::Io)?,
            #[cfg(windows)]
            identity: windows_identity(file)?,
            hash,
        })
    }
}

type SharedTask = Arc<Mutex<Task>>;

fn lock<T>(value: &Mutex<T>) -> MutexGuard<'_, T> {
    value.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Default)]
struct Registry {
    tasks: HashMap<String, SharedTask>,
}

impl Registry {
    /// Read-only snapshot: no TTL renewal, file probing, worker or audit writes.
    /// Creation order descending; task ID breaks ties independently of HashMap order.
    fn list_owned(&self, owner: &access::CurrentUser, now: Instant) -> Vec<AuditExportStatus> {
        let mut items: Vec<_> = self
            .tasks
            .values()
            .filter_map(|shared| {
                let task = lock(shared);
                if &task.owner != owner
                    || task
                        .finished
                        .is_some_and(|at| now.saturating_duration_since(at) >= TTL)
                {
                    return None;
                }
                Some((task.created, task.status.clone()))
            })
            .collect();
        items.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.task_id.cmp(&b.1.task_id)));
        items.into_iter().map(|(_, status)| status).collect()
    }

    fn prune(&mut self, now: Instant) {
        self.tasks.retain(|_, task| {
            lock(task)
                .finished
                .is_none_or(|at| now.saturating_duration_since(at) < TTL)
        });
    }

    fn reserve(&mut self, owner: access::CurrentUser) -> Result<SharedTask, KeelError> {
        self.prune(Instant::now());
        if self.tasks.len() >= MAX_TASKS
            || self.tasks.values().any(|task| {
                let task = lock(task);
                task.owner.name == owner.name && task.status.phase == "running"
            })
        {
            return Err(KeelError::Validation("导出任务已达上限，请稍后重试".into()));
        }
        let nonce = new_correlation_id();
        let id = format!("E{:016x}-{}", RandomState::new().hash_one(&nonce), nonce);
        let task = Arc::new(Mutex::new(Task {
            owner,
            created: Instant::now(),
            status: AuditExportStatus {
                task_id: id.clone(),
                phase: "running".into(),
                completed_rows: 0,
                total_rows: 0,
                output_path: None,
                error_code: None,
            },
            cancel: false,
            finished: None,
            source: None,
        }));
        self.tasks.insert(id, task.clone());
        Ok(task)
    }
}

/// 仅用于集成测试：清空进程内注册表，模拟新进程。Release 构建不提供。
#[cfg(debug_assertions)]
pub fn reset_for_tests() {
    registry().lock().unwrap().tasks.clear();
}

fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}

#[cfg(debug_assertions)]
type WorkerPause = (
    tokio::sync::oneshot::Sender<()>,
    tokio::sync::oneshot::Receiver<()>,
);

#[cfg(debug_assertions)]
fn worker_pause() -> &'static Mutex<Option<WorkerPause>> {
    static PAUSE: OnceLock<Mutex<Option<WorkerPause>>> = OnceLock::new();
    PAUSE.get_or_init(|| Mutex::new(None))
}

#[cfg(debug_assertions)]
pub fn pause_next_worker_for_tests() -> (
    tokio::sync::oneshot::Receiver<()>,
    tokio::sync::oneshot::Sender<()>,
) {
    let (arrive, arrived) = tokio::sync::oneshot::channel();
    let (release, released) = tokio::sync::oneshot::channel();
    *lock(worker_pause()) = Some((arrive, released));
    (arrived, release)
}

fn validate(query: AuditQuery) -> Result<ListParams, KeelError> {
    audit::validate_date_range(query.start_at_ms, query.end_at_ms_exclusive)?;
    if query.keyword.len() > 1024 || query.keyword.chars().any(char::is_control) {
        return Err(KeelError::Validation(
            "审计筛选或排序无效（关键字最多 1024 UTF-8 字节）".into(),
        ));
    }
    let sort: Vec<audit_data::SortKey> = query
        .sort
        .into_iter()
        .map(|key| audit_data::SortKey {
            field: key.field,
            descending: key.descending,
        })
        .collect();
    audit_data::validate_sort(&sort)?;
    Ok(ListParams {
        start_at_ms: query.start_at_ms,
        end_at_ms_exclusive: query.end_at_ms_exclusive,
        keyword: query.keyword,
        sort,
        page: 1,
        page_size: 200,
    })
}

fn diagnostic(code: &str, id: &str, summary: &str) {
    tracing::warn!(code, correlation_id = id, "{summary}");
    events::record(Level::Warn, "audit.export", code, id, summary);
}

async fn record(pool: &SqlitePool, task: &SharedTask, action: &str, result: &str) {
    let (owner, id) = {
        let task = lock(task);
        (task.owner.name.clone(), task.status.task_id.clone())
    };
    if audit_data::insert(
        pool,
        audit::now_ms(),
        &owner,
        action,
        "audit_log",
        result,
        &id,
    )
    .await
    .is_err()
    {
        diagnostic(
            "KEEL-DB",
            &id,
            "Audit export audit record failed; no path or filter recorded",
        );
    }
}

fn finish_error(task: &SharedTask, error: &KeelError) {
    let mut task = lock(task);
    if task.status.phase != "running" {
        return;
    }
    task.status.phase = if matches!(error, KeelError::Cancelled) {
        "cancelled"
    } else {
        "failed"
    }
    .into();
    task.status.error_code = if matches!(error, KeelError::Cancelled) {
        None
    } else {
        Some(error.code().into())
    };
    task.finished = Some(Instant::now());
}

/// Future 在首次 poll 前被丢弃、spawn panic、worker panic、runtime shutdown 都结束 running。
/// Drop 无法异步写 DB；异常丢弃明确输出安全诊断，正常结果走异步审计。
struct StartReservation {
    id: String,
    handed_off: bool,
}

impl Drop for StartReservation {
    fn drop(&mut self) {
        if self.handed_off {
            return;
        }
        let mut registry = lock(registry());
        // WorkerGuard 先于本预留析构：已置终态的失败句柄保留给 list/owned 展示，
        // 只回滚从未启动、仍处 running 的僵尸预留。
        let terminal = registry
            .tasks
            .get(&self.id)
            .is_some_and(|task| lock(task).finished.is_some());
        if !terminal {
            registry.tasks.remove(&self.id);
        }
    }
}

struct WorkerGuard {
    task: SharedTask,
    armed: bool,
}

impl Drop for WorkerGuard {
    fn drop(&mut self) {
        if self.armed {
            finish_error(&self.task, &KeelError::internal("export worker dropped"));
            diagnostic(
                "KEEL-INTERNAL",
                &lock(&self.task).status.task_id,
                "Audit export worker stopped unexpectedly; result audit may be unavailable",
            );
        }
    }
}

pub async fn start(
    pool: &SqlitePool,
    db_path: &Path,
    query: AuditQuery,
) -> Result<AuditExportStatus, KeelError> {
    let identity_guard = access::lock_identity().await;
    let owner = access::require(pool, Permission::AuditExport).await?;
    let params = validate(query)?;
    let handle = tokio::runtime::Handle::try_current()
        .map_err(|_| KeelError::internal("export runtime unavailable"))?;
    let base = db_path
        .parent()
        .filter(|p| p.is_absolute())
        .ok_or_else(|| KeelError::Validation("导出需要绝对数据目录".into()))?
        .to_path_buf();
    if base.to_str().is_none() {
        return Err(KeelError::Validation("导出目录必须能表示为 UTF-8".into()));
    }
    if access::current()? != owner {
        return Err(KeelError::PermissionDenied("audit.export.owner".into()));
    }
    let task = lock(registry()).reserve(owner.clone())?;
    let initial = lock(&task).status.clone();
    let mut reservation = StartReservation {
        id: initial.task_id.clone(),
        handed_off: false,
    };
    // 在 async future 外创建 guard：即使 spawn 前失败/从未 poll，也有终态。
    let guard = WorkerGuard {
        task: task.clone(),
        armed: true,
    };
    // Do not start an operation whose durable registration did not commit.
    crate::services::audit_export_history::register(pool, &owner, &initial.task_id).await?;
    drop(identity_guard);
    let supervisor_pool = pool.clone();
    let pool = pool.clone();
    let future = async move {
        #[cfg(debug_assertions)]
        let pause = { lock(worker_pause()).take() };
        #[cfg(debug_assertions)]
        if let Some((arrive, released)) = pause {
            let _ = arrive.send(());
            let _ = released.await;
        }
        record(&pool, &guard.task, "audit.export.start", "started").await;
        let result = run(&pool, &base, params, &guard.task).await;
        if let Err(error) = &result {
            finish_error(&guard.task, error);
            if !matches!(error, KeelError::Cancelled) {
                diagnostic(
                    error.code(),
                    &lock(&guard.task).status.task_id,
                    "Audit export failed",
                );
            }
        }
        let status = lock(&guard.task).status.clone();
        if let Err(error) =
            crate::services::audit_export_history::finish_with_retry(&pool, &status).await
        {
            diagnostic(
                error.code(),
                &status.task_id,
                "Export history terminal write failed",
            );
        }
        let outcome = if let Some(code) = status.error_code {
            format!("failed:{code}")
        } else {
            status.phase
        };
        record(&pool, &guard.task, "audit.export.result", &outcome).await;
        std::mem::forget(guard);
    };
    // CSV 转义和本地磁盘同步写在 Tokio 阻塞池上，SQLx 异步操作仍使用原 runtime。
    let worker_handle = handle.clone();
    let worker = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        handle.spawn_blocking(move || worker_handle.block_on(future))
    }))
    .map_err(|_| KeelError::internal("export spawn failed"))?;
    reservation.handed_off = true;
    // panic 由 guard 先同步结束状态；runtime 仍可用时补写明确的结果审计。
    let _supervisor = handle.spawn(async move {
        if worker.await.is_err() {
            finish_error(&task, &KeelError::internal("export worker join failed"));
            let status = lock(&task).status.clone();
            if let Err(error) =
                crate::services::audit_export_history::finish_with_retry(&supervisor_pool, &status)
                    .await
            {
                diagnostic(
                    error.code(),
                    &status.task_id,
                    "Export history terminal write failed",
                );
            }
            let outcome = match status.error_code {
                Some(code) => format!("failed:{code}"),
                None => status.phase,
            };
            record(&supervisor_pool, &task, "audit.export.result", &outcome).await;
        }
    });
    Ok(initial)
}

async fn owned(pool: &SqlitePool, id: &str) -> Result<SharedTask, KeelError> {
    let owner = access::require(pool, Permission::AuditExport).await?;
    if id.len() > 128 || id.is_empty() {
        return Err(KeelError::Validation("无效导出任务 ID".into()));
    }
    let mut registry = lock(registry());
    registry.prune(Instant::now());
    let task = registry.tasks.get(id).ok_or(KeelError::NotFound)?.clone();
    if lock(&task).owner != owner || access::current()? != owner {
        return Err(KeelError::PermissionDenied("audit.export.owner".into()));
    }
    Ok(task)
}

/// Current process only, at most MAX_TASKS; all terminal phases expire at 300s.
/// Expiry hides handles, never removes exported files or renews a result lease.
pub async fn list(pool: &SqlitePool) -> Result<Vec<AuditExportStatus>, KeelError> {
    let owner = access::require(pool, Permission::AuditExport).await?;
    let registry = lock(registry());
    let items = registry.list_owned(&owner, Instant::now());
    if access::current()? != owner {
        return Err(KeelError::PermissionDenied("audit.export.owner".into()));
    }
    Ok(items)
}

pub async fn status(pool: &SqlitePool, id: &str) -> Result<AuditExportStatus, KeelError> {
    let task = owned(pool, id).await?;
    let status = lock(&task).status.clone();
    Ok(status)
}

/// 返回 running 表示取消请求已接受，只有 worker 清理完临时文件才变 cancelled。
/// 与文件发布共用同一锁；发布成功后取消是幂等无操作。
pub async fn cancel(pool: &SqlitePool, id: &str) -> Result<AuditExportStatus, KeelError> {
    let task = owned(pool, id).await?;
    let mut task = lock(&task);
    if task.status.phase == "running" {
        task.cancel = true;
    }
    Ok(task.status.clone())
}

fn copy_owner(task: &SharedTask) -> Result<(), KeelError> {
    let task = lock(task);
    let current = access::current()?;
    if current != task.owner || !current.role.allows(Permission::AuditExport) {
        return Err(KeelError::PermissionDenied("audit.export.owner".into()));
    }
    if task.finished.is_some_and(|at| at.elapsed() >= TTL) {
        return Err(KeelError::NotFound);
    }
    if task.status.phase != "completed" || task.source.is_none() {
        return Err(KeelError::Validation("只能另存已完成的导出".into()));
    }
    Ok(())
}

/// 阻塞池排队前、开始读取前、异步授权等待后和发布前均复查完整身份。
pub async fn save_copy(
    pool: &SqlitePool,
    id: &str,
    destination: &str,
) -> Result<String, KeelError> {
    let actor = access::current()?;
    let result = async {
        let task = owned(pool, id).await?;
        if actor != lock(&task).owner {
            return Err(KeelError::PermissionDenied("audit.export.owner".into()));
        }
        copy_owner(&task)?;
        let destination = destination.to_owned();
        let pool = pool.clone();
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            copy_owner(&task)?;
            let (source, stamp) = {
                let task = lock(&task);
                (
                    task.status.output_path.clone().ok_or(KeelError::NotFound)?,
                    task.source.clone().ok_or(KeelError::NotFound)?,
                )
            };
            let target = copy_destination(&destination)?;
            copy_owner(&task)?;
            let temp = stage_copy(Path::new(&source), &stamp, &target)?;
            let authorized = runtime.block_on(access::require(&pool, Permission::AuditExport))?;
            if authorized != lock(&task).owner {
                return Err(KeelError::PermissionDenied("audit.export.owner".into()));
            }
            publish_copy(&task, temp, &target)?;
            Ok(destination)
        })
        .await
        .map_err(|_| KeelError::internal("copy worker join failed"))?
    }
    .await;
    // 仅记录经格式校验的 task ID，拒绝把调用者任意输入/目标路径带入审计。
    if !id.is_empty()
        && id.len() <= 128
        && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        let outcome = match &result {
            Ok(_) => "ok".to_owned(),
            Err(error) => format!("failed:{}", error.code()),
        };
        if audit_data::insert(
            pool,
            audit::now_ms(),
            &actor.name,
            "audit.export.copy",
            id,
            &outcome,
            id,
        )
        .await
        .is_err()
        {
            diagnostic("KEEL-DB", id, "Audit export copy audit record failed");
        }
    }
    result
}

fn publish_copy(task: &SharedTask, temp: Temporary, target: &Path) -> Result<(), KeelError> {
    copy_owner(task)?;
    safe_directory(target.parent().ok_or(KeelError::NotFound)?)?;
    temp.verify_file()?;
    copy_owner(task)?;
    // 唯一发布点：目标存在时 hard_link 失败，绝不覆盖或退化为直接写目标。
    fs::hard_link(&temp.path, target).map_err(KeelError::Io)?;
    Ok(())
}

fn invalid_copy() -> KeelError {
    KeelError::Validation("另存路径或源文件不安全、已变化或超过 64 MiB".into())
}

fn copy_destination(value: &str) -> Result<PathBuf, KeelError> {
    let path = PathBuf::from(value);
    if !path.is_absolute()
        || value.starts_with('\\')
        || value.starts_with("//")
        || value.chars().any(char::is_control)
        || value.ends_with(['/', '\\'])
        || value
            .split(['/', '\\'])
            .any(|part| part == "." || part == "..")
    {
        return Err(invalid_copy());
    }
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => match prefix.kind() {
                std::path::Prefix::Disk(drive) => {
                    #[cfg(windows)]
                    check_local_drive(drive)?;
                    #[cfg(not(windows))]
                    let _ = drive;
                }
                _ => return Err(invalid_copy()),
            },
            Component::Normal(name) => {
                let name = name.to_str().ok_or_else(invalid_copy)?;
                let stem = name
                    .split('.')
                    .next()
                    .unwrap_or("")
                    .trim_end()
                    .to_uppercase();
                if name.ends_with(['.', ' '])
                    || name.contains([':', '\\', '<', '>', '"', '|', '?', '*'])
                    || matches!(
                        stem.as_str(),
                        "CON" | "PRN" | "AUX" | "NUL" | "CLOCK$" | "CONIN$" | "CONOUT$"
                    )
                    || ["COM", "LPT"].iter().any(|prefix| {
                        stem.strip_prefix(*prefix).is_some_and(|n| {
                            matches!(
                                n,
                                "1" | "2"
                                    | "3"
                                    | "4"
                                    | "5"
                                    | "6"
                                    | "7"
                                    | "8"
                                    | "9"
                                    | "¹"
                                    | "²"
                                    | "³"
                            )
                        })
                    })
                {
                    return Err(invalid_copy());
                }
            }
            Component::RootDir => (),
            _ => return Err(invalid_copy()),
        }
    }
    // 拒绝系统目录及可执行文件。允许用户选择普通本地目录，不构建路径沙箱。
    let lower = value.replace('\\', "/").to_lowercase();
    if [
        "/bin", "/sbin", "/etc", "/usr", "/lib", "/lib64", "/boot", "/dev", "/proc", "/sys",
        "/root", "/run", "/var", "/opt", "/srv", "/snap",
    ]
    .iter()
    .any(|root| lower == *root || lower.starts_with(&format!("{root}/")))
        || path
            .extension()
            .and_then(|s| s.to_str())
            .is_none_or(|s| !s.eq_ignore_ascii_case("csv"))
    {
        return Err(invalid_copy());
    }
    #[cfg(windows)]
    {
        for key in [
            "SystemRoot",
            "WINDIR",
            "ProgramFiles",
            "ProgramFiles(x86)",
            "ProgramData",
        ] {
            if let Some(root) = std::env::var_os(key) {
                let root = root
                    .to_string_lossy()
                    .replace('\\', "/")
                    .trim_end_matches('/')
                    .to_lowercase();
                if lower == root || lower.starts_with(&format!("{root}/")) {
                    return Err(invalid_copy());
                }
            }
        }
        if lower.split('/').any(|s| {
            matches!(
                s,
                "windows"
                    | "program files"
                    | "program files (x86)"
                    | "programdata"
                    | "$recycle.bin"
                    | "system volume information"
            )
        }) {
            return Err(invalid_copy());
        }
    }
    let parent = path
        .parent()
        .filter(|p| p.parent().is_some())
        .ok_or_else(invalid_copy)?;
    safe_directory(parent)?;
    #[cfg(windows)]
    {
        // 在先拒绝 links 后解析实际父目录，避免 8.3 短名称绕过系统目录检查。
        let resolved = fs::canonicalize(parent).map_err(KeelError::Io)?;
        let resolved = resolved.to_string_lossy().replace('\\', "/").to_lowercase();
        if resolved.split('/').any(|s| {
            matches!(
                s,
                "windows"
                    | "program files"
                    | "program files (x86)"
                    | "programdata"
                    | "$recycle.bin"
                    | "system volume information"
            )
        }) {
            return Err(invalid_copy());
        }
        for key in [
            "SystemRoot",
            "WINDIR",
            "ProgramFiles",
            "ProgramFiles(x86)",
            "ProgramData",
        ] {
            if let Some(root) = std::env::var_os(key) {
                let root = fs::canonicalize(root).map_err(KeelError::Io)?;
                let root = root
                    .to_string_lossy()
                    .replace('\\', "/")
                    .trim_end_matches('/')
                    .to_lowercase();
                if resolved == root || resolved.starts_with(&format!("{root}/")) {
                    return Err(invalid_copy());
                }
            }
        }
    }
    match fs::symlink_metadata(&path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
        Err(e) => return Err(KeelError::Io(e)),
        Ok(_) => return Err(KeelError::Duplicate),
    }
    Ok(path)
}

#[cfg(windows)]
fn check_local_drive(drive: u8) -> Result<(), KeelError> {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetDriveTypeW(root_path: *const u16) -> u32;
    }
    let root = [u16::from(drive), b':' as u16, b'\\' as u16, 0];
    // SAFETY: root 是有效、以 NUL 结尾且在调用期间存活的 UTF-16 缓冲。
    // 仅允许 removable/fixed/RAM disk；映射网络盘与未知设备安全失败。
    if matches!(unsafe { GetDriveTypeW(root.as_ptr()) }, 2 | 3 | 6) {
        Ok(())
    } else {
        Err(invalid_copy())
    }
}

// Windows Metadata 的稳定 API 不含 volume/file index；它只检查属性变化，
// 句柄身份必须另外由 check_source_handle / check_windows_identity 检查。
fn same_metadata(a: &fs::Metadata, b: &fs::Metadata) -> bool {
    if is_link(a)
        || is_link(b)
        || !a.is_file()
        || !b.is_file()
        || a.len() > MAX_BYTES
        || a.len() != b.len()
        || a.modified().ok() != b.modified().ok()
        || a.created().ok() != b.created().ok()
    {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if a.dev() != b.dev() || a.ino() != b.ino() {
            return false;
        }
    }
    true
}

#[cfg(windows)]
fn windows_identity(file: &File) -> Result<(u32, u32, u32), KeelError> {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    // Win32 BY_HANDLE_FILE_INFORMATION，布局与 import_screen 中的实现一致。
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
    // SAFETY: File 句柄在调用期间有效，输出缓冲符合 Win32 ABI，仅成功后读取。
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), info.as_mut_ptr()) } == 0 {
        return Err(KeelError::Io(std::io::Error::last_os_error()));
    }
    // SAFETY: 成功返回说明 Win32 已初始化完整结构。
    let info = unsafe { info.assume_init() };
    Ok((info.volume, info.index_high, info.index_low))
}

#[cfg(windows)]
fn check_windows_identity(file: &File, expected: (u32, u32, u32)) -> Result<(), KeelError> {
    if windows_identity(file)? != expected {
        return Err(invalid_copy());
    }
    Ok(())
}

#[cfg(windows)]
fn check_windows_handles(
    first: &File,
    second: &File,
    expected: (u32, u32, u32),
) -> Result<(), KeelError> {
    check_windows_identity(first, expected)?;
    check_windows_identity(second, expected)
}

fn check_source_handle(file: &File, stamp: &SourceStamp) -> Result<(), KeelError> {
    if !same_metadata(&file.metadata().map_err(KeelError::Io)?, &stamp.metadata) {
        return Err(invalid_copy());
    }
    #[cfg(windows)]
    check_windows_identity(file, stamp.identity)?;
    Ok(())
}

fn source_file(path: &Path, stamp: &SourceStamp) -> Result<File, KeelError> {
    safe_directory(path.parent().ok_or_else(invalid_copy)?)?;
    let metadata = fs::symlink_metadata(path).map_err(KeelError::Io)?;
    if !same_metadata(&metadata, &stamp.metadata) {
        return Err(invalid_copy());
    }
    // Windows 的路径元数据不能证明身份；probe 保持打开至实际读取句柄核对完成。
    #[cfg(windows)]
    let probe = open_source_file(path)?;
    #[cfg(windows)]
    check_source_handle(&probe, stamp)?;
    let file = open_source_file(path)?;
    check_source_handle(&file, stamp)?;
    #[cfg(windows)]
    check_windows_handles(&probe, &file, stamp.identity)?;
    Ok(file)
}

fn open_source_file(path: &Path) -> Result<File, KeelError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Linux O_NOFOLLOW | O_NONBLOCK：拒绝最终符号链接，竞争替换为 FIFO 时也不挂起。
        options.custom_flags(0x20000 | 0x800);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000).share_mode(1); // 不允许打开期间写入/删除。
    }
    options.open(path).map_err(KeelError::Io)
}

/// 所有文件 I/O 由 blocking worker 调用。祖先检查与打开/发布之间仍有 TOCTOU：
/// 不抵御同机恶意进程并发替换目录，不把标准库路径检查宣称为沙箱。
fn stage_copy(source: &Path, stamp: &SourceStamp, target: &Path) -> Result<Temporary, KeelError> {
    let mut file = source_file(source, stamp)?;
    let before = file.metadata().map_err(KeelError::Io)?;
    let mut temp = Temporary::create_in(target.parent().ok_or_else(invalid_copy)?)?;
    let mut buffer = [0_u8; 32 * 1024];
    loop {
        let count = file.read(&mut buffer).map_err(KeelError::Io)?;
        if count == 0 {
            break;
        }
        temp.write(&buffer[..count])?;
    }
    if temp.bytes != stamp.metadata.len()
        || temp.hash.finish() != stamp.hash
        || !same_metadata(&before, &file.metadata().map_err(KeelError::Io)?)
        || !same_metadata(
            &before,
            &fs::symlink_metadata(source).map_err(KeelError::Io)?,
        )
    {
        return Err(invalid_copy());
    }
    temp.sync()?;
    // 落盘等待后复查原读取句柄及路径；Windows 重新打开并核对 volume/index，
    // 不把 size/时间戳一致误当成同一个文件。祖先目录恶意替换的边界仍存在。
    check_source_handle(&file, stamp)?;
    #[cfg(windows)]
    {
        let reopened = source_file(source, stamp)?;
        check_windows_handles(&file, &reopened, stamp.identity)?;
    }
    Ok(temp)
}

fn check_cancel(task: &SharedTask) -> Result<(), KeelError> {
    if lock(task).cancel {
        Err(KeelError::Cancelled)
    } else {
        Ok(())
    }
}

/// 检查全部已存在祖先，不 canonicalize 后悄悄接受符号链接或 junction。
/// std 路径 API 不提供跨平台 openat，仍假定数据目录不被本机其他进程恶意并发替换。
fn safe_directory(path: &Path) -> Result<(), KeelError> {
    for ancestor in path.ancestors() {
        let metadata = fs::symlink_metadata(ancestor).map_err(KeelError::Io)?;
        if is_link(&metadata) || !metadata.is_dir() {
            return Err(KeelError::Validation("导出目录含不安全文件类型".into()));
        }
    }
    Ok(())
}

fn is_link(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // FILE_ATTRIBUTE_REPARSE_POINT，包含 junction 等非符号链接重解析点。
        metadata.file_type().is_symlink() || metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

struct Temporary {
    path: PathBuf,
    file: Option<BufWriter<File>>,
    bytes: u64,
    hash: DefaultHasher,
}

impl Temporary {
    fn create(base: &Path) -> Result<Self, KeelError> {
        safe_directory(base)?;
        let dir = base.join("exports");
        #[cfg(unix)]
        let mut directory = fs::DirBuilder::new();
        #[cfg(not(unix))]
        let directory = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            directory.mode(0o700);
        }
        match directory.create(&dir) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(e) => return Err(KeelError::Io(e)),
        }
        safe_directory(&dir)?;
        Self::create_in(&dir)
    }

    fn create_in(dir: &Path) -> Result<Self, KeelError> {
        safe_directory(dir)?;
        for _ in 0..16 {
            let nonce = RandomState::new().hash_one(new_correlation_id());
            let path = dir.join(format!(".audit-{nonce:016x}.tmp"));
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::OpenOptionsExt;
                options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
            }
            match options.open(&path) {
                Ok(file) => {
                    return Ok(Self {
                        path,
                        file: Some(BufWriter::new(file)),
                        bytes: 0,
                        hash: DefaultHasher::new(),
                    })
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(KeelError::Io(e)),
            }
        }
        Err(KeelError::Io(std::io::Error::other(
            "export name collision",
        )))
    }

    fn write(&mut self, bytes: &[u8]) -> Result<(), KeelError> {
        if bytes.len() as u64 > MAX_BYTES - self.bytes {
            return Err(KeelError::Validation("CSV 超过 64 MiB".into()));
        }
        self.file
            .as_mut()
            .ok_or_else(|| KeelError::internal("export file closed"))?
            .write_all(bytes)
            .map_err(KeelError::Io)?;
        self.bytes += bytes.len() as u64;
        self.hash.write(bytes);
        Ok(())
    }

    fn sync(&mut self) -> Result<(), KeelError> {
        if let Some(mut file) = self.file.take() {
            file.flush().map_err(KeelError::Io)?;
            file.get_ref().sync_all().map_err(KeelError::Io)?;
        }
        Ok(())
    }

    fn source_stamp(&mut self) -> Result<SourceStamp, KeelError> {
        let mut file = self
            .file
            .take()
            .ok_or_else(|| KeelError::internal("export file closed"))?;
        file.flush().map_err(KeelError::Io)?;
        file.get_ref().sync_all().map_err(KeelError::Io)?;
        // 从实际写入句柄记录完成源身份，不能关闭后仅凭路径重新采样。
        SourceStamp::from_file(file.get_ref(), self.hash.finish())
    }

    fn publish(&mut self, id: &str) -> Result<PathBuf, KeelError> {
        self.sync()?;
        let dir = self
            .path
            .parent()
            .ok_or_else(|| KeelError::internal("export directory missing"))?;
        safe_directory(dir)?;
        self.verify_file()?;
        let output = dir.join(format!("audit-{id}.csv"));
        // hard_link 原子发布完整 inode，目标已存在（含链接）必失败，绝不 rename 覆盖。
        // 不支持 hard link 的文件系统安全失败，不降级为覆盖/部分可见的复制。
        fs::hard_link(&self.path, &output).map_err(KeelError::Io)?;
        Ok(output)
    }

    fn verify_file(&self) -> Result<(), KeelError> {
        let metadata = fs::symlink_metadata(&self.path).map_err(KeelError::Io)?;
        if !metadata.file_type().is_file() || is_link(&metadata) {
            return Err(KeelError::Validation("导出临时文件类型无效".into()));
        }
        Ok(())
    }
}

impl Drop for Temporary {
    fn drop(&mut self) {
        drop(self.file.take());
        if fs::remove_file(&self.path).is_err() {
            diagnostic("KEEL-IO", "", "Audit export temporary file cleanup failed");
        }
    }
}

fn formula_prefix(value: &str) -> bool {
    // 空白前缀中的 TAB/CR/LF 也有风险，不能只 trim 后判断公式首字符。
    value
        .chars()
        .take_while(|c| c.is_whitespace())
        .any(|c| matches!(c, '\t' | '\r' | '\n'))
        || value.trim_start().starts_with(['=', '+', '-', '@'])
}

fn write_field(temp: &mut Temporary, value: &str, task: &SharedTask) -> Result<(), KeelError> {
    temp.write(b"\"")?;
    if formula_prefix(value) {
        temp.write(b"'")?;
    }
    // 只保留至多 16 KiB 转义缓冲，不复制整行/整个导出；字节切片保持 UTF-8 原始字节。
    for chunk in value.as_bytes().chunks(8192) {
        check_cancel(task)?;
        let mut escaped = Vec::with_capacity(chunk.len() * 2);
        for byte in chunk {
            escaped.push(*byte);
            if *byte == b'"' {
                escaped.push(b'"');
            }
        }
        temp.write(&escaped)?;
    }
    temp.write(b"\"")
}

fn write_row(
    temp: &mut Temporary,
    row: &audit_data::AuditRow,
    task: &SharedTask,
) -> Result<(), KeelError> {
    let id = row.id.to_string();
    let at = row.at.to_string();
    for (index, field) in [&id, &at, &row.actor, &row.action, &row.target, &row.result]
        .into_iter()
        .enumerate()
    {
        if index != 0 {
            temp.write(b",")?;
        }
        write_field(temp, field, task)?;
    }
    temp.write(b"\r\n")
}

async fn run(
    pool: &SqlitePool,
    base: &Path,
    params: ListParams,
    task: &SharedTask,
) -> Result<(), KeelError> {
    check_cancel(task)?;
    let mut snapshot = ExportSnapshot::begin(pool, params).await?;
    check_cancel(task)?;
    if snapshot.total > i64::from(MAX_ROWS) || snapshot.raw_bytes > MAX_BYTES as i64 {
        return Err(KeelError::Validation(
            "审计导出超过 100000 行或 64 MiB".into(),
        ));
    }
    lock(task).status.total_rows = snapshot.total as u32;
    let mut temp = Temporary::create(base)?;
    temp.write(b"\xef\xbb\xbfid,at_utc_ms,actor,action,target,result\r\n")?;
    loop {
        check_cancel(task)?;
        let rows = snapshot.next_batch().await?;
        if rows.is_empty() {
            break;
        }
        for row in rows {
            check_cancel(task)?;
            write_row(&mut temp, &row, task)?;
            lock(task).status.completed_rows += 1;
            // 即使单线程 runtime 也让取消调用有机会执行。
            tokio::task::yield_now().await;
        }
    }
    // 在写结果审计前释放只读事务，避免单连接池/rollback journal 的死锁。
    // 显式回滚：丢弃事务的后台回滚可能与连接复用竞态，留下旧快照连接。
    let _ = snapshot.release().await;
    // 大量落盘不持任务锁；同步期间仍可请求取消，发布前最后复查。
    let source = temp.source_stamp()?;
    let mut task = lock(task);
    if task.cancel {
        return Err(KeelError::Cancelled);
    }
    let output = temp.publish(&task.status.task_id)?;
    drop(temp);
    task.status.output_path = Some(output.to_string_lossy().into_owned());
    task.status.phase = "completed".into();
    task.source = Some(source);
    task.finished = Some(Instant::now());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::audit::SortKey;
    use crate::domain::permissions::Role;

    #[test]
    fn history_is_read_only_stable_full_identity_scoped_and_never_renews_ttl() {
        let mut registry = Registry::default();
        let owner = access::CurrentUser {
            name: "owner".into(),
            role: Role::Admin,
        };
        let now = Instant::now();
        let mut ids = Vec::new();
        for phase in ["completed", "failed", "cancelled"] {
            let task = registry.reserve(owner.clone()).unwrap();
            let mut task = lock(&task);
            task.created = now; // exercise deterministic tie-break
            task.status.phase = phase.into();
            task.finished = Some(now);
            ids.push(task.status.task_id.clone());
        }
        registry
            .reserve(access::CurrentUser {
                name: "other".into(),
                role: Role::Admin,
            })
            .unwrap();
        registry
            .reserve(access::CurrentUser {
                name: owner.name.clone(),
                role: Role::Operator,
            })
            .unwrap();
        ids.sort();
        let rows = registry.list_owned(&owner, now + TTL - Duration::from_nanos(1));
        assert_eq!(
            rows.iter().map(|s| s.task_id.clone()).collect::<Vec<_>>(),
            ids
        );
        assert_eq!(registry.tasks.len(), 5);
        assert!(registry.list_owned(&owner, now + TTL).is_empty());
        assert!(registry.list_owned(&owner, now + TTL + TTL).is_empty());
        assert_eq!(registry.tasks.len(), 5, "listing never mutates Registry");
        let other = access::CurrentUser {
            name: "other".into(),
            role: Role::Admin,
        };
        assert_eq!(
            registry.list_owned(&other, now + TTL + TTL).len(),
            1,
            "running tasks do not expire with terminal TTL"
        );
        // Different creation instants take precedence over lexicographic ID.
        lock(&registry.tasks[&ids[0]]).created = now + Duration::from_nanos(1);
        assert_eq!(registry.list_owned(&owner, now)[0].task_id, ids[0]);
        for id in ids {
            assert_eq!(lock(&registry.tasks[&id]).finished, Some(now));
        }
    }

    #[test]
    fn registry_enforces_owner_capacity_and_terminal_ttl() {
        let mut registry = Registry::default();
        let owner = access::CurrentUser {
            name: "a".into(),
            role: Role::Admin,
        };
        let first = registry.reserve(owner.clone()).unwrap();
        assert!(registry.reserve(owner.clone()).is_err());
        for i in 1..6 {
            registry
                .reserve(access::CurrentUser {
                    name: i.to_string(),
                    role: Role::Operator,
                })
                .unwrap();
        }
        assert!(registry
            .reserve(access::CurrentUser {
                name: "overflow".into(),
                role: Role::Admin
            })
            .is_err());
        finish_error(&first, &KeelError::Cancelled);
        registry.prune(Instant::now() + TTL);
        assert_eq!(registry.tasks.len(), 5);
        assert!(registry.reserve(owner).is_ok());
    }

    #[test]
    fn csv_protects_formulas_controls_and_quotes() {
        for value in [
            "=1",
            "  +1",
            "\u{2003}-1",
            "@x",
            "\tword",
            " \rword",
            "\nword",
        ] {
            assert!(formula_prefix(value), "{value:?}");
        }
        assert!(!formula_prefix("a,\"b\"\r\n中文"));
        assert!(!formula_prefix("normal"));
    }

    #[cfg(windows)]
    #[test]
    fn windows_source_identity_rejects_replacement_despite_matching_metadata_and_content() {
        let dir = std::env::temp_dir().join(format!("keel-copy-identity-{}", new_correlation_id()));
        fs::create_dir(&dir).unwrap();
        let mut original = Temporary::create(&dir).unwrap();
        original.write(b"identical CSV bytes").unwrap();
        let stamp = original.source_stamp().unwrap();
        // 完成 stamp 来自写入句柄；hard_link 发布不能改变 volume/index。
        let source = original.publish("identity").unwrap();
        drop(original);
        let old = File::open(&source).unwrap();
        assert_eq!(windows_identity(&old).unwrap(), stamp.identity);
        let opened = source_file(&source, &stamp).unwrap();
        let reopened = open_source_file(&source).unwrap();
        check_windows_handles(&opened, &reopened, stamp.identity).unwrap();
        drop(opened);
        drop(reopened);
        // 只改变 volume / index high / index low 中任一字段都必须拒绝，
        // 不需要两个真实文件恰巧具有相同的创建或修改时间。
        let (volume, high, low) = stamp.identity;
        for wrong in [
            (volume ^ 1, high, low),
            (volume, high ^ 1, low),
            (volume, high, low ^ 1),
        ] {
            assert!(matches!(
                check_windows_identity(&old, wrong),
                Err(KeelError::Validation(_))
            ));
        }
        let replacement = dir.join("replacement.csv");
        fs::write(&replacement, b"identical CSV bytes").unwrap();
        let parked = dir.join("parked.csv");
        // 保留 old 句柄防止旧 index 被复用；File::open 默认允许删除/重命名共享。
        fs::rename(&source, &parked).unwrap();
        fs::rename(&replacement, &source).unwrap();
        let replacement_handle = open_source_file(&source).unwrap();
        assert_ne!(
            windows_identity(&replacement_handle).unwrap(),
            stamp.identity
        );
        assert_eq!(fs::read(&source).unwrap(), fs::read(&parked).unwrap());
        let mut equal_metadata_stamp = stamp.clone();
        equal_metadata_stamp.metadata = replacement_handle.metadata().unwrap();
        assert!(same_metadata(
            &replacement_handle.metadata().unwrap(),
            &equal_metadata_stamp.metadata
        ));
        // 即使跳过时间戳差异，probe/实际打开的检查仍因完成 stamp 的身份不符拒绝。
        assert!(matches!(
            check_source_handle(&replacement_handle, &equal_metadata_stamp),
            Err(KeelError::Validation(_))
        ));
        assert!(matches!(
            source_file(&source, &equal_metadata_stamp),
            Err(KeelError::Validation(_))
        ));
        // 与 stage_copy 末尾共用的核对：读取句柄正确、reopen 指向新文件也不能放行；
        // 反过来第一句柄被替换同样拒绝。这些断言完全不读取时间戳。
        assert!(matches!(
            check_windows_handles(&old, &replacement_handle, stamp.identity),
            Err(KeelError::Validation(_))
        ));
        assert!(matches!(
            check_windows_handles(&replacement_handle, &old, stamp.identity),
            Err(KeelError::Validation(_))
        ));
        let target = dir.join("copy.csv");
        assert!(matches!(
            stage_copy(&source, &equal_metadata_stamp, &target),
            Err(KeelError::Validation(_))
        ));
        assert!(!target.exists());
        assert!(!fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .any(|entry| entry.file_name().to_string_lossy().ends_with(".tmp")));
        drop(replacement_handle);
        drop(old);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn copy_stream_checks_content_metadata_types_limits_and_cleans_failures() {
        let dir = std::env::temp_dir().join(format!("keel-copy-{}", new_correlation_id()));
        fs::create_dir(&dir).unwrap();
        let mut original = Temporary::create(&dir).unwrap();
        let bytes = vec![b'x'; 70_001];
        original.write(&bytes).unwrap();
        let stamp = original.source_stamp().unwrap();
        let source = original.publish("source").unwrap();
        drop(original);
        let target = dir.join("副本.csv");
        let temp = stage_copy(&source, &stamp, &target).unwrap();
        fs::hard_link(&temp.path, &target).unwrap();
        drop(temp);
        assert_eq!(fs::read(&target).unwrap(), bytes);
        assert!(copy_destination(target.to_str().unwrap()).is_err());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&target).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        // 模拟目标在暂存后被另一写者抢占；发布失败且清理临时文件。
        let temp = stage_copy(&source, &stamp, &target).unwrap();
        assert!(fs::hard_link(&temp.path, &target).is_err());
        drop(temp);
        assert_eq!(fs::read(&target).unwrap(), bytes);
        let mut bad_hash = stamp.clone();
        bad_hash.hash ^= 1;
        assert!(stage_copy(&source, &bad_hash, &dir.join("bad.csv")).is_err());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 2); // exports + 副本，无残留临时文件
        fs::write(&source, b"changed").unwrap();
        assert!(stage_copy(&source, &stamp, &dir.join("bad.csv")).is_err());
        fs::remove_file(&source).unwrap();
        fs::create_dir(&source).unwrap();
        assert!(stage_copy(&source, &stamp, &dir.join("bad.csv")).is_err());
        fs::remove_dir(&source).unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&target, &source).unwrap();
            assert!(stage_copy(&source, &stamp, &dir.join("bad.csv")).is_err());
            fs::remove_file(&source).unwrap();
            let linked = dir.join("linked");
            std::os::unix::fs::symlink(&dir, &linked).unwrap();
            assert!(copy_destination(linked.join("bad.csv").to_str().unwrap()).is_err());
            let linked_target = dir.join("linked-target.csv");
            std::os::unix::fs::symlink(&target, &linked_target).unwrap();
            assert!(copy_destination(linked_target.to_str().unwrap()).is_err());
            assert_eq!(fs::read(&target).unwrap(), bytes);
        }
        // 稀疏文件，只检查大小而不分配/读取 64 MiB。
        let file = File::create(&source).unwrap();
        file.set_len(MAX_BYTES + 1).unwrap();
        let oversized = SourceStamp::from_file(&file, 0).unwrap();
        drop(file);
        assert!(source_file(&source, &oversized).is_err());
        assert_eq!(
            fs::read_dir(&dir)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
                .count(),
            0
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn copy_rejects_nonlocal_ambiguous_reserved_and_system_paths() {
        for path in [
            "relative.csv",
            "//server/share/x.csv",
            r"\\server\share\x.csv",
            r"\\?\C:\data\x.csv",
            r"\\.\C:\data\x.csv",
            "/tmp/x.csv:stream",
            "/tmp/NUL.csv",
            "/tmp/COM1.csv",
            "/tmp/LPT².csv",
            "/tmp/con .csv",
            "/tmp/../x.csv",
            "/tmp/./x.csv",
            "/tmp/x.csv.",
            "/tmp/x.exe",
            "/etc/new.csv",
            "/proc/new.csv",
            "/dev/new.csv",
            "/usr/local/new.csv",
        ] {
            assert!(copy_destination(path).is_err(), "{path}");
        }
    }

    #[test]
    fn worker_drop_finishes_unpolled_task_and_publish_never_overwrites() {
        let mut registry = Registry::default();
        let task = registry
            .reserve(access::CurrentUser {
                name: "a".into(),
                role: Role::Admin,
            })
            .unwrap();
        drop(WorkerGuard {
            task: task.clone(),
            armed: true,
        });
        assert_eq!(lock(&task).status.phase, "failed");
        let dir = std::env::temp_dir().join(new_correlation_id());
        fs::create_dir(&dir).unwrap();
        let mut temp = Temporary::create(&dir).unwrap();
        temp.write(b"first").unwrap();
        let output = temp.publish("collision").unwrap();
        drop(temp);
        let mut second = Temporary::create(&dir).unwrap();
        second.write(b"second").unwrap();
        assert!(second.publish("collision").is_err());
        drop(second);
        assert_eq!(fs::read(&output).unwrap(), b"first");
        assert_eq!(fs::read_dir(dir.join("exports")).unwrap().count(), 1);
        let panicked = registry
            .reserve(access::CurrentUser {
                name: "panic-owner".into(),
                role: Role::Admin,
            })
            .unwrap();
        let unwind = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = WorkerGuard {
                task: panicked.clone(),
                armed: true,
            };
            let mut partial = Temporary::create(&dir).unwrap();
            partial.write(b"partial").unwrap();
            panic!("test export worker unwind");
        }));
        assert!(unwind.is_err());
        assert_eq!(lock(&panicked).status.phase, "failed");
        assert_eq!(fs::read_dir(dir.join("exports")).unwrap().count(), 1);
        fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn cancellation_after_rows_written_removes_partial_file() {
        let dir = std::env::temp_dir().join(format!("keel-export-cancel-{}", new_correlation_id()));
        fs::create_dir(&dir).unwrap();
        let pool = crate::data::open(&dir.join("main.db")).await.unwrap();
        sqlx::query(
            "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 1000) \
             INSERT INTO audit_log(at,actor,action,target,result,correlation_id) \
             SELECT 1,'actor','action','target','ok','' FROM n",
        )
        .execute(&pool)
        .await
        .unwrap();
        let mut registry = Registry::default();
        let task = registry
            .reserve(access::CurrentUser {
                name: "a".into(),
                role: Role::Admin,
            })
            .unwrap();
        let worker_task = task.clone();
        let worker_pool = pool.clone();
        let base = dir.clone();
        // current_thread 上每行 yield 都允许测试在已写第一行后设置取消。
        let worker = tokio::spawn(async move {
            run(
                &worker_pool,
                &base,
                ListParams {
                    start_at_ms: None,
                    end_at_ms_exclusive: None,
                    keyword: "".into(),
                    sort: vec![SortKey {
                        field: "at".into(),
                        descending: false,
                    }],
                    page: 1,
                    page_size: 200,
                },
                &worker_task,
            )
            .await
        });
        tokio::time::timeout(Duration::from_secs(10), async {
            while lock(&task).status.completed_rows == 0 {
                assert!(!worker.is_finished());
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        lock(&task).cancel = true;
        let error = worker.await.unwrap().unwrap_err();
        assert!(matches!(error, KeelError::Cancelled));
        assert_eq!(fs::read_dir(dir.join("exports")).unwrap().count(), 0);
        pool.close().await;
        for _ in 0..40 {
            match fs::remove_dir_all(&dir) {
                Ok(()) => break,
                Err(error) if error.raw_os_error() == Some(32) => {
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(error) => panic!("remove test dir failed: {error}"),
            }
        }
    }

    #[test]
    fn size_boundary_and_terminal_pruning_preserve_exported_files() {
        let dir = std::env::temp_dir().join(format!("keel-export-size-{}", new_correlation_id()));
        fs::create_dir(&dir).unwrap();
        let mut temp = Temporary::create(&dir).unwrap();
        // 不分配 64 MiB，直接测试同一个 writer 的严格字节边界。
        temp.bytes = MAX_BYTES - 1;
        temp.write(b"x").unwrap();
        assert!(temp.write(b"y").is_err());
        let output = temp.publish("kept").unwrap();
        drop(temp);
        let mut registry = Registry::default();
        let task = registry
            .reserve(access::CurrentUser {
                name: "a".into(),
                role: Role::Admin,
            })
            .unwrap();
        {
            let mut task = lock(&task);
            task.status.phase = "completed".into();
            task.status.output_path = Some(output.to_string_lossy().into_owned());
            task.finished = Some(Instant::now());
        }
        registry.prune(Instant::now() + TTL);
        assert!(registry.tasks.is_empty());
        assert_eq!(fs::read(output).unwrap(), b"x");
        fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn registration_database_error_blocks_worker_and_copy_checks_remain_safe() {
        let dir =
            std::env::temp_dir().join(format!("keel-export-db-error-{}", new_correlation_id()));
        fs::create_dir(&dir).unwrap();
        let db = dir.join("main.db");
        let pool = crate::data::open(&db).await.unwrap();
        pool.close().await;
        access::set_current(access::CurrentUser {
            name: "db-error-owner".into(),
            role: Role::Admin,
        });
        let error = start(
            &pool,
            &db,
            AuditQuery {
                start_at_ms: None,
                end_at_ms_exclusive: None,
                keyword: "".into(),
                sort: vec![crate::api::audit::AuditSort {
                    field: "at".into(),
                    descending: false,
                }],
                page: 1,
                page_size: 1,
            },
        )
        .await
        .unwrap_err();
        assert_eq!(error.code(), "KEEL-DB");
        assert!(!dir.join("exports").exists());
        // The failed registration retained a terminal in-memory handle only.
        let started = list(&pool).await.unwrap().into_iter().next().unwrap();
        assert_eq!(started.phase, "failed");
        assert!(started.output_path.is_none());
        let task = owned(&pool, &started.task_id).await.unwrap();
        lock(&task).status.phase = "running".into();
        assert!(matches!(
            save_copy(
                &pool,
                &started.task_id,
                dir.join("running.csv").to_str().unwrap()
            )
            .await,
            Err(KeelError::Validation(_))
        ));
        lock(&task).status.phase = "failed".into();
        assert!(matches!(
            save_copy(
                &pool,
                &started.task_id,
                dir.join("failed.csv").to_str().unwrap()
            )
            .await,
            Err(KeelError::Validation(_))
        ));
        // 模拟暂存/授权等待期间换人或改角色：直接验证实际发布函数拒绝并清理。
        let owner = access::current().unwrap();
        let mut original = Temporary::create(&dir).unwrap();
        original.write(b"copy bytes").unwrap();
        let stamp = original.source_stamp().unwrap();
        let source = original.publish("copy-owner").unwrap();
        drop(original);
        {
            let mut task = lock(&task);
            task.status.phase = "completed".into();
            task.status.output_path = Some(source.to_str().unwrap().into());
            task.source = Some(stamp.clone());
        }
        let target = dir.join("switched.csv");
        for next in [
            access::CurrentUser {
                name: "other".into(),
                role: Role::Admin,
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
            let staged = stage_copy(&source, &stamp, &target).unwrap();
            let temporary_path = staged.path.clone();
            access::set_current(next);
            assert!(matches!(
                publish_copy(&task, staged, &target),
                Err(KeelError::PermissionDenied(_))
            ));
            assert!(!target.exists());
            assert!(!temporary_path.exists());
            access::set_current(owner.clone());
        }
        lock(&task).finished = Some(Instant::now() - TTL);
        assert!(matches!(
            save_copy(
                &pool,
                &started.task_id,
                dir.join("expired.csv").to_str().unwrap()
            )
            .await,
            Err(KeelError::NotFound)
        ));
        assert!(!dir.join("expired.csv").exists());
        fs::remove_dir_all(dir).unwrap();
    }
}
