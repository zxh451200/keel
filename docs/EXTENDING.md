# 新增 Fluent 列表页与编辑页

本文对应 [REQUIREMENTS.md](REQUIREMENTS.md) §9.3：非原作者能在干净环境构建，并完成一个列表页和编辑页。技术约定见 [agents.md](../agents.md)，公共边界与升级步骤见 [PUBLIC_API.md](PUBLIC_API.md)。

2026-11-07 基线：用户已确认此前 Windows Release 构建通过，但本机未重跑该版本。当前 `check_sources.py` 因 l10n/FRB 生成项缺失退出 1；旧台账中的 PASS、待生成和未构建记录均按各自快照理解。本次指南更新不等于新增页面、关闭流程或兼容测试已验收。下列代码按当前手写源码核对，仍须在目标工具链编译和运行。

## 1. 当前接入点

| 职责 | 当前路径（相对仓库根目录） | 扩展方式 |
|---|---|---|
| 页面注册与应用根 | `lib/app.dart` | 在 `KeelApp._pages` 中增加 `UiPage`，由 `FluentApp` 承载 |
| 页面配置 | `lib/ui/ui_page.dart` | `kind/title/navTitle/icon/builder`；builder 接收 context 与 openSelf |
| 桌面外壳 | `lib/ui/shell.dart` | `KeelShell(pages: _pages)` 生成入口与标签；不要复制私有标签管理代码 |
| 列表示例 | `lib/ui/pages/audit_page.dart` | Fluent TextBox、Button、InfoBar、ProgressRing 与分页列表 |
| 编辑示例 | `lib/ui/pages/users_page.dart` | Fluent TextBox、ComboBox、局部校验、保存/取消与 Ctrl+S |
| 完整业务切片（推荐先读） | `lib/ui/pages/customers_page.dart`、`lib/features/customers/state/customers_providers.dart`、`rust/src/api/customers.rs` | 分页/筛选/排序列表 + 对话框表单 + `customers.manage` 权限 + 审计同事务的端到端示例 |
| 查询状态 | `lib/features/audit/state/audit_providers.dart` | 过滤条件、分页 DTO 构造、可覆盖数据源 |
| 草稿与守卫 | `lib/features/users/state/user_draft.dart`、`lib/ui/close_guards.dart` | family 草稿、异步放弃确认、按 kind 注册关闭守卫 |
| 手写调用适配 | `lib/api/bridge.dart` | Widget 经 Provider/服务调用此层，避免直接执行生成 FFI |

