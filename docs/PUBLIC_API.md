# 公共 API 范围与升级迁移契约

本文件明确二开调用边界，配合 [EXTENDING.md](EXTENDING.md) 使用。技术基线见 [agents.md](../agents.md) §3.3、§7，放行条件见 [REQUIREMENTS.md](REQUIREMENTS.md) §9.3。当前是源码内扩展的桌面应用，没有独立的动态插件 SDK；Dart 符号可导入、Rust 符号为 pub，都不自动意味着永久稳定。本文列出的手写入口表示当前源码契约；当前 l10n/FRB 生成门禁仍有缺项，因此不表示生成、编译、兼容性测试或平台验收已通过。

2026-11-07 用户已确认此前 Windows Release 构建基线；本机未重跑该版本，且当前 `check_sources.py` 因 l10n/FRB 生成项缺失退出 1。这不表示公共 API 兼容矩阵、关闭流程或本文迁移步骤已执行。

## 1. 哪些属于兼容性评估范围

| 层次 | 范围与源码入口 | 维护约定 |
|---|---|---|
| 跨语言业务契约 | `rust/src/api/mod.rs` 导出的 API 函数、请求/响应 DTO、枚举、错误码；对应 `lib/src/rust/api/` 生成类型 | 作为公共接口评估签名和语义兼容性，不能暴露 SQLx row、池、事务或任意 SQL |
| Dart 手写调用入口 | `lib/api/bridge.dart` 中业务适配函数与其输入输出 | 二开优先通过此层调用；变更时同步调用方、Provider、测试与本文迁移说明 |
| 持久化兼容 | `rust/src/data/` 下迁移、`rust/src/config/mod.rs` 的配置版本与读取规则 | 数据格式也有兼容要求；字段默认、迁移、回滚限制必须记录，禁止靠手改版本号兼容 |
| 当前源码扩展入口 | `lib/ui/ui_page.dart` 的 UiPage、`lib/ui/shell.dart` 的 KeelShell、`lib/ui/close_guards.dart` 的 PageCloseGuard/CloseGuards | 是当前二开接入点；随 UI 演进可变，变更须给迁移步骤，不承诺为独立稳定 SDK |
| 当前测试注入点 | `lib/features/audit/state/audit_providers.dart` 的 auditSourceProvider、`lib/core/state/user_provider.dart` 的 userServiceProvider 等 | 支持替换副作用；具体业务 Provider/草稿结构随功能演进，不能将全部 Riverpod 状态视为稳定接口 |

内部实现包括 `lib/ui/` 的私有 State、布局、菜单构造、焦点策略、widgets/actions/pages 细节，Rust services/data 内部函数与数据库表结构。业务代码不应绕过 bridge 依赖生成器内部类、底层 transport、原始 FFI 符号或数据库文件。FRB 生成类型反映公共 DTO；生成文件的排版、辅助方法、序列化内部实现与内存布局不构成额外稳定承诺，Dart 与 Rust 动态库必须配套交付。

`AppLocalizations` 是 ARB 生成的界面资源访问器，键和占位符变更需同步 Widget；它不是业务存储协议。不要把翻译字符串或显示区域格式写入持久化标识。

## 2. 当前可操作的签名

下表摘录手写适配签名，完整类型定义以源码与同版本生成物为准，不代表每个模块都已有兼容性测试。

