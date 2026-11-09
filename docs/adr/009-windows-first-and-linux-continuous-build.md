# ADR-009：Windows 优先与 Linux 持续构建

- 日期：2026-11-02
- 状态：沿用 Windows 首发、Linux 可移植基线；CI 配置已有，当前完整桌面平台支持尚未验收。

## 背景与依据

依据 `AGENTS.md` §0、§1、§2、§3、§10，以及 `docs/REQUIREMENTS.md` §2、§8、§9、§10。Windows 是首发桌面目标，Rust 核心须避免绑定 Win32；Linux 可移植性通过持续检查尽早发现退化，正式桌面支持仍需目标环境证据。

核对实现：`.github/workflows/ci.yml`、`.github/workflows/release.yml`、`scripts/verify.ps1`、`rust-toolchain.toml`、`rust/src/config/mod.rs`，以及 `docs/WINDOWS_RELEASE_CHECKS.md`、`docs/DESKTOP_EXIT_CHECKS.md` 的未执行验收项。

## 已选设计与当前实现

1. 沿用 Rust 核心、Flutter 独立桌面 UI 与 FRB 生成桥接。业务逻辑和数据库访问留在 Rust，平台差异收敛在有限适配处，不通过浏览器/WebView 承载主界面。
2. 数据目录与安装目录分离：Windows 使用 APPDATA 下 Keel；Linux 优先 XDG_DATA_HOME，否则 HOME 下 .local/share/keel。路径和文件 API 按平台处理，不以当前工作目录或 Windows 绝对路径作为业务约定。
3. CI 对 PR 和 main 推送配置 windows、linux-rust、linux-desktop 三个作业，另有独立 Windows 发布候选工作流；当前覆盖边界如下：

| 作业 | 源码配置的检查 | 不代表的结论 |
|---|---|---|
| windows，windows-latest | FRB 重新生成及提交差异检查、l10n 生成、Rust fmt/clippy/test、Dart format/analyze/test、真实 Rust 库桥接端到端、安全扫描 | 工作流尚无本次运行证据；不是完整 Release、安装或所有桌面交互验收。 |
| linux-rust，ubuntu-latest | Rust fmt/clippy/test | 未构建 Flutter Linux 应用，未验证 Linux 桌面、插件、打包或所有发行版。 |
| linux-desktop，ubuntu-24.04 | 显式安装 GTK3/构建/Mesa/Xvfb/DBus/字体依赖并检查 pwsh，复用固定 SHA Flutter Action 与全局 Flutter/FRB 版本；按锁文件获取依赖、FRB/l10n 生成与差异门禁、Dart 门禁、Linux Release 构建、Xvfb/DBus 下逐 entry 隔离真实桥接，结束后复查生成物与锁文件 | 仅有工作流源码，尚未执行；不代表生成、编译、桌面测试或正式 Linux 平台验收通过。 |
| Windows 发布候选 | 独立工作流调用 verify.ps1 -BuildRelease，随后安全扫描并组装证据 | 只是候选流水线配置；签名、Defender 和正式发布另见 ADR-011。 |

4. 当前 CI 指定 Flutter 3.47.8 与 FRB codegen 2.13.0；Rust 工具链文件选择 stable 并要求 rustfmt/clippy。stable 是滚动通道，runner 的 latest 也会变化，不能称为完整工具链/系统镜像的不可变锁定。实际版本需要在构建证据中记录。
5. 本地 Windows 验证入口是 verify.ps1；首次同步未解析依赖用 ResolveDependencies，并在编译前执行安全门禁。生成文件禁止手补；已有阶段 0 桥接结果只适用于当时样例，不能推广为当前新增功能已通过。

## 替代方案与后果

| 方案 | 取舍与后果 |
|---|---|
| 只维护 Windows，未来再移植 | 初期配置少，但平台耦合难以及时发现；保留 Linux Rust 检查，并已补 Linux 桌面构建/桥接作业源码，待实际执行。 |
| 立即承诺 Windows/Linux 同等完整支持 | 缺少 Linux Flutter、插件和目标环境证据；采用 Windows 首发及分层验证，明确剩余缺口。 |
| 以 Linux Rust 编译成功替代桌面验收 | 无法覆盖 UI、文件交互、字体和剪贴板；正式支持仍按需求完成目标桌面测试。 |
| 为每个平台复制业务核心 | 增加规则和迁移分歧；保持共享 Rust 核心及有限平台适配。 |

Windows 优先集中首发验证资源，Linux Rust 检查用于发现核心可移植性问题；新增 linux-desktop 源码用于覆盖 Flutter Linux 构建和真实桥接，但尚未运行，Linux UI 与原生交互仍需目标环境证据。

## 未验证、缺口与待外部决策

- 本次没有执行远端 CI；本机只有 Python，无法运行 cargo fmt/clippy/test、flutter analyze/test、FRB 生成或桌面构建。当前生成物与新增依赖仍有待同步项。
- Windows 真实 runner、完整 Release、DPI/键盘/文件锁/Unicode 路径、普通窗口叉号和 Alt+F4 的可取消退出行为，须按现有清单逐项记录结果。
- linux-rust 继续只覆盖 Rust 层；Linux Flutter 编译与真实桥接已纳入新增 linux-desktop 作业源码，尚未执行，锁文件与生成物待同步。正式支持的 Linux 发行版、架构、系统依赖和打包格式需在首个可发布版本前由维护者明确，并核验文件选择、剪贴板、快捷键、字体与桌面集成；Ubuntu 24.04 CI 配置不等于正式支持范围已确定。
- 精确 Rust 补丁版本及 runner 镜像固定程度仍待发布阶段落实；本 ADR 不擅自改工具链，也不扩展 macOS、多窗口或全发行版支持承诺。