旧 Material 展示层已移除；不要引用旧的 features/*/view 页面、appPages 或旧命令注册配置。当前 `UiPage` 没有 commands/canClose 参数，`KeelShell` 没有 canExit/statusTrailing 构造参数。菜单和命令栏在 shell 中实现，页面操作在页面中绑定；如需跨页统一命令，先明确新的接口与回归要求。

## 2. 注册页面

在 `lib/app.dart` 导入页面后，将配置放入 `KeelApp._pages`。下面是现有两项的实际形状，不要再次注册相同 kind：

```dart
UiPage(
  kind: 'audit',
  title: (t) => t.navAudit,
  icon: FluentIcons.list,
  builder: (_, _) => const AuditPage(),
),
UiPage(
  kind: 'new-user',
  title: (t) => t.navNewUser,
  icon: FluentIcons.contact,
  builder: (_, _) => const UsersPage(),
),
```

新业务页按此形状替换 kind、标题、图标与 Widget。`navTitle` 可选，仅用于侧栏短标题，未提供时回退 title；标签仍使用 title。`builder` 的第二参数是 `VoidCallback openSelf`，用于打开/激活该注册页，不是关闭函数，也不是 WidgetRef；页面自身用 ConsumerWidget/ConsumerStatefulWidget 读取 Provider。

kind 必须唯一、稳定，避免占用外壳内置的 `dashboard`。当前外壳按 kind 唯一打开，不提供同类型任意多实例编辑。保留既有 `new-user` 等标识；重命名要检查持久导航偏好和调用方，按公共 API 文档迁移。

## 3. 新增列表：沿审计查询链实现

```text
lib/ui/pages/audit_page.dart (AuditPage)
  → auditPageProvider → auditSourceProvider → bridge.loadAuditPage(query)
  → FRB listAuditLogs(query: query) → rust/src/api/audit.rs
  → rust/src/services/audit.rs → rust/src/data/audit.rs → SQLite
```

1. 在 `lib/ui/pages/` 增加普通 Fluent 页面，功能状态放 `lib/features/<功能>/state/`。只建需要的文件，不预建通用 CRUD 框架。
2. 按审计示例定义过滤状态和 `FutureProvider.autoDispose` 结果，数据源使用 `Provider<Future<结果> Function(查询)>`，便于测试覆盖。查询依赖 `databaseEpochProvider`，数据库恢复/重试后的 epoch 改变时重新读取。
3. 在 bridge 增加手写适配，Rust API 定义跨语言 DTO、入口权限检查；业务规则/事务进 services，参数绑定、分页、排序白名单进 data。只返回一页与过滤后的 total，不整库拉到 Dart 排序，不逐单元格跨语言调用。
4. 页面用 AsyncValue 的 loading/error/data 展示 ProgressRing、`errorText(t, error)` 与重试、空态及结果；控制器在 initState 初始化、dispose 释放。过滤或排序变化回到第 1 页，翻页保留已提交条件。

审计现有查询可以直接由以下表达式构造（在已导入 audit_providers.dart 的 Consumer 页面中）：

```dart
final query = buildAuditQuery(
  const AuditFilter(keyword: '', page: 1),
);
final result = await ref.read(auditSourceProvider)(query);
```

实际页面优先 `ref.watch(auditPageProvider)`，不在 build 中发起上述 Future。`buildAuditQuery(AuditFilter filter, {int? page})` 返回生成的 `AuditQuery`，包含 `keyword`、`sort`、`page`、`pageSize`、`startAtMs`、`endAtMsExclusive`。默认每页 50 条、时间倒序；页码从 1 开始，Rust 页大小允许 1–200。排序为 `AuditSort(field: ..., descending: ...)` 列表，最多 3 个、字段不重复；具体可用字段以 Rust 校验为准，勿拼 SQL。

`AuditFilter.startDate/endDate` 是本地日历日期，结束日包含当天；构造查询时转成 UTC epoch 毫秒时间点的左闭右开范围。次日边界使用日历构造，不能加固定 24 小时；两端同时有值时 Rust 拒绝 start >= end。清除范围用 `copyWith(clearDateRange: true, page: 1)`，传 null 会保留旧值。

刷新可用现有 `refreshAudit(ref)`；当前 AuditPage 按 loading 状态禁用按钮后 invalidate 结果 Provider。审计导出入口见 `lib/ui/actions/audit_export_actions.dart` 与 `lib/features/audit/state/audit_export_provider.dart`，列表查询和导出应复用同一查询构造，不能导出未授权的额外范围。当前 Fluent 列表不等于网格选择、复制、虚拟化等能力全部验收。

### 3.1 完整示例：复制往来单位模块

`customer`（往来单位）是最小的端到端参考实现，含迁移、data/service/api、权限、审计、双语资源与
三层测试；新增自己的业务列表时按这条链复制并按业务改名，不要直接扩展它：

```text
rust/migrations/0005_customers.sql → rust/src/data/customer.rs
  → rust/src/services/customer.rs（校验 + 权限 + 审计同事务）
  → rust/src/api/customers.rs → flutter_rust_bridge_codegen generate
  → lib/features/customers/state/customers_providers.dart
  → lib/ui/pages/customers_page.dart → lib/app.dart 注册
```

要点：列表只向 Rust 要一页；排序字段走白名单；编号等唯一值由数据库约束兜底并映射成 `KEEL-DUPLICATE`；
`viewer` 只读、写操作需要新权限；失败保留对话框输入；业务名称等无法规则识别的敏感字段不进诊断事件。
行选择用「单选 / Ctrl 切换 / Shift 范围 + 锚点」，键盘用 Up/Down/Home/End/Esc，复制走 TSV 并对
`= + - @` 前缀加单引号；批量删除与批量启停是单事务、任一记录缺失整批回滚、逐条写审计——照抄这套语义，
不要逐行调用写接口。测试分别放在 `rust/tests/customer_test.rs`、`test/ui/customers_page_test.dart`，
真实桥接断言在 `integration_test/current_api_test.dart`。

### 3.2 登录门禁（涉及敏感页面时先读）

`lib/app.dart` 在渲染外壳前读取 `authStatusProvider`：`locked` 时只渲染 `LoginPage`，
解锁后才构建 `KeelShell`。新增页面不需要改门禁代码；只要页面依赖 `currentUserProvider`
或 Rust 侧权限，它就自动只在解锁后可达。要扩展登录本身（例如按用户口令、OS 凭据存储），
改 `rust/src/services/auth.rs` 与 `lib/features/auth/`，并在 `docs/REQUIREMENTS.md` §4.1 更新边界；
不要把口令存进配置或普通表字段，也不要让外部配置能打开/关闭登录。

### 3.3 页面命令

页面命令写在 `UiPage.commands`（`lib/ui/ui_page.dart` 的 `UiCommand`）：稳定 id、本地化标题、
可选图标/快捷键提示、`isEnabledProvider` 与 `onInvoke(context, ref)`。外壳把**活动页**的命令渲染到
命令栏和“工具”菜单；没有命令时显示占位文案。示例：`lib/features/audit/ui/audit_shell_commands.dart`、
`backupShellCommands()`、`diagnosticsShellCommands()`、`settingsImportShellCommands()`、
`customerShellCommands()`、`securityShellCommands()`。

约定：命令只调用 Provider/服务，不持有页面 State；快捷键仍由页面自己绑定，命令上的 `shortcutHint`
只用于提示，避免双触发；权限用 `isEnabledProvider` 表达，Rust 边界仍会再校验。

`isEnabledProvider` 必须是 `Provider<bool>`，外壳在 build 顶部直接 `ref.watch`，页面状态
（选中项、忙锁、权限）变化才会重建命令栏。不要传一个在外壳 build 里调用的布尔闭包：
实测那种写法内部的 `ref.watch` 不建立订阅，命令会停在旧状态。

需要页面局部状态（文本框内容、单次预览句柄、确认对话框）的动作，别把整个页面状态提升为全局：
参考 `lib/features/settings_import/settings_import_shell_commands.dart` 的
`SettingsImportPageActions` 注册表——页面在 `initState` 注册、`dispose` 注销，命令只调用已注册实例，
只把“能否用”交给 `isEnabledProvider`。备份页的恢复流程则是把动作抽到
`lib/features/backup/backup_actions.dart`，页面按钮与命令共用同一套确认与身份复查。

### 3.4 页面在最小窗口下的布局

新页面若用「固定页头 + 筛选区 + Expanded 表格」这种列式结构，请把整页包进
`UiScrollablePage`（`lib/ui/widgets/ui_layout.dart`）：可用高度低于 640 时整页滚动并按 640 布局，
正常窗口保持原样。起因是 640×360（1280×720 @200%）下页面只剩约 148px，固定页头与多行筛选会把
表格挤成 `RenderFlex` 溢出——备份、诊断、审计、往来单位、登录保护五页都踩过。空状态用 `UiEmpty` 即可，
它在被挤压时会内部滚动；单行里放长文本的 `Row` 记得给文本 `Expanded`，否则窄窗口会横向溢出。

## 4. 新增编辑：沿用户工作区实现

`UsersPage` 是普通 `ConsumerStatefulWidget`，没有旧 UserEditor/controller 接口。它以 `userWorkspaceEditorId`（当前值 `new-user-workspace`）访问 `userDraftProvider(id)`；编辑其他实体时定义自己的草稿、dirty 判定、Provider 与稳定 ID，不复用用户草稿存其他实体。

`lib/core/state/user_provider.dart` 的真实注入点为：

```dart
const UserService({
  required this.current,
  required this.list,
  required this.create,
  required this.switchTo,
});
```

这是构造签名摘录；四个回调类型依次为 `Future<UserInfo> Function()`、`Future<List<UserInfo>> Function()`、`Future<void> Function(String name, String role)`、`Future<UserInfo> Function(String name)`。页面调用 `ref.read(userServiceProvider).create(normalizeUserName(name), role)`，测试用完整的假 UserService 覆盖该 Provider，避免加载动态库。当前示例只创建用户，不包含编辑已有用户的更新 API。

新增编辑页保留以下生命周期：

1. Widget 持有并释放 TextEditingController、FocusNode、订阅和定时器；在 build 中 watch 草稿以保持 autoDispose family 的监听。应用根 ProviderScope 和启动覆盖见 `lib/main.dart`，不要另建无关容器绕过启动注入。
2. 保存前复查权限、busy、confirming 和本地确认锁。所有保存入口调用同一函数，避免按钮、Enter、Ctrl+S 各自实现提交。当前 UsersPage 用 `validateUserName(t, value)` 返回本地化错误，并聚焦用户名；它没有 Material TextFormField/Form.validate 调用。
3. 用户名归一化对齐 Rust Unicode trim，必填、最多 32 个 Unicode 标量、拒绝控制字符。UI 校验用于提示；Rust 校验、权限、唯一约束与事务仍是最终边界。
4. await 前同步设置 busy 防重复提交。成功或失败返回后先检查 mounted，再读 ref、setState、弹提示或调用上层回调；需要提示/焦点时还需检查当前路由和活动页，过期回调不能改变新实例。mounted 只能证明对象存活，隐藏标签仍可能 mounted。
5. 成功 invalidate 相关列表（用户示例为 usersProvider），重置草稿及控制器；失败保留输入、释放 busy、经 errorText 展示安全提示。取消先经过草稿确认，再清空；取消和保存都不自动关闭标签。

若新增弹窗编辑入口，给它独立草稿 ID，并让遮罩、Esc、返回、应用退出都经过相应守卫；不要假设当前用户样例还存在旧弹窗实现，也不要把“注册工作区守卫”当作覆盖所有模态入口。

## 5. Provider、权限与异步边界

查询数据源默认走 bridge；在 ProviderScope overrides 中替换 source/service，测试无需真实 FFI。业务日期/数字使用 `effectiveFormatLocaleProvider` 配合 intl；界面语言来自本地化资源，显示区域不改变时区或币种。

隐藏标签由外壳保留在 Widget 树中；autoDispose 不会因切换标签自动执行，失去最后监听后才释放。新增列表/草稿应验证切换保留、关闭重开重置和连续开关资源回收。不要依赖旧外壳的 TickerMode/焦点隔离结论；当前行为以 `lib/ui/shell.dart` 和实际回归为准。页面销毁也不表示 Rust 长任务已取消，任务生命周期由其 Provider/API 管理。

UI 的 `hasPermission(user, 'users.manage')`、`audit.export` 等只负责入口提示与禁用；Rust API 必须再次授权。异步对话框、路径选择、用户切换之后，敏感操作应重新检查身份、权限与请求快照。不要将本地角色当成防御本机管理员的安全边界。错误不直接显示异常字符串、路径或 SQL；使用 `lib/core/errors/error_text.dart`，诊断信息走既有脱敏渠道。

## 6. 关闭守卫与应用退出

当前接入文件是 `lib/ui/close_guards.dart`，不是 UiPage 的 canClose 参数：

```dart
typedef PageCloseGuard = Future<bool> Function();
```

页面持有作用域内的 `CloseGuards` notifier，在挂载后注册，dispose 时注销。UsersPage 的接线形状如下（放在 ConsumerState 生命周期中，`_guards` 为 `CloseGuards?` 字段）：

```dart
// initState 中，在 super.initState() 之后：
_guards = ref.read(closeGuardsProvider.notifier);
WidgetsBinding.instance.addPostFrameCallback((_) {
  if (!mounted) return;
  _guards?.register(
    'new-user',
    () => canDiscardUserDraft(context, ref, userWorkspaceEditorId),
  );
});
// dispose 中，在 super.dispose() 之前：
_guards?.unregister('new-user');
```

新页面替换为自己的 kind 和守卫。未注册的页面没有自定义草稿保护；外壳仅对内置 `new-user`、`form_samples` 在注册前拒绝关闭，自定义编辑页须自行确保注册时序。守卫必须返回 Future<bool>，busy/confirming 时拒绝，确认后复查草稿是否改变；只作检查与确认，不提前清空草稿或销毁标签，否则后续检查拒绝时无法保留现场。`canDiscardUserDraft` 的现有签名是 `(BuildContext context, WidgetRef ref, String id)`。

外壳负责将标签关闭、批量关闭和退出请求串联到守卫，并管理全局操作阻断。应用退出入口为 `AppLifecycleListener.onExitRequested`，只覆盖 Flutter 收到的可取消退出请求；强杀、崩溃、断电和不可取消系统退出无法保证拦截。

当前外壳的关闭/退出共用防重锁，批量关闭先完成全部守卫检查，再一次性移除标签；拒绝或异常保留全部页面。等待期间锁住导航与页面交互，并核对标签修订、活动页和守卫注册快照；确认后再次检查 busy。退出另检查全局导出、备份、诊断、配置导入、设置保存和数据库重试，即使审计或任务页没有打开也不绕过保护。内置编辑页须等首帧完成守卫注册；没有自定义守卫的普通页仍默认允许关闭。

工作区使用按 kind 稳定的 key，隐藏页禁用 TickerMode 和焦点；关闭才释放页面。新增 `test/ui/shell_lifecycle_test.dart` 覆盖部分拒绝/异常、并发退出、全局导出和实例保留场景，但本轮未执行 Flutter 测试。仍须验证等待期间状态变化、隐藏草稿、任务阻断与窗口叉号/Alt+F4。平台清单见 [DESKTOP_EXIT_CHECKS.md](DESKTOP_EXIT_CHECKS.md)，其中旧页面名或历史结果需按当前实现解读。

## 7. ARB 与 FRB 生成边界

优先复用 `lib/l10n/app_zh.arb`、`lib/l10n/app_en.arb` 中已有键，例如 actionRefresh/actionRetry/actionCancel、errPermission、emptyList。新增导航、字段、校验或空态文案必须同时补齐中英 ARB、placeholder 元数据，不硬编码产品文案。通过 `AppLocalizations.of(context)` 取值；UTC epoch 时间点在展示时转本地时间，不把本地化文本写入业务数据。

改 ARB 后运行 `flutter gen-l10n`（pub get 后也执行）；改 Rust 公共函数/DTO 后按锁定的 FRB 2.13.0 生成，再更新手写 bridge、调用者和测试。配置见 `flutter_rust_bridge.yaml`，Rust API 模块导出见 `rust/src/api/mod.rs`。生成命令从仓库根运行：

```bash
# 固定 Flutter/FRB 版本并保持两个锁文件不变；推荐使用仓库脚本
bash scripts/generate-frb.sh
```

`lib/src/rust/**`、`rust/src/frb_generated.rs` 和 `lib/l10n/app_localizations*.dart` 禁止手改。FRB 生成物随 API 变更核对，本地化生成文件不入库。本轮仅改文档，不修改 ARB、源码或生成区；当前生成物不完整，最新源码门禁仍报告待生成项，不能据文件存在判定“全部待补齐”。新增依赖须另按 agents.md 与 REQUIREMENTS.md §7 核对来源、锁定版本、许可证及 NOTICE，不能用改生成文件绕过流程。

## 8. 验证与交付

当前存在 `test/widget_test.dart`（Fluent 外壳冒烟、打开创建用户页）与 `test/audit_query_test.dart`（默认/多列排序参数）；本批在 `test/ui/` 补充审计交互、用户/类型表单及 `shell_lifecycle_test.dart` 回归源码，均尚未在本机执行。它们不覆盖全部权限、关闭竞争和桌面键盘。新增业务页需补有意义的 source/service 覆盖测试；旧指南列出的 test/features 和 test/core 旧 UI 回归不能当作仍存在或已运行。

在工具链可用的环境，从仓库根运行以下命令；这里是待执行说明，不是本轮运行报告：

```bash
python3 -B scripts/check_sources.py  # 当前若有待生成项应退出 1
flutter analyze
flutter test
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml
pwsh -File scripts/integration-check.ps1 -Device windows
```

Windows 的完整生成/门禁入口与参数见 [README.md](../README.md) 及 `scripts/verify.ps1`，独立桥接集成执行器见 `scripts/integration-check.ps1`。源码检查只核对资源、导入和依赖等静态问题，不代替编译、真实 FFI、许可证、安全扫描或平台验收。
执行器为每个集成入口独立启动应用进程，创建并验证归属的临时数据目录，结束后恢复原环境变量；不要复用真实用户数据目录或绕过 ownership marker 检查。

新开发者应在隔离的 KEEL_DATA_DIR 中验证：注册页可打开；列表加载/空/失败重试/筛选分页参数正确；编辑无权限禁用、校验首错、重复提交阻断、失败保留、成功重置；切换保留与关闭释放；保存快捷键不误触背景页；批量关闭/应用退出拒绝时保留现场。重复开关页面检查控制器、焦点、订阅和内存；中英、窄窗口、高 DPI、Tab/Shift+Tab 和 Windows 关闭行为需要实际记录。交付列明命令、结果和未覆盖项，保留既有 Windows 构建基线，同时为新改动重新取证。