| 功能 | 当前入口 | 关键语义 |
|---|---|---|
| 审计分页 | `Future<AuditPage> loadAuditPage(AuditQuery query)` | keyword、sort、page、pageSize、startAtMs、endAtMsExclusive；分页/过滤/排序在 Rust 执行 |
| 创建用户 | `Future<void> createLocalUser(String name, String role)` | 用户服务 create 回调同形状；Rust 再校验权限和输入，当前没有通用实体更新 API |
| 诊断事件 | `Future<List<DiagnosticEvent>> loadDiagnosticEvents(DiagnosticEventQuery query)` | DTO 携带 limit/minLevel/correlationId；不要沿用旧位置参数 |
| 诊断包预览 | `Future<DiagnosticPackPreview> preparePack(DiagnosticPackRequest request)` | 先展示完整 content 再确认；预览身份不能用于新采集内容 |
| 诊断包导出 | `Future<String> exportPreparedPack(String previewId)` | 对应 Rust export_prepared_diagnostic_pack(preview_id)，不能绕过预览 |
| 设置保存 | `Future<void> saveSettingsToRust(Settings settings)` | 异步；Settings 含 language/theme/formatLocale，修改一个字段时保留其他当前值 |
| 配置导入 | `Future<ExternalConfigPreview> prepareSettingsImport(Uint8List bytes)` → `Future<void> confirmSettingsImport(String previewId)`；文件入口为 `prepareSettingsFileImport(String path)` | 预览与确认是一次性、绑定当前身份/权限的两步；确认前复查并只合并允许偏好，不能把 previewId 当作通用写入句柄 |
| 外部诊断文件 | `ExternalDiagnosticService.prepareFile(String path)` / `chooseFile(...)` | 文件选择只返回路径，准备阶段负责受限读取、筛查和绑定快照；仍需按平台验证通道生命周期 |
| 审计导出另存 | `Future<String> saveAuditExportCopy(String taskId, String destination)` | 仅本人、`audit.export`、completed 且在终态 TTL 内；返回目标路径，不授予原任务或任意文件写入权限 |
| 审计导出历史 | `Future<AuditExportHistoryPage> listAuditExportHistory(int page, int pageSize)` | 只读、按当前身份隔离；历史条目不授予取消或另存句柄，启动恢复不自动重放 |
| 登录保护 | `Future<AuthStatusDto> loadAuthStatus()`、`Future<bool> signInWithPassword(String password)`、`Future<void> lockApplication()`、`Future<void> setLoginPasswordInRust(String? current, String next)`、`Future<void> setLoginRequiredInRust(bool enabled, String password)` | 口令只发给 Rust 校验，桥接不保存/不回显；开启后启动停在登录页；开关不进入可导入配置；失败登录返回 false 并固定延迟 200ms |
| 往来单位（二开示例） | `Future<CustomerPage> loadCustomers(CustomerQuery query)`、`Future<int> createCustomerInRust(SaveCustomerRequest request)`、`Future<void> updateCustomerInRust(int id, SaveCustomerRequest request)`、`Future<int> deleteCustomersInRust(List<int> ids)`、`Future<int> setCustomersActiveInRust(List<int> ids, bool active)` | 分页/过滤/排序在 Rust；读取不分角色，写入需要 `customers.manage`；编号唯一由数据库约束兜底并映射 `KEEL-DUPLICATE`；批量删除/启停为单事务、任一记录缺失整批回滚、单批上限 200 并逐条审计；这是示例契约，复制时按业务改名而不是扩展它 |

页面注册构造为 `UiPage(kind: ..., title: ..., navTitle: ..., icon: ..., builder: ...)`，navTitle 可省略。builder 类型是 `Widget Function(BuildContext context, VoidCallback openSelf)`；外壳是 `KeelShell({super.key, required List<UiPage> pages})`。关闭接口是 `Future<bool> Function()`，由 `CloseGuards.register(String kind, PageCloseGuard guard)`、`unregister(String kind)` 接入。更详细的挂载/注销步骤见二开指南第 6 节。

## 3. 现有破坏性变更的迁移

