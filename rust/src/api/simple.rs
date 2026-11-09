#[flutter_rust_bridge::frb(sync)] // Synchronous mode for simplicity of the demo
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
    // 日志初始化失败不应阻止应用启动，所以忽略结果。
    let _ = crate::diagnostics::logging::init_default();
    crate::diagnostics::logging::install_panic_hook();
}