| 旧调用或假设 | 当前迁移方式 | 必须检查 |
|---|---|---|
| 旧 Material WorkspacePage/WorkspaceShell、appPages、单参数 builder | 页面改为 `lib/ui/pages/` 下的 Fluent Widget；在 `KeelApp._pages` 注册 UiPage，builder 使用两个参数，交给 KeelShell | 编译、入口标题、kind 唯一性、关闭重开、焦点与快捷键；不能只替换类名 |
| 页面配置中的 commands/canClose 或外壳 canExit/statusTrailing 参数 | 当前 UiPage/KeelShell 没有这些参数；页面保存/取消绑定同一真实处理函数，关闭通过 closeGuardsProvider 注册 | 守卫仅检查/确认，不能提前清草稿；外壳批量检查后统一移除，并复查快照/busy；新增生命周期回归仍须运行，不保留旧 controller/命令示例 |
| 旧用户 UserEditor 与弹窗/controller 接线 | 当前示例是 UsersPage + userDraftProvider(userWorkspaceEditorId) + UserService | 新增其他入口须独立草稿 ID 与关闭/退出保护，旧弹窗不存在不能当作可复用组件 |
| 旧诊断事件两个位置参数 | 构造 DiagnosticEventQuery 后调用 loadDiagnosticEvents(query)，Rust 入口 recent_events 接收 query | 更新 DTO、适配和测试，再生成 FRB；过滤在有限缓冲内先执行再限量 |
| 直接采集并导出诊断包 | prepare_diagnostic_pack(request) → 展示预览 → export_prepared_diagnostic_pack(preview_id)；Dart 用 preparePack/exportPreparedPack | 类别改变、失败或过期后重新准备；不能复用旧确认授权新内容 |
| 同步 Rust save_settings 或省略显示区域字段 | Rust 调用 await；Dart 保持 Future<void>；Settings 构造包含 nullable formatLocale，null 表示跟随系统 | 同步调用者、FRB 生成物、语言/主题字段保留与配置兼容；不绕过 services 直接重建配置文件 |
| 无日期边界的审计 DTO 构造 | AuditQuery 使用可选 nullable startAtMs/endAtMsExclusive；用 buildAuditQuery 复用日历转换 | 包含开始、排除结束，列表/COUNT/导出条件一致；空范围为 null；这两个生成 Dart 参数可省略，新增范围行为须同步测试 |

这些是当前升级映射，不表示旧接口还保留兼容别名。普通窗口叉号/Alt+F4 是否进入可取消请求链路须在目标平台验证；平台强杀、崩溃与断电不在守卫保障内。

## 4. 后续变更如何交付

框架升级遵循 SemVer，并在 [CHANGELOG.md](../CHANGELOG.md) 记录新增、变更、移除、修复与迁移。当前开发阶段也必须逐项记录破坏面，不能将尚未建立的稳定版本或弃用周期当作既成承诺。稳定版本发布后，公共契约的不兼容修改按主版本变更管理；内部实现重构若改变本指南的源码接入方式，同样更新示例与迁移说明。

新增必填参数、字段删除/改名、null 语义或默认值改变、同步改异步、错误码/权限语义变化、排序/分页边界改变，以及持久化格式变化，都需要兼容性评估。即使只增加字段，也应检查 Dart 构造器是否要求调用者提供该值；“nullable”不保证源码兼容。

破坏性变更的交付契约是：

1. 写清旧调用、替代签名、行为差异、受影响文件和最低配套版本；能保留安全适配时明确弃用入口与移除版本，不能保留时直接声明不兼容。
2. 同步 Rust API/DTO、模块导出、手写 Dart bridge、Provider/Widget 和测试；用锁定版本 FRB 正常生成，核对生成差异，不手改生成文件。新增产品文案经中英 ARB 与 gen-l10n 生成。
3. 涉及数据库/配置时提供版本迁移、旧数据读取测试、默认值与降级限制；未经证据不能声称可逆。保留真实用户数据，用隔离副本验证备份/恢复，不以清库代替迁移。
4. 在干净 Windows 环境构建示例应用，并照二开指南实际接入一个列表和编辑页；运行适当 Rust/Dart 测试与真实桥接，记录键盘、资源释放、关闭守卫和平台退出结果。指南更新或测试文件存在不能代替这一步。
5. 发布前把实际通过、失败与待验项写入交付记录；文档若仍与并行修改的关闭接口不一致，应先修正文档再放行。

现存轻量回归入口为 `test/widget_test.dart`、`test/audit_query_test.dart`、区域设置/文件选择/导出历史测试，真实桥接入口在 `integration_test/`，Rust 测试在 `rust/tests/`。生成前先执行 `bash scripts/generate-frb.sh`；随后再运行 `flutter analyze`、目标 Flutter/Rust 测试和 `pwsh -File scripts/integration-check.ps1 -Device windows`。这些命令分别覆盖生成、静态分析/测试和真实桥接；命令未执行时不能记为兼容性通过。它们不是完整的二开公共 API 兼容测试套件；§9.3 的独立开发者接入验收仍须另行执行并保留证据。
