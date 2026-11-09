# Keel — 技术基线与开发规范

最后更新：2026-11-09。来源：《Keel Rust + Flutter 通用桌面 Admin 技术总方案 v1.1 安全加固版》、安全发布检查清单 v1.1、2026-10-31 目录与分层评审结论、2026-11-01 阶段 0 重建与桥接验证结论。本文件是技术基线与开发规范的唯一权威；产品需求与详细规范见 `docs/REQUIREMENTS.md`（读取规则见 §8）。历史版本文档只在仓库外归档，不进仓库。README 只做入口。

## 0. 当前状态（先读，别假设）

- 2026-11-09 网格语义树断言：trina 单元格无显式 Semantics（数据靠内部 Text 隐式暴露），
  往来单位网格外层加 `Semantics(container: true, label: t.navCustomers)` 区域标签（复用现有
  ARB 键）。新增 `test/ui/customers_grid_semantics_test.dart` 5 项：区域/表头/单元格进入语义树、
  隐藏内部列（备注/原始 kind）不泄漏、只读角色同等暴露、中文标签随语言切换、翻页换行；
  灵敏度已验证（临时移除标签即失败）。门禁实跑：`flutter analyze` 0 项、`flutter test`
  **200 项全过**（195 → +5）、`check_sources.py` PASS、format 无差异。Rust 未改，未重跑 cargo 门禁。
  这是语义树层面回归，**不是读屏验收**；Narrator/Orca 朗读与焦点顺序仍 NOT RUN（X06）。

- 2026-11-09 网格锁定与首个生产接线：根依赖加入 `trina_grid: 2.4.0`（MIT，ADR-012），
  根锁由 pub.dev 重解为 110 项（102 hosted，新增 52 包：MIT/BSD-3-Clause/Apache-2.0，
  无 copyleft/未知；`jni` 被注册为 Windows/Linux 的 FFI 插件）。往来单位示例页
  （`lib/ui/pages/customers_page.dart`）改用网格行选择/虚拟滚动/快捷键；`code/name/phone/email`
  支持单元格内联编辑与 Ctrl+V 区域粘贴（整段经新增 `update_customers` 一次事务提交），
  kind/status/备注仍走对话框。Ctrl/Shift 多选、TSV 复制、只读角色、分页与最小窗口行为由测试固定；
  `flutter test` **200 项全过**（含同批语义断言），analyze 0、format 0；Rust `cargo test` 173 项（含批量更新回归）。
  1M 行客户表分页/过滤/排序有手工规模测试（`rust/tests/customer_scale_test.rs`，默认 ignored，
  用 `--ignored` 显式运行）。
  `integration-check.ps1 -Device windows` 在含语义标签的最终树上 **7/7 PASS**
  （`build/reports/integration-windows-13451c161d1641c9901e7d31f22c1422/summary.json`，
  14:22–14:35 UTC，native 构建含 `jni` FFI 插件；此前 11:12 的 504db0d2 是接入批次快照）。
  平台矩阵（真实 OS 焦点/DPI/读屏/Linux）仍 NOT RUN。

- 2026-11-09 页面滚动结构修正：审计 / 备份 / 诊断 / 登录保护 / 往来单位共用的 `UiScrollablePage`
  原先回退阈值固定 640（往来单位显式 720），在 1280×720 @125%（页面可用高度约 440）就会触发整页
  滚动，与表格/列表自身的纵向滚动条叠成两条（用户截图反馈）。改为宽页面（可用宽度 ≥ 760）只在
  高度 < 420 时回退，窄页面沿用原阈值与布局高度（640 / 往来单位 720），640×360 行为不变；审计横向
  `RawScrollbar` 与往来单位横向 `Scrollbar` 改为内容溢出时才常显（此前无溢出也会画一条铺满整轨的
  假滚动条）；审计冻结列只在最右侧可见分栏保留纵向滚动条，其余分栏关闭滚动条以免并排多条。
  新增 `test/ui/page_scroll_test.dart` 6 项：1024×576 下五页无溢出，且审计分页页脚 / 往来单位页码
  直接可见（把阈值临时恢复 640 时这两项即失败，已验证灵敏度）。门禁实跑：`flutter analyze` 0 项、
  `flutter test` 186 项全过（180 → +6）、`check_sources.py` PASS、改动文件 format 无差异。Rust 未改，
  未重跑 cargo 门禁；滚动条外观与 125% 真机窗口仍需人工复核。

- 2026-11-09 Rust edition 2024：`rust/Cargo.toml` 由 2021 升到 2024（`unsafe extern`、unsafe `set_var`、
  let-chain 折叠等最小迁移）；因 FRB 生成物仍按旧样式输出且 CI 有生成差异门禁，新增
  `rust/rustfmt.toml` 固定 `style_edition = "2021"`，待 FRB 能产出 2024 样式后删除。门禁实跑：
  `cargo fmt --all --check`、`clippy --locked --all-targets -D warnings`、`cargo test --locked`
  全绿（26 个测试二进制、172 项通过，lib 95 项，0 失败）；Cargo.lock 未变。
  同批补 I02 自动化：新增 `test/core/format_locale_system_test.dart`、`test/ui/regional_display_test.dart`、
  `test/ui/shell_regional_menu_test.dart` 共 13 项，覆盖系统 locale 跟随/显式固定、视图菜单落盘、
  审计时间列按区域与时区重排；根 `flutter test` 本批 167 → 180，同日后续批次到 186，analyze 0、format 0。
  真实 OS 区域事件、DST/负偏移与平台矩阵仍未验证。

- 2026-11-09 Windows 桌面交互与 P02 证据：新增第 7 个集成入口
  `integration_test/interaction_memory_test.dart`，在真实窗口 + 真实 Rust 库下验证
  审计表 ↓/↑/End/Home/Esc 选择、Ctrl+K 浮层按键不穿透且 Esc 后恢复、关闭标签后按键不误触，
  以及备份页选择/Enter 确认/Cancel/Esc 行为（用按钮可用性与行高亮断言，不动真实剪贴板）；
  同进程 5 轮打开-筛选-翻页-关闭-重开采样 RSS（接入 trina 后，2026-11-09 复跑）：
  584.1→600.9→623.3→624.4→636.1→631.5 MiB，首末 +47.4 MiB，无遗留 busy、末轮可重开。
  `integration-check.ps1 -Device windows` **7/7 PASS**
  （`build/reports/integration-windows-13451c161d1641c9901e7d31f22c1422/summary.json`，
  14:22–14:35 UTC；接入批次的首跑为 504db0d2，RSS 序列随运行波动）。
  边界：RSS 为 debug 构建 + 测试种子，隐藏页长任务、CPU/订阅计数、Linux 与 DPI/读屏仍 NOT RUN；
  Ctrl+W 仅在外壳焦点子树内生效（点工具条后焦点在外壳外）已记录，未改行为。


- 2026-11-09 最小窗口兜底：新增 `UiScrollablePage`（可用高度 < 640 时整页滚动并按 640 布局），
  备份 / 诊断 / 审计 / 往来单位 / 登录保护五页接入；`UiEmpty` 在可用高度小于内容时改为内部滚动；
  往来单位页脚在 < 560 宽时换行两行，登录保护状态行改为 `Expanded` 文本。起因是补命令栏测试时在
  640×360（1280×720 @200%）实测到既有溢出：备份 69px、诊断 271px、审计 102px、
  往来单位横向 197px + 纵向 41px、登录保护横向 89px，命令栏本身未超宽。
  新增 `test/ui/command_bar_small_window_test.dart`（8 项）逐个打开备份 / 诊断 / 导入设置 / 审计 /
  往来单位 / 登录保护 / 任务 / 表单样例，断言无溢出异常且命令栏不超宽；桥接样例页在 build 时即调用
  Rust，widget 测试没有动态库，改由集成测试覆盖。
  门禁：`flutter analyze` 0 项、`flutter test` 167 项全过，`integration-check.ps1 -Device windows`
  在最终代码上 **6/6 PASS**
  （`build/reports/integration-windows-791dca6e46d5476da6c0190947a45416/summary.json`，06:16–06:23 UTC）。

- 2026-11-09 页面命令补全：`UiCommand` 的可用性改为 `isEnabledProvider: Provider<bool>`，外壳在 build
  顶部统一 `ref.watch`。原来的 `isEnabled(ref)` 布尔闭包虽然在外壳 build 中被调用，闭包内部的
  `ref.watch` 实测不建立订阅——列表选中后命令仍停在禁用态，外壳不再重建；审计 / 往来单位 / 登录保护
  的命令同批迁移。备份页列表改为单选（点击、↑/↓/Home/End/Esc、Enter 触发恢复，行高亮 +
  `Semantics.selected`），命令栏新增「立即备份 / 恢复所选 / 取消待恢复」；恢复动作抽到
  `features/backup/backup_actions.dart`，页面按钮与命令共用同一套确认、身份复查与忙锁，
  选中项不在最新列表时命令禁用。诊断导出把页面 `_exportOpen` 提升为 `diagnosticExportOpenProvider`，
  命令栏新增「导出诊断包」，对话框期间命令同步禁用。导入设置页用 `SettingsImportPageActions` 注册表
  （仿 `closeGuards`）把文件导入 / 取消 / 重载交给外壳，预览与确认仍留在页内（依赖文本框与单次预览句柄）。
  门禁实跑：`flutter analyze` 0 项、`flutter test` 159 项全过（新增 10 项）、`check_sources.py` PASS，
  `integration-check.ps1 -Device windows` **6/6 PASS**
  （`build/reports/integration-windows-dea034954b5f4787b132763b74fe2a64/summary.json`，03:08–03:19 UTC）。
  Rust 未改，未重跑 cargo 门禁。集成测试覆盖的是应用启动与既有审计/登录/桥接/网格条目，
  没有点按新加的三个命令；真机 DPI/读屏与备份页键盘选择仍需人工验收。

- 2026-11-08 偶发测试与安全门禁复核：`settings_import_audit` 的偶发失败是真实竞态，不是环境噪声——
  同一测试二进制内的 7 个 `#[tokio::test]` 并行执行，共享进程级当前用户（`access::CURRENT`）；
  临时注入延时即可双向复现：主测试对 Viewer 的 `unwrap_err()` 拿到 `Ok`，另一测试的 `unwrap()`
  拿到 `PermissionDenied("settings.import")`。改为文件级 `SERIAL` 串行后连跑通过；保留同一延时
  再加锁的控制实验也通过，证明修复来自串行化。`backup_test` 的 `#[cfg(unix)]` 分支有同类隐患
  （第二个 tokio 测试 `access::init` 覆盖身份），同批加锁；该分支本机 Windows 不编译，待 Linux CI 验证。
  安全门禁：`cargo audit` 自带 fetch 仍报 `failed to prepare fetch` / IO error（本机到 github 的
  传输层问题，非代码），但同一轮 `cargo deny fetch db` 成功取得干净快照 HEAD `309392b1`
  （与远端一致）；audit 改用该快照 `--db <快照> --no-fetch` 后 exit 0（1422 条公告、201 个依赖、
  无漏洞），deny-advisories `advisories ok`，脚本的离线降级设计不变。完整 `security-check.sh`
  本轮未跑完：卡在 `flutter pub deps`，超过脚本 600s 仍未返回（本机 `flutter --version` 30s、
  `pub deps` 90s 也超时，cache/lockfile 与两个孤儿 dart 时间吻合），与公告库无关；
  `capture()` 的超时对 `.bat` 子树是否真正生效需单独立项核查。发布仍以 CI 联网判定。

- 2026-11-08 依赖升级增量：两项依赖各按独立批次升级并全门禁验证。`sqlx` 0.8.6 → 0.9.0：
  `query*()` 的 SQL 参数改为 `SqlSafeStr`，`data/audit.rs` 的 COUNT 语句改为 `&'static str` 常量，
  白名单拼出的 ORDER BY 与两处测试内固定 DDL 用 `sqlx::AssertSqlSafe` 并注明依据；
  `cargo update` 重解析锁文件（顺带移除不再需要的 rsa/zeroize 传递依赖，tokio 等直接依赖未变）。
  `flutter_riverpod` 2.6.1 → 3.5.0（pubspec 声明 `^3.4.3`）：StateProvider/StateNotifierProvider
  家族改经官方 `flutter_riverpod/legacy.dart` 导入（3.x 保留 2.x 语义含 autoDispose/family，转 Notifier
  留作后续重构）；`valueOrNull` → `.value`（14 处）；`Ref` 去泛型参数；修复一处真实 3.0 行为破坏——
  审计导出 Notifier 在 `ref.onDispose` 里读 `state` 触发「生命周期回调禁用 Ref」断言，改用普通字段
  `_lastTask` 镜像任务句柄。门禁实跑：cargo fmt/clippy -D warnings/test 全绿（89 单测 + 全部集成测试，
  首轮 settings_import_audit 一项在并行负载下偶发失败，单跑与全量复跑均通过）；`flutter analyze` 0 项；
  `flutter test` 105 项全过；`integration-check.ps1 -Device windows` 6 entry 全 PASS（两轮升级后各跑一次）；
  `check_sources.py` PASS；pubspec.lock 50 个 url 全为 pub.dev 未被镜像改写。security-check 本机结果：
  deny-licenses/bans/sources、osv-scanner、gitleaks、hygiene、dart-deps PASS，新依赖许可均在白名单内；
  cargo-audit 公告库拉取网络失败、deny-advisories 因脚本传 `--disable-fetch` 与 cargo-deny 0.20.2 不兼容
  而 UNSURE、rust-licenses 状态识别 UNKNOWN——均为与升级无关的既有环境/工具版本问题，发布以 CI 联网判定。
  另将 trina_grid 生态备注写入 docs/GRID_POC.md 与需求文档 §6（pluto_grid 仍维护但社区重心迁移，
  POC 时两者对比后择一锁定）。Rust edition 2021 → 2024 择机另做。

- 2026-11-08 安全扫描脚本修复增量：security_check.py/security-check.sh 修了四处真实缺陷并全量实跑验证——
  (1) deny-advisories 的 `--disable-fetch` 已被 cargo-deny 0.20.x 移除导致命令必然报错，且该报错含
  "fetch" 字样被误分类为网络型 UNSURE；改为按 help 探测支持形态（新版用全局 `--offline`），
  且仅在 RustSec 快照 verified 时才钉定检查（此前 fetch 失败也会带着空缓存路径去查）；误分类排除
  参数错误输出。(2) rust-licenses 版本探测经 `cargo install --list`，CARGO_HOME 指向非工具安装目录时
  拿不到版本被判 UNKNOWN；去掉该变量重探一次。(3) security-check.sh 硬编码 python3，Windows 开发机
  只有 python（python3 是商店占位）导致静默退出；改为 python3 优先、缺失回退 python。(4) 测试夹具
  Windows 化：test_security_check 的 python3 符号链接在 Windows 触发加载器按链接目录找 DLL
  （0xC0000135 → MSYS 静默 127），工具桩为无扩展名 bash 脚本被 shutil.which/PATHEXT 与 capture()
  拒绝，夹具改为 python3 用 bash 桩（exec 真实解释器）、工具桩按宿主 OS 生成批处理/POSIX 双形态；
  test_grid_poc 的 `with sqlite3.connect()` 只提交不关闭连接，Windows 上句柄挡住临时目录清理（0x20
  文件占用），改显式 commit/close；test_collect_signature_evidence 的 CLI 测试泄漏 "FAIL:" 子进程
  输出到套件 stdout，包 redirect_stdout。结果：Python 工具回归 89 项全过（1 skip 合理，此前本机
  8 error 2 skip 根本跑不起来）；security-check.sh 端到端实跑本机结论从 FAIL(exit 1) 修正为
  INCOMPLETE(exit 3)——rust-licenses/deny-licenses/bans/sources/osv/gitleaks/hygiene/dart-deps 全 PASS
  （新依赖许可均在白名单），deny-advisories UNSURE 与 audit PARTIAL 为本机到 RustSec/OSV 公告库
  网络受限的诚实降级，发布门禁仍以 CI 联网判定为准。
  后续修正：security-check.sh 的回退判定再修一处——Git Bash PATH 里的 python3 是商店占位 stub，
  `command -v` 找得到但一跑就退出，改为先 `python3 -c ""` 实际验证可用再 exec；读报告必须用
  本次运行的 summary_path（脚本 stdout 首行），不能按目录名/时间猜（本机曾按随机目录名读到
  陈旧报告造成误判）。github 网络恢复后端到端实跑 PASS(exit 0)：9 项检查全 PASS，
  deny-advisories 与 audit 钉定同一 RustSec revision（309392b1，与 git ls-remote HEAD 一致），
  `--offline` 钉定检查在 cargo-deny 0.20.2 上真实可用。

- 2026-11-08 增量：本机补齐 Flutter 3.47.8 / Dart 3.13.7 / rustc 1.99.1 / FRB codegen 2.13.0 后，全部门禁在本机实跑通过：FRB/l10n 正常生成补齐此前 11 个生成缺口（9 函数 wrapper + audit_export_history/grid_preferences 两 module），`check_sources.py` 严格模式 PASS；Rust fmt/clippy/test 全绿（89 单测 + 全部集成测试，修复 audit_export 终态句柄保留、audit_export_history 事务显式回滚与 ExportSnapshot 释放、settings_import_audit 测试期望 v5 等真实缺陷）；`flutter analyze` 0 项；`flutter test` 105 项全过；`integration-check.ps1 -Device windows` 5/5 entry PASS（真实加载 Rust 动态库，含审计页/当前 API/导出历史/网格存储/桥接样例）；Windows Debug/Release 构建成功。pubspec.lock/Cargo.lock 与入锁基线哈希一致，未手改生成区。
  过程中修复的产品缺陷：打印预览在页面销毁时 busy 锁经对话框 future 泄漏（showDialog 改 Future.any + 卸载监听，route.completed 仅在页面挂载时等待）；外壳 IndexedStack 在 Flutter 3.47 新实现（无键 _VisibilityScope 包裹）下列表收缩时按键匹配退化为按位置更新、关闭一个标签会销毁其他隐藏页状态（页面内容改用 per-kind GlobalKey 重定位）；审计筛选栏窄窗口 Row 溢出（Print/Export 并入 Wrap 换行）；外部诊断对话框同类对话框 future 泄漏（同一 Future.any 模式）。新增 ARB 键 taskPhaseRunning/taskPhaseCancelled（历史行不再借用活跃进度文案）。
  环境边界：C 盘满（os error 112），构建须 `CARGO_HOME=D:\cargo-home`（D 盘 22 GB 可用）；integration-check.ps1 清理临时目录遇杀毒短暂占用 keel.db 增加有界重试（12×1s，所有权/重解析点检查不变，仍失败即 FAIL）。集成 current_api 的配置 v4 断言已按配置 v5 修正。仍未完成：Linux 桌面验收、DPI/读屏矩阵、签名/发布链、网格生产接线与 POC 平台矩阵（见 docs/IMPLEMENTATION_STATUS.md 各行）。

- 2026-11-08 网格 POC 与 DPI 自动化增量：隔离包 `poc/grid_columns` 补可编辑模式、12/1k/10k/100k/1M
  数据集、`PlutoLazyPagination` 分页与对照 Rust fixture 的 Dart 校验层，`flutter test` 48 通过 + 1 有理由 skip；
  实测并记录 PlutoGrid 8.1.0 五个缺陷（`rows` 必须可变、数字/日期列静默纠正、Dart `int.tryParse('0x10')`
  与 Rust 不一致、内置粘贴对空剪贴板断言且无上限、惰性分页无销毁守卫），生产接线须自建页脚或加取页守卫。
  `trina_grid 2.4.0` 仅只读核对（MIT，额外引入 pdf/shadcn_ui），未进 POC 锁、矩阵 NOT RUN。
  新增 `test/ui/shell_dpi_test.dart` 覆盖 3 种分辨率 × 4 档缩放、200% 文本缩放、640×360 最小窗口与深浅主题，
  审计页补 200% 文本用例；据此修复首页状态 pill、审计筛选区、分页页脚与页头说明四处真实溢出
  （筛选区最多占窗口 40% 高度并可滚动、页头说明最多两行、摘要省略）。`flutter test` 111 项全过，`integration-check.ps1 -Device windows`
  在最终代码上 5/5 PASS（并发跑 POC 测试时 `simple_test` 曾报 did not complete，去并发后两次单跑均 PASS，
  判为本机临时目录抖动而非回归）。同日补齐 S03/§4.2 脱敏：新增其他绝对路径（Windows 盘符/POSIX 多段）
  与电话号码规则（最多 5 组，或 CN 手机号形态；排除日期、版本号、相对路径、URL 路径），新增 6 项单测含
  混合行泄漏回归与超长数字串规模守卫（新规则最初在 1 MiB 输入上退化为 O(n²)，已用有界扫描修复）。
  发布与平台的外部条件（签名、attestation、
  Defender/SmartScreen、ruleset、Linux 发行、干净环境安装、公告库扫描、CI 首跑、素材授权、发布者名单）
  已列成 X01–X11 阻塞表，不因清单存在放宽任何门禁。

- 2026-11-08 往来单位参考闭环：新增二开示例实体 `customer`（客户/供应商），
  迁移 `0005_customers.sql`、`data/customer.rs`、`services/customer.rs`（校验 + `customers.manage`
  权限 + `customer.create/update` 审计同事务）、`api/customers.rs`，FRB 正常生成；
  Flutter 侧 `customers` 页（分页/搜索/类型/状态筛选、单选/Ctrl 多选/Shift 范围、方向键/Home/End/Esc、
  Ctrl+C 复制 TSV（公式前缀防护）、新建/编辑对话框、批量启停与删除（二次确认）、只读角色提示）
  与中英 ARB 50 键。权限矩阵增至 8 项（admin/operator 可维护，viewer 只读，读取不分角色）。
  批量写为单事务、逐条审计、任一记录缺失整批回滚、单批上限 200。
  `rust/tests/customer_test.rs`（真 SQLite 校验/唯一/分页/权限/审计/批量回滚）、
  `test/ui/customers_page_test.dart`（15 项，含多选复制、键盘导航、Enter/Delete、RTL、分页回退与 640×360 最小窗口）、
  `test/l10n/arb_parity_test.dart`（中英键集/占位符一致性）、
  `integration_test/current_api_test.dart` 真实桥接往返（含批量启停/删除）。门禁（当时）：cargo test 31 目标、
  flutter test 135 项、analyze 0、`integration-check.ps1` 5/5 PASS（含 16 项 current_api，客户往返含批量启停/删除）；
  当前批次已推进到 32 目标 / 149 项 / 6 entry，见下方增量。
  侧栏补齐“模块 / 收藏（上限 50）/ 最近访问（上限 10）”三组与折叠态（图标模式），
  打开页面记访问、未知 kind 只隐藏不回写；`test/ui/shell_nav_test.dart` 6 项。
  同步修正 `database_test` 的迁移前备份表清单（新增表要一起 drop）与 `widget_test` 的卡片滚动；
  末页删空后自动回退上一页（分页边界用例）。
  已知边界：文本排序走 SQLite BINARY（CJK 不按拼音），单元格/区域粘贴与内联编辑仍只在隔离 POC，
  审计日志保持只读；这是二开示例，不属于底座自带业务范围。

- 2026-11-09 登录保护（可选门禁）：新增 `app_security` 迁移、`data/auth.rs`、`services/auth.rs`
  （Argon2id 校验值、口令策略、开启/关闭/改口令、锁定与登录、审计）、`api/auth.rs` 并正常生成；
  启动时若开关打开则不发布当前用户，界面停在登录页；`lib/features/auth/` + 登录页 + “登录保护”设置页
  + 状态栏用户菜单“立即锁定”。开关存数据库、**不进可导入配置**；失败登录固定延迟 200ms。
  错误码新增 `KEEL-AUTH`。测试：`rust/tests/auth_test.rs`（策略/开关/锁定/审计/不落明文）、
  `test/ui/login_page_test.dart`（5 项）、`test/ui/security_page_test.dart`（5 项）、
  `integration_test/auth_test.dart` 真实桥接往返。已知边界：非 OS 凭据存储、非本机管理员隔离。

- 2026-11-09 页面命令统一注册：`UiPage.commands`（`UiCommand`：稳定 id/本地化标题/图标/
  快捷键提示/`isEnabled`/`onInvoke`）由外壳渲染到命令栏与“工具”菜单，只显示活动页的命令；
  已接审计（刷新/导出/打印）、往来单位（新建）、登录保护（立即锁定）、备份/诊断/任务（刷新）；
  快捷键仍由页面绑定以避免双触发；同时给英文删除确认加了 ICU 复数（1 entry / N entries）。
  `test/ui/shell_commands_test.dart` 3 项；`flutter test` 149 项。

- 2026-11-06 增量：配置 v5 新增独立 time_zone/currency，支持本机/UTC 及未指定/CNY/USD/EUR/GBP/JPY；旧偏好与区域偏好在服务锁内分别合并保存，沿用审计 outbox。真实用户 JSONL 导入已有 prepare/run/cancel 身份版本句柄，取消回执不等于回滚。Python 工具回归 86 项通过；当前十项 FRB 绑定待正常生成，本机缺 Flutter/Dart/Rust/PowerShell，新增功能尚未编译或完成桌面验收。（2026-11-08 注：上述生成与门禁缺口已在本机闭环，见最上方增量。）

- 2026-11-01：阶段 0 骨架曾在 Windows 验证。以下构建结论仅适用于当时的桥接样例；
  桥接三类样例（同步字符串 / 同步结构体 / 异步结构体）在 `flutter test integration_test -d windows`
  真实构建下通过，Dart 侧展示层与 FFI 接线分离，`flutter test` 不需要动态库。
- 2026-11-04 当前基线：Windows Release 已构建验证（用户确认，亦见下方 Fluent UI 集成记录）。
  当前副本保留部分扩展 API 的桥接生成物与依赖锁文件；本轮执行
  `python3 -B scripts/check_sources.py` 报告生成声明/模块 PENDING 并退出 1。
  本轮未执行 FRB/l10n 工具链；该检查只核对资源、导入和依赖名，不代替编译、测试、安全扫描或平台专项验收。
  后续改动须重新执行相应门禁；历史记录中的“待生成/尚未编译”按其当时快照理解，
  不能继续据此否定当前 Windows 构建结果，也不能据构建通过宣称所有功能已验收。
  禁止手补生成文件；新增依赖仍须核对锁定版本许可证和生成结果。
- 工具链与锁定：`rust-toolchain.toml`（stable）、`rust/Cargo.lock`、`pubspec.lock` 已入库；
  codegen 与门禁命令见 README「常用命令」。`tokio` 在阶段 0 锁定 1.54.1，
  当前直接启用 `time` / `sync`（定时器、初始化异步锁），runtime 由 FRB 创建；新增依赖仍待重新解析锁定。
- 依赖治理：`rust/deny.toml`（cargo-deny 0.20：许可证白名单 / 来源限制 / 重复依赖 / 公告）+
  `scripts/security-check.sh`（报告写入 gitignore 的 `build/reports/`；退出码 0 通过 / 1 违规或缺工具 /
  3 无违规但公告库取不到、发布不放行）；`THIRD_PARTY_NOTICES` 按依赖包 LICENSE 正文核对（2026-11-01）。
  2026-11-01 为清除 cargo-audit 报出的 yanked/unsound/unmaintained 跑过一次 `cargo update`
  （semver 范围内，tokio 1.34.0 → 1.54.1 等），更新后重跑全部门禁与 Windows 集成测试。
- CI 源码已有（GitHub Actions，远端已确定）：`.github/workflows/ci.yml` 四个 job——`windows` 跑全部门禁 +
  桥接端到端 + `scripts/security-check.sh`，`linux-rust` 保留 Rust 层可移植性冒烟；
  2026-11-02 新增 `linux-desktop`（Ubuntu 24.04）：显式安装 GTK3/构建/Xvfb 依赖，检查 runner 自带 pwsh，
  复用固定 SHA Flutter Action 与全局 Flutter/FRB 版本，锁文件约束、FRB/l10n 生成、生成差异门禁、
  Dart 门禁、Linux Release 构建及 Xvfb 下逐 entry 隔离真实桥接；仅补源码，尚未执行，不代表 Linux 桌面验收通过。Action 全部固定到完整
  commit SHA，osv-scanner 2.7.0 与 gitleaks 8.30.1 按官方发布物 SHA-256 校验后使用，报告作为 artifact 保留 30 天。
  `.github/dependabot.yml` 覆盖 cargo / pub / github-actions。
- 审计日期筛选的 Dart/Rust 手写契约已对齐：可选 UTC 毫秒 start_at_ms（包含）/end_at_ms_exclusive（排除），列表、COUNT、导出预检及批次共用 WHERE；两端有值时拒绝 start >= end。SQLite/跨批次/快照回归源码已补，FRB/l10n 生成、编译和真实测试未完成。
- CI 新增 Python 回归与 Bash 语法 job；release 已接严格扫描、本次摘要路径交接、证据/目录/ZIP 内容和外摘要校验、严格元数据门禁及 always 诊断上传。候选上传要求扫描/证据/严格校验均实际成功；公告库版本提取尚未实现，unknown/unavailable 保持阻断，不得伪造版本放行。Windows/Git Bash、PowerShell 和真实 Actions 仍待验证。
- 发布候选工作流与 SBOM/哈希/元数据生成已有源码，实际产物仍待核验；签名、来源 attestation、
  Defender 扫描记录与正式发布属阶段 4 独立门禁；`.gitattributes` 已固定脚本换行符。
  CI 的 `windows` job 首次在真实 runner 上执行时仍需观察（本机会话无法代跑），失败按 §10 修因不放行。
- 已新增 `.github/workflows/release.yml`：由 `v*` 标签触发 Windows 发布候选，标签保护须另在远端仓库 ruleset 配置，
  从 `cargo metadata` 与 `dart pub deps` 汇总依赖组件，生成 Release、SHA-256、SPDX 文件清单、
  构建元数据与安全报告；证据目录随候选 ZIP 打包。签名、attestation、安装器、
  Defender、干净环境安装升级卸载和正式发布仍是未完成的独立门禁。对应手工入口为
  `docs/WINDOWS_RELEASE_CHECKS.md`，其中未执行项不能记为通过。
- 本机开发有一个会弄脏 `pubspec.lock` 的陷阱（镜像地址改写），见 README「已知坑」；`scripts/security-check.sh` 会检查。
- SQLite/SQLx 已有实现与集成测试源码；进程内数据库打开已串行化，迁移前备份清理只处理匹配的普通文件并最多保留三份，新增并发打开与清理边界测试仍待真实运行；网格 POC 的查询基准、桌面验收矩阵和报告模板见 `docs/GRID_POC.md`、`docs/GRID_POC_REPORT_TEMPLATE.md`、`scripts/grid_poc.py`，尚未在 Flutter/桌面工具链中执行。
  审计页暂用 DataTable：分页、搜索/重置、三列排序、刷新/重试、双向滚动，
  当前页单行选择、上下/Home/End 导航、Esc 清选与 Ctrl+C/按钮复制五列 TSV；
  新查询结果清除旧选择，表格焦点内处理快捷键，复制失败显示安全提示。
  Ctrl+F 搜索、F5 刷新。工作区支持 Ctrl+Tab / Ctrl+Shift+Tab，隐藏页禁用焦点与动画，
  切换保留页面状态、关闭释放，相关回归测试待执行。不以临时 DataTable 代替网格验收。
- 外壳已有静态页面命令配置（`WorkspacePage.commands`）：审计/备份/诊断刷新共用工具栏、
  工具菜单与 F5；用户工作区保存/取消复用同一 Form，保存支持 Ctrl+S，忙状态/确认期间禁用，
  保存另检查管理权限。页面命令执行前复查活动标签实例、当前路由与关闭锁；
  控制器由 ProviderScope 持有，卸载编辑器解除连接。审计 CSV 导出已接入页面命令；
  其他业务导入/导出与打印仍待对应功能接入。
  应用级错误提示已编写：数据库失败可单飞重试，成功后刷新依赖查询；设置串行保存、
  失败可重试，加载失败的原配置禁止覆盖。Rust 在用户准备和启动审计成功后才发布池，
  初始化/恢复重试用异步锁串行。新增独立 `startup_restore_status` / `StartupRestoreStatus`，
  保留首次实际恢复结论跨初始化失败/重试；全局提示恢复结果、错误码/诊断 ID，可本次运行隐藏；
  恢复成功与数据库就绪分别呈现，`AppStatus` 字段未变。以上均待生成桥接及 Windows 验证。
- 状态栏由 `app.dart` 聚合备份操作/确认、诊断包准备/导出、配置导入、数据库重试和设置保存，
  显示进行中操作数量、悬停说明与 liveRegion 语义；空闲隐藏，隐藏页面的未完成操作仍显示。
  串行设置写入队列作为一类活动，结束或失败后移除；错误仍由原页面/全局提示处理。
  状态栏宽度不足时换行，高度随内容增长；无新增任务调度器、取消协议或依赖，测试待执行。
- 用户创建弹窗/工作区已复用普通 Form：本地 Unicode 校验、角色下拉、权限提示、
  提交锁、失败保留输入；校验失败聚焦用户名，错误布局后滚动定位，
  延迟定位检查 mounted/焦点/当前路由，焦点节点随编辑器释放；键盘回归测试待执行。
  `WorkspacePage.canClose` 为应用内全部关闭入口提供守卫，
  批量关闭全部确认后才执行，拒绝/异常保留页面。外壳已通过 `AppLifecycleListener.onExitRequested`
  处理 Flutter 框架收到的可取消平台退出请求：先检查 `WorkspaceShell.canExit`（用户弹窗草稿），
  再复用全部已打开工作区（含隐藏页）的 `canClose`；退出与标签关闭共享锁防重入，
  确认期间不提前销毁页面，工作区标签快照的数量、顺序或实例变化即取消退出。
  草稿 busy 或 confirming 时拒绝关闭，确认期间阻止同一草稿重复确认；
  确认后还会核对姓名/角色与 busy，避免旧确认用于已变更内容。
  此接入无新依赖，未修改 native `SetQuitOnClose`；普通窗口叉号 / Alt+F4 的目标行为仍需
  Windows 真机确认，强杀或不可取消退出不保障。关闭接入说明见 `docs/EXTENDING.md`，
  手工验收见 `docs/DESKTOP_EXIT_CHECKS.md`；测试源码已补，尚未执行。
- 诊断包默认仅 runtime，recent_events 需显式选择；完整脱敏快照预览后按单次句柄导出，
  5 分钟有效，绑定当前用户与角色；旧直接导出入口已删除。准备/导出 busy 阻止诊断标签关闭
  与可取消系统退出，失败须重新预览；中英文、交互与退出回归测试源码已补，尚未执行。
  诊断事件的非空关联 ID 可通过逐行按钮复制，Tab 聚焦后用 Enter/空格激活；只写 ID，
  复制防重、失败安全提示，隐藏/模态覆盖/卸载后不显示过期结果；相关测试源码待执行。
  诊断中心另支持 ID 精确查询与最低级别组合：搜索/Enter 提交、Ctrl+F 聚焦、重置、
  F5 保留已提交条件；筛选在 Rust 的最多 500 条事件缓冲内先过滤再取最多 200 条。
  `recent_events` 改为 `DiagnosticEventQuery` 参数，需重生桥接；不查询历史日志文件。
  中英资源、UI/Rust 双端输入校验与测试源码已补，尚待生成、编译和 Windows 验证。
  外部诊断/配置输入已有 Rust 只读筛查核心：限制 UTF-8 输入大小，检查 JSON 配置结构和
  版本，识别敏感类别并输出有限长度脱敏预览；不写正式配置、不执行内容、不处理路径或归档。
  未知字段、未来版本、损坏 JSON、非法编码和超限输入不能成为导入候选；文件选择、
  Rust 确认写入已在设置锁内重新筛查，只合并 language/theme/format_locale/navigation 并保留本机待写审计队列，
  文件层已限制普通文件、大小并拒绝符号链接，写入复用配置原子替换；文件选择、暂存/事务导入、
  Rust 已增加 5 分钟/6 项上限的一次性预览缓存并绑定当前用户，确认时消费句柄后重新校验；
  跨语言直接字节写入 API 已删除，仅保留准备快照与提交句柄，写入失败须重新准备。
  Rust 服务层 direct/file 入口保留作内部验证，不跨桥接；缓存生命周期与 API 消费测试源码已补，未运行。
  预览、直接导入和确认写入均在 Rust 检查独立 `settings.import` 权限；
  直接、文件和 prepared 确认导入共用持久结果审计（`settings.import` / `application` /
  `ok` 或 `failed:稳定错误码`，非空事件/关联 ID，不记录路径或输入），等待设置锁后复查完整用户身份，
  文件读取前先检查权限。成功事件进入 `pending_settings_import_audit`，与允许偏好同次 `config::save`；
  失败仅在本机配置健康、可写且有容量时入队，不改变原失败结果。该队列与 `pending_settings_audit`
  混合总上限 200，满时先尝试补写，仍满拒绝新的偏好变更/成功导入；配置仍为 v4，新增字段 serde 默认空。
  外部 pending 不采纳，保留本机两类队列；启动及后续保存按动作/事件 ID 幂等补写，
  核对完整记录以检测 `RAISE(IGNORE)`，全部确认入库后才清队列，失败保留待重放。
  无池或补写失败只告警，不撤销已保存配置；这不是配置与 SQLite 的跨存储事务，
  仅支持单进程写者，旧程序降级不保证保留新增队列。独立 SQLite 回归源码已补，尚未运行。
  Flutter 已编写独立“导入设置”工作区：用户主动粘贴受限 JSON 文本、Rust 脱敏预览、显式确认，
  预览后清空文本控制器；确认先封闭新偏好写入并排空旧设置/导航队列，再写入并回读语言/主题/显示区域/导航。
  回读失败保持写保护，状态栏提供重新打开入口，重试只读不重放句柄。准备/确认 busy 纳入状态栏、
  导入标签关闭与可取消退出守卫；隐藏页/模态覆盖的旧操作回调拒绝执行。中英及回归源码待实际运行。
  已补 Windows COM / Linux GTK 系统配置文件选择，经独立 method channel 仅返回路径；
  Rust 受限读取后复用单次预览句柄，Flutter 不读取文件内容。原生窗口期间持有导入 busy，
  取消不提交、返回后复查身份和活动页面。无新依赖；原生/路径测试、生成桥接/本地化及完整泄漏回归仍待实际运行。
  批量业务导入、跨配置/SQLite 事务仍未完成；导入结果持久补写已有源码，待真实验证。
- 审计筛选 CSV 导出已补手写实现：独立 `audit.export` 权限、固定筛选快照、后台任务进度/取消，
  输出到应用数据目录 exports；限 100,000 行 / 64 MiB，按稳定排序分批读取，CSV 处理转义和公式注入。
  Flutter 单飞轮询，通信错误保留句柄并仅重查；隐藏页仍显示活动，关闭只请求取消审计自己的任务，
  收到终态前保留页面。结果路径仅对任务所有者显示，切换用户不转移任务。
  已补异步 `save_audit_export_copy(task_id, destination) -> Result<String, ApiError>`：
  只允许本人 completed 且终态未满 5 分钟的任务，并在读取/异步授权后/发布前复查身份及 `audit.export`。
  Windows COM / Linux GTK `chooseAuditCsvSavePath` 仅返回路径；Dart `auditCopyPickerProvider` /
  `auditCopyWriterProvider` 与面板另存副本入口已接入，选择器及复制期间 `savingCopy` 纳入 busy，
  防重、保护标签关闭和可取消退出，返回后复查同一任务/身份/活动页面。
  Rust 限本地绝对 CSV 目标、普通源文件及 64 MiB，拒绝既有目标与预置链接/重解析点；
  目标同目录唯一临时文件写完后用 hard link 发布，不覆盖，不回退为直接写目标。
  源元数据与内容指纹仅检测普通损坏/变化，不是安全 hash；Windows 另核对句柄 file ID（卷号/文件索引）。
  祖先目录检查与打开/发布之间仍有恶意并发替换的 TOCTOU 边界，不承诺消除所有路径竞态。
  本轮无新依赖；FRB/l10n 生成、编译及 Win/Linux 平台测试均待执行，打印/通用任务历史仍未实现。
- 备份创建/登记/取消及恢复确认共用 UI 操作锁；忙状态保护标签关闭和可取消系统退出，
  失败也重读实际状态。Rust 取消需恢复权限，登记/取消进程内串行；取消先记请求再删除标记，
  删除后记成功，文件与审计没有共同事务。启动清理走私有无身份路径；测试源码待运行。
  恢复标记使用同目录唯一临时文件同步写入后原子替换，已有标记符号链接直接拒绝；恢复临时
  数据库使用唯一临时路径，不跟随预置 `.restore-tmp` 符号链接。Unix 回归源码已补，Windows
  文件替换和权限行为仍待真实验证。
  文件大小按当前 locale 格式化，使用字节 / KiB / MiB / GiB / TiB（1024 进制），
  大单位保留一位小数，悬停提示精确字节数；单位文案进 ARB，语言切换原位更新。
  无新依赖，未创建共享格式化目录；新增本地化及交互测试仍待生成与 Windows 验证。
- 配置变更审计已编写：配置 v4 将偏好与待写事件一同原子保存，兼容读取 v1–v3；
  `save_settings` 改为异步，数据库不可用仍可保存，启动就绪后及后续保存时按事件 ID 补写去重。
  变更事件保留原时间/操作者，只记 language/theme/format_locale 字段名；两类审计队列合计上限 200、配置上限 1 MiB，
  队列满先尝试补写，仍满则拒绝新变更。已保存设置不因补写失败误报为未保存；
  损坏/未来版本配置在 Rust 保存边界也禁止覆盖。仅保证单进程写者，测试源码待实际运行。
- 显示区域已独立于界面语言：视图菜单可选 en_US/en_GB/zh_CN 或跟随系统；
  中文系统映射 zh_CN，en_GB 保留英国格式，其他系统区域回退 en_US，监听系统区域变化。
  审计/诊断/备份日期、审计分页数字和备份大小读取同一显示区域；时间仍为本机时区。
  配置 v4 新增 format_locale，v1–v3 迁移为跟随系统；保存和导入沿用审计/写保护，
  语言/主题变更保留区域值，无新依赖。Rust/Dart 回归源码已补，FRB/l10n 生成及真实验证待完成。
- 导航已有模块/收藏/最近访问分组：星标增删收藏（上限 50），显式打开/切换页面更新最近
  10 项，关闭自动选页不记访问；导航折叠状态一并保存。只持久化页面 kind，不恢复标签或草稿；
  未注册 kind 在 UI 隐藏，不在初始化时擅自写回清除。导航与语言主题共用 Rust 配置锁，
  字段级合并保留待写审计，导航操作不新增语言/主题审计；保存失败可重试，读坏配置只临时使用。
  新增导航 DTO/API、启动注入、中英文和回归测试源码，仍待生成与 Windows 验证。
- 页面快速搜索已接入 Ctrl+K 和窗口菜单：按本地化页面名称/稳定 kind 匹配，支持方向键、
  Enter 打开、Escape 取消，复用工作区 open 和最近访问；取消不留访问记录。
  同时只开一个搜索，关闭检查或其他模态路由打开时不叠窗，执行前复查页面注册。
  搜索仅覆盖已注册页面入口，业务数据搜索仍按功能设计；测试源码待 Flutter/Windows 执行。

- 2026-11-02 本批：`appPages` 静态登记 `tasks`（当前进程本人审计任务列表）和
  `form_samples`（int32/精确USD/日期时间/枚举本地预览）；作用域稳定key连接表单关闭守卫，
  任务/审计页共用取消终态守卫，原孤立导出canExit保护保留；未知阶段也计入全局busy。
  共享导出面板/操作新增身份加载与错误隔离，表单旧回调/延迟滚动检查隐藏和路由状态。
  中英各31个 formSample 资源键及其 placeholder 元数据已补；注册/关闭/退出回归源码已补，未手改生成区或加依赖。
  表单仅本地样例，无业务保存/Rust校验；任务已有最多6项本人进程内列表与按ID选回，
  终态300秒过期且查询不续期、原文件保留；持久历史/跨重启恢复未实现。未知阶段保守阻断。
  实跑check_sources --allow-pending-generation退出0/PARTIAL（17项PENDING）、Python脚本回归30项通过；
  本机无Flutter/Dart/Cargo，未生成、格式化、编译、跑widget/Rust测试或验收桌面。

- 本批集成复核：历史诊断文件检索为独立显式入口，读取前授权与阻塞扫描后复查完整身份，
  固定 logs 目录、合法每日文件名；上限256目录项/14文件/4MiB/200行、8192字节输入行与2048输出标量。
  完整行脱敏后字面匹配，链接/重解析点拒绝；不等于内存事件筛选或持久任务历史。
  已补中英文资源；身份加载/错误拒绝历史入口与旧提交、清除旧结果；迟到未知任务保留句柄和关闭保护。
  app.dart 已有注册/退出接线，本轮未改；bridge.dart 未见手写冲突，FRB/l10n仍待正常生成。
  网格仍缺目标版本包源码/API和LICENSE正文/哈希/传递依赖证据、可用生成工具链及Win/Linux矩阵实测。

- 2026-11-04 本批：新增 `lib/shared/widgets/page_shell.dart`（KeelPage / KeelPanel / KeelNotice /
  KeelBusyLine / KeelEmptyState），导入设置、审计、备份、诊断四页统一为「页头说明 + 分区卡片」；
  非滚动页在窗口高度 < 680 时隐藏页头说明以保证表格/列表可用，窄宽度下操作条自动换行。
  审计页筛选与导出合并为一张卡片、导出范围说明改为信息图标 tooltip、分页右对齐；
  诊断页检索范围提示改为单行 + tooltip；备份页保留 MaterialBanner 恢复横幅语义（测试契约）。
  新增中英文键（四页页头说明、预览标题/空态/字节计数/快照版本/脱敏组数），已重跑 `flutter gen-l10n`；
  未手改生成区、未加依赖。`flutter analyze` 干净，`flutter test` 583 通过（2 项既有 skip）；
  已用离屏真实字体截图核对四页。未在 Windows/Linux 桌面真机验收。

- 2026-11-04 视觉批次：新增 `lib/core/theme/keel_theme.dart`（中性石墨 + 单一蓝色强调，深浅两套；
  统一字号、控件高度 30–32、圆角 6/10、输入框/按钮/表格/列表/菜单/横幅/滚动条主题，NoSplash 贴近桌面手感），
  app.dart 改用 `keelTheme()`。外壳重绘：菜单栏 34 高、工具栏按钮 30 高、侧栏 216 宽（图标 + 选中 pill）、
  标签页 38 高（选中并入内容底色 + 顶部强调线）、状态栏 26 高（数据库状态圆点、用户首字母头像）。
  任务、普通表单、新建用户、桥接样例四页改用 KeelPage/KeelPanel；审计与诊断搜索框加前缀图标。
  新增中英文键（当前任务/任务历史/历史空态/桥接页说明），已重跑 `flutter gen-l10n`。
  `flutter analyze` 干净，`flutter test` 583 通过（2 项既有 skip）；离屏真实字体截图核对深浅主题。
  未在 Windows/Linux 桌面真机验收。

- 2026-11-04 Fluent 重写批次：按「当作新项目重写界面」的要求，删除原 Material 展示层
  （`lib/core/theme/`、`lib/shared/widgets/`、`lib/features/*/view/`、旧工作区外壳与全部旧 UI 测试），
  改为 `lib/ui/`：`shell.dart`（菜单栏/命令栏/侧栏/标签/状态栏）、`theme.dart`（FluentThemeData，
  显式实色背景避免 acrylic 底色不一致）、`widgets/`（UiPageHeader/UiPanel/UiEmpty/UiNotice/showToast/
  showConfirmDialog）、`close_guards.dart` 与 `actions/audit_export_actions.dart`；`pages/` 覆盖工作台、
  审计（日期范围、三列排序、导出 CSV）、诊断（事件检索/最低级别/导出包/历史日志）、备份与恢复、
  创建用户、导入设置、任务、桥接样例、普通表单。`app.dart` 改为 FluentApp；主题枚举改
  `KeelThemeMode` 以隔离 fluent_ui 的 ThemeMode。保留全部 `features/*/state/`、`core/state/`、桥接与 Rust。
  外壳支持 Ctrl+K 页面搜索、Ctrl+W/Ctrl+Tab、语言/主题/显示区域菜单、状态栏用户切换、关闭标签与
  系统退出共用页面关闭守卫（草稿/表单、备份、诊断包、导入写保护、导出任务）。
  新增依赖 `fluent_ui ^4.17.0`（BSD-3-Clause）。`flutter analyze` 干净；`flutter test` 通过
  （仅保留 `test/widget_test.dart` 外壳冒烟，旧 UI 测试随旧界面删除，需后续补齐）；
  `flutter build windows --release` 成功，并在本机 120 DPI 屏幕以浅色/深色实拍核对。未做 Linux 桌面验收。

- 2026-11-04 审计多列排序：`AuditQuery.sort_by/descending` 改为 `sort: Vec<AuditSort>`
  （field + descending，最多 3 列、字段不重复、按顺序生效，`id` 稳定兜底），列表与导出快照共用
  `data/audit::order_clause`，列名仍走白名单；已跑 FRB codegen。Dart 侧 `AuditFilter.sort` 与
  页面表头联动：点击加入排序、再点切换方向、Ctrl+点击移除，多列时显示序号；重置筛选同时恢复默认排序。
  Rust 单测 + `audit_test`（真 SQLite 三列排序）与 Dart 查询映射测试通过；`cargo clippy -D warnings` 干净。

## 1. 定位、目标与非目标

### 1.1 定位

可复用、可 fork、可二次开发的通用桌面 Admin 底座，用于构建进销存、ERP、仓储、采购、销售、财务、生产等 Windows 桌面软件。不是数据 Demo，也不是 WebView 网页后台：必须有菜单栏、工具栏、多工作区标签、键盘操作、数据网格、状态栏、系统级文件交互、独立配置和本地数据库。桌面形态与交互细节（菜单栏组成、布局、快捷键、DPI）见需求文档 §2。

### 1.2 必须满足

1. Rust 是核心语言：业务规则、数据访问、事务、批处理、导入导出、核心计算。
2. 独立桌面 UI：Flutter 编译为 Windows/Linux 应用，不以浏览器/WebView 作主容器。
3. 性能可验证：用真实表格、真实查询、真实数据量测渲染、内存、响应与资源释放，不用语言基准推断。
4. 容易二开：遵循 Flutter / Cargo 官方惯例；不要求先学私有 DSL、注册机制或自创抽象。
5. 开源依赖优先：默认依赖不要求商业 UI 授权；直接与传递依赖都要核许可证、维护状态、平台支持。
6. Windows 首发、Linux 可移植：业务逻辑不绑 Win32，平台差异收敛在小范围适配。
7. 国际化先天支持：文字、日期时间、数字、货币、时区、复数、排序都不硬编码为中文场景。
8. 安全与数据保护：参数化 SQL、最小权限、错误分层、日志脱敏、诊断包双向脱敏、迁移前备份。
9. 升级友好：以源码模板 + 可运行样例为首要交付；只有稳定复用边界形成后才抽成独立包。

### 1.3 非目标（v1）

- 不自研完整 GUI 渲染引擎或通用 DataGrid 引擎。
- 不采用浏览器/WebView 作主界面。
- 不预拆大量 crate / Dart package / 微服务。
- 不建 Keel 专属 UI DSL、万能查询 DSL、全局事件总线、运行时模块注册体系、服务定位器。
- 不强制复杂 Repository / Unit-of-Work；数据访问只在真有复用和测试价值处抽象。
- 不承诺“只换连接串就能切数据库”。
- 不把本地角色权限当成能防御本机管理员的安全隔离。
- 不做动态插件市场、任意第三方脚本执行、远程代码加载。

## 2. 技术路线与版本锁定

### 2.1 选型

| 层 | 选型 | 说明 |
|---|---|---|
| 核心语言 | Rust stable | 业务、数据、事务、批处理、系统能力；Cargo 管理 |
| 桌面 UI | Flutter / Dart | 声明式、跨平台、Flutter 自绘；不是 Win32 原生控件封装 |
| 桥接 | flutter_rust_bridge 2.x 稳定版 | 代码生成，不手写 FFI；codegen 与运行时版本锁定 |
| 数据库 | SQLite（v1） | 不默认具备静态加密 |
| Rust 数据访问 | SQLx | 启 SQLite；PG/MySQL 按验证结果再加 feature |
| 异步 | Tokio | 按 SQLx 运行配置；不为简单同步工作引入复杂任务系统 |
| 序列化 | Serde | 配置、DTO；不把内部数据库模型原样暴露给 UI |
| 日志 | tracing + tracing-subscriber | 结构化日志与诊断事件 |
| Rust 错误 | thiserror / anyhow | 领域/API 用可识别类型；工具层可带上下文 |
| Flutter 状态 | flutter_riverpod + 本地状态 | 共享/异步用 Provider；纯局部留在 Widget；不建第二套状态框架 |
| 数据网格 | trina_grid 2.4.0（MIT，已锁定） | 2026-11-09 同用例对比后锁定（ADR-012）；缺陷 6/7 的固定绕法见 `docs/GRID_POC.md`；平台矩阵仍开放，不自研完整引擎 |
| UI 视觉 | Flutter 组件 + Keel 设计令牌；可 POC fluent_ui | 专业桌面惯例，不做网页式大卡片 Dashboard |
| 国际化 | flutter_localizations + intl + ARB | 可见文字全部进资源文件 |
| 配置 | 版本化配置文件 + 系统用户目录 | 可变数据不进安装目录；敏感信息不明文存普通配置 |
| 构建锁定 | Cargo.lock + pubspec.lock + 工具链记录 | 发布可复现；只升级测过的组合 |

### 2.2 锁定规则

- Rust 用当前 stable，记录在 `rust-toolchain.toml`；CI 与开发机同一工具链，不跟随 nightly。
- Flutter/Dart 用 stable 同一已验证版本，CI 固定版本。
- FRB 用稳定版，固定 codegen + 运行时兼容组合。
- SQLx、trina_grid、Riverpod 等先通过 Windows 构建与关键行为测试，再锁进 lock 文件。
- 正式版本不用浮动 Git 分支；必须用 Git 依赖时锁到 commit 并记录原因。
- 调研参考值：FRB 2.13.0、SQLx 0.9、trina_grid 2.4.0——版本锁定见 ADR-012，升级须重跑 POC 用例。

### 2.3 关于“原生桌面”的准确说明

Flutter Windows 发行物 = `.exe` + 引擎 DLL + `data` 目录等，不是 WebView 套壳；但多数控件由 Flutter 引擎绘制，不是 Win32 原生控件。产品承诺是“独立编译的跨平台桌面应用与桌面式交互”，不是“每个按钮都原生”。必须用系统原生能力的场景，通过有限的平台插件/FFI 适配。

## 3. 分层与职责边界

```text
Flutter UI → lib/api/bridge.dart → FRB 生成接口 → rust/src/api
                                                   → services → data(SQLx) → SQLite
                                                   → diagnostics（日志/审计/诊断）
```

- 单 crate；不因“架构高级”拆 crate。Rust 分层冻结为 `api / services / data / domain（按需）/ diagnostics`，不使用 `application`、`infrastructure` 命名。
- `api`：跨语言入口，DTO + 命令薄壳；不写业务规则。
- `services`：可复用业务操作与事务边界。
- `data`：SQLx、迁移、查询/分页/排序/过滤/批量。
- `domain`：只在领域规则/模型值得单独表达时出现。
- 小功能允许直接实现，不强制五层抽象。

### 3.1 Flutter 职责

窗口内容、菜单、工具栏、左侧导航、工作区标签、状态栏、主题；表格展示、筛选输入、表单编辑、快捷键、焦点、对话框；加载/成功/失败/空状态；i18n 资源与展示格式化；调用 Rust API 并转成 ViewModel。

不做：直接 SQL；持有连接池/事务/游标；UI isolate 跑大型同步处理；在 Dart 复制整库做过滤/排序；每行每单元格触发一次跨语言调用。

### 3.2 Rust 职责

业务规则、参数验证、数据完整性、事务；连接池、迁移、查询/排序/过滤/分页、批量；导入导出核心解析与写入；统一错误码、日志上下文、可诊断结果；通过明确 API/DTO 暴露能力。

不做：构建 Widget/主题；每页一个 crate；让 UI 传 SQL 执行；用任意脚本执行当“扩展接口”。

### 3.3 桥接约定

1. 桥接是接口边界，不是业务层。
2. 用稳定明确的请求/响应类型（命名模式 `XxxQuery`、`XxxPage`、`SaveXxxRequest`、`OperationResult`，Xxx 换成你的业务名；底座本身不含业务实体，示例列表将用审计日志）。
3. 不把 SQLx row、连接池、事务句柄或内部实现暴露给 Dart。
4. 列表一次分页调用返回一页；禁止逐单元格调用。
5. 批量/导入/长任务异步化，提供阶段、进度、取消；进度事件限频。
6. 错误保留可供程序判断的 code，用户提示与内部诊断分开。
7. 生成文件不手改；生成步骤写入 README/CI。
8. 跨语言 DTO 视为公共接口；破坏性改动同步更新 Rust、Dart、测试与迁移说明。

## 4. 目录结构（V1）与规则

下面是**目标结构**。每个节点标了当前状态：`[已有]` 仓库里现在就有；`[计划]` 还没创建，对应阶段开工时再建
（不要为了对齐这棵树预建空目录，见下面的规则）。阶段 0 的桥接样例已经拆成
`main.dart`（只做初始化 + runApp）+ `app.dart`（根 Widget）+ `api/bridge.dart`（所有对 Rust 的调用）+
`features/bridge_samples/`（样例页，纯展示、回调注入）；阶段 1 在这个结构上往 `core/`、`features/` 里加东西。

```text
keel/
├─ AGENTS.md  README.md                [已有]
├─ .github/workflows/ci.yml          # [已有] GitHub Actions：门禁 + 依赖治理 + 密钥扫描；Action 固定到 commit SHA
├─ .github/dependabot.yml            # [已有] cargo / pub / github-actions 升级 PR
├─ assets/                         # [计划] 当前无图片资源（占位品牌图已移除）；重新引入时在 pubspec 声明
├─ docs/                           # [已有] REQUIREMENTS.md 产品需求；adr/ [计划]
├─ lib/
│  ├─ main.dart                    # [已有] 入口：initBridge() + runApp(KeelApp)
│  ├─ app.dart                     # [已有] KeelApp：主题 / 路由 / 首页
│  ├─ l10n/                        # [已有] app_zh.arb / app_en.arb；app_localizations*.dart 由 `flutter gen-l10n` 生成，不入库
│  ├─ api/bridge.dart              # [已有] 手写桥接适配层：初始化、设置、审计、用户、备份、诊断与桥接样例调用
│  ├─ core/                        # [已有] 只放跨业务基础能力
│  │  ├─ workspace/ state/ errors/ # [已有] 错误码翻译、诊断 ID；导入写保护与导航偏好；设置保存/语言/主题/格式区域/数据库重试等 provider
│  │  ├─ app/ routing/ localization/   # [计划]
│  ├─ features/<feature>/          # [已有] 仅业务状态与解析：audit/、backup/、diagnostics/、settings_import/、form_samples/、users/（state/）；一功能一目录
│  ├─ ui/                          # [已有] Fluent 展示层：shell.dart、theme.dart、ui_page.dart、close_guards.dart、actions/、widgets/、pages/
│  │  ├─ pages/                    # [已有] 工作台 / 审计 / 诊断（含两个对话框）/ 备份 / 创建用户 / 导入设置 / 任务 / 桥接样例 / 普通表单
│  │  ├─ widgets/                  # [已有] ui_layout.dart（页头/面板/空态/提示/showToast）、ui_dialogs.dart（确认对话框）
│  └─ src/rust/                    # [已有] ⚙ FRB 生成，禁止手改
├─ rust_builder/                    # [已有] ⚙ FRB 模板：cargokit 构建插件，挂进 flutter build
├─ rust/
│  ├─ Cargo.toml  Cargo.lock       # [已有]
│  ├─ deny.toml                     # [已有] cargo-deny：许可证白名单/来源/重复依赖/公告
│  ├─ migrations/                  # [已有] 0001_init.sql（audit_log）、0002_users.sql（app_user）；000N_描述.sql，编号连续（sqlx migrate add -s）
│  ├─ src/
│  │  ├─ lib.rs                    # [已有]
│  │  ├─ api/                      # [已有] error.rs（ApiError）、app.rs（数据库初始化 / 状态）、audit.rs（审计列表）、users.rs（当前用户 / 用户管理）、backup.rs（备份与恢复）、settings.rs、diagnostics.rs、ping.rs / simple.rs（桥接样例）；业务命令放这里
│  │  ├─ services/                 # [已有] startup.rs（串行初始化/重试）、settings.rs（配置与审计补写）、audit.rs（校验 + 分页限制）、access.rs（用户与权限）、backup.rs（备份与恢复）、diagnostic_pack.rs（诊断包预览与导出）
│  │  ├─ data/                     # [已有] mod.rs（打开 / 迁移 / 迁移前备份）、audit.rs（查询）、user.rs；SQLx 与 SQL 只在这一层
│  │  ├─ domain/                   # [已有] permissions.rs：角色（admin / operator / viewer）与权限（查看审计、管理用户、创建备份、恢复备份、导出诊断包）
│  │  ├─ diagnostics/              # [已有] 关联 ID、脱敏（redact）、文件日志 + panic 钩子、诊断事件缓冲（500 条，写入即脱敏）
│  │  ├─ config/                   # [已有] v4 用户配置（语言、主题、显示区域、导航偏好、待写审计），兼容读 v1–v3，JSON 原子保存
│  │  ├─ tasks/                    # [计划] 按需；有真实功能再建
│  │  ├─ errors.rs                 # [已有] KeelError：Validation / NotFound / Io / Internal / Cancelled / Uninitialized
│  │  ├─ state.rs                  # [已有] 进程级连接池
│  │  └─ frb_generated.rs          # [已有] ⚙ 生成
│  └─ tests/                       # [已有] 真 SQLite 集成测试（audit、database、access、backup、settings、logging、diagnostics）
├─ test/                            # [已有] widget_test.dart：Fluent 外壳冒烟（旧 UI 测试随旧界面删除，待补页面级回归）
├─ integration_test/               # [已有] 加载真实 Rust 库的端到端测试
├─ scripts/                        # [已有] security-check.sh、check_sources.py（离线静态核对）、verify.ps1（Windows 生成/格式化/测试）、integration-check.ps1（逐 entry 隔离的桌面集成测试）
├─ windows/  linux/                # [已有] ⚙ flutter create 平台壳
├─ packaging/{windows,linux}/      # [计划] 安装器与发行物；不另建 installer/
├─ pubspec.yaml  pubspec.lock  analysis_options.yaml   # [已有]
├─ .gitattributes                   # [已有] 固定脚本 LF / 平台文件 CRLF（Windows 开发机 autocrlf=true）
├─ flutter_rust_bridge.yaml         # [已有]
├─ rust-toolchain.toml             # [已有] stable + rustfmt/clippy
├─ LICENSE                         # [已有] MIT
└─ THIRD_PARTY_NOTICES             # [已有] 按依赖包 LICENSE 正文核对（2026-11-01）
```

规则：

- 不预建空目录；`macos/`、`core/lifecycle/`、`core/permissions/` 等有真实代码再加（单主窗口、多工作区是 v1 范围，多窗口不是）。
- 生成区：`lib/src/rust/**`、`rust/src/frb_generated.rs`、l10n 生成文件——禁止手改。
- 迁移、生成物、资源各有归属，不与手写代码混放。
- 新增依赖目录前先确认有第二处真实复用。

## 5. 数据库与数据访问

### 5.1 v1 决定

- SQLite；连接与事务只在 Rust；数据库放系统用户数据目录，不放安装目录或 CWD。
- 初始化、迁移、版本检查在应用服务层；UI 只显示进度与结果。
- 外部输入全参数绑定；禁止字符串拼接用户输入构造 SQL。
- 列表按服务端分页思想处理：只给 UI 当前页与必要聚合。

### 5.2 SQLite 约定

- 外键开启；事务边界明确，一个用户操作不拆成不可回滚的多次写入。
- WAL 与 busy timeout 以真实并发测试结果定值（拟定初值：WAL、`foreign_keys=ON`、`busy_timeout=5000`）。
- 长查询可取消或至少不阻塞 UI；桥接调用不长期持锁。
- 启动检查 schema 版本并顺序迁移；迁移前可恢复备份；失败给错误摘要、诊断 ID 与恢复指引。
- 新建迁移一律 `sqlx migrate add -s <描述>`：`-s` 才生成 `000N_` 顺序前缀；sqlx 默认模式生成时间戳前缀，与 `000N_` 混用会打乱迁移顺序。
- 备份保留策略、手工备份/恢复属于基础能力；恢复前覆盖提示与校验。
- 不把 SQLite 描述为加密数据库；静态加密须单独立项并重核许可证。

### 5.3 数据层规范

- services 管规则与事务，data 管 SQL；SQL 就近存放、可检索；复杂查询加注释与测试。
- 不为每张表机械生成 CRUD；只有真实复用价值才抽象。
- DB 模型、Rust DTO、Dart UI 模型分离；公共 DTO 需考虑兼容演化。
- 分页固定页大小上限（拟定 200，page 从 1 起）；排序字段白名单，禁止把 UI 字符串直接进 `ORDER BY`。
- 保存操作考虑唯一约束、并发更新与冲突反馈，不只做前端校验。
- 金额用整数最小货币单位（如分）；时间存 UTC epoch 毫秒，显示转本地时区；时间点与本地日历日期区分建模。
- 重要写入记 `audit_log`（时间、操作者、动作、对象、结果、关联 ID）。

### 5.4 未来 PostgreSQL / MySQL

在 data 边界定义必要能力，不让 SQLite 独有 SQL 泄漏到业务规则；每种 provider 单独迁移脚本、集成测试与性能测试；v1 不预建万能数据库抽象；切换是独立工程项目。

## 6. 错误处理与可观测性

- 用户看到明确可操作的提示；开发者凭关联 ID 在诊断中心查脱敏后的技术上下文。
- 错误类别至少：输入校验、业务冲突、数据库、文件 I/O、权限、桥接、内部、取消。
- 领域错误用稳定 code，UI 不解析错误字符串做分支；`message` 可展示，`detail` 只进诊断。
- 错误码：`KEEL-VALIDATION`、`KEEL-NOT-FOUND`、`KEEL-DUPLICATE`、`KEEL-DB`、`KEEL-DB-MIGRATION`、`KEEL-IO`、`KEEL-IMPORT`、`KEEL-BACKUP`、`KEEL-UNINITIALIZED`、`KEEL-PERMISSION`、`KEEL-AUTH`（登录口令不正确或未设置）、`KEEL-INTERNAL`、`KEEL-CANCELLED`（用错误方式中止时才用，一般用返回值里的 cancelled）。新增码先登记。目前 `errors.rs` 已实现上述全部错误码。
- 日志级别 TRACE/DEBUG/INFO/WARN/ERROR；Release 默认不输出高量调试日志；关联 ID 贯穿 Dart 调用、Rust 服务、数据库操作，不用个人敏感信息作 ID。
- 可恢复错误给重试/取消/详情；不可恢复给备份、修复或导出诊断建议。

## 7. ADR

- ADR-001 Rust 为核心语言——通过。
- ADR-002 Flutter 作桌面 UI——选定基线，须 POC。
- ADR-003 FRB 作桥接——通过；POC 起点版本 2.13.0（codegen 与运行时一致），最终版本 POC 后锁定。
- ADR-004 SQLite + SQLx——通过；具体版本 POC 后锁定；PG/MySQL 单独立项。
- ADR-005 PlutoGrid 优先候选——其中“首选候选”部分由 ADR-012 取代（2026-11-09 锁定 trina_grid 2.4.0）；
  “不通过换组件、不自研完整引擎”的边界不变。
- ADR-006 遵循社区惯例，不建私有框架——通过；不建 DSL/事件总线/服务定位器/过度 Repository。
- ADR-007 日志与诊断脱敏、ADR-008 国际化与时区、ADR-009 Windows 优先 + Linux 持续构建、
  ADR-010 依赖许可治理、ADR-011 发布签名与更新策略、ADR-012 数据网格选用 trina_grid 2.4.0
  已记录在 `docs/adr/`；记录现有基线与待验证边界，不代表签名、平台构建或发布证据已完成。

框架升级：SemVer；明确公共 API 与内部实现；破坏性变更写迁移说明；数据库迁移可测试；发布前跑示例应用与二开样例兼容测试；业务代码不改框架生成文件；优先通过稳定接口扩展，不要求复制源码。首次发布前建 `CHANGELOG.md`（Keep a Changelog 格式），每次发版记录新增、变更、移除、修复与迁移步骤。

## 8. 需求文档与读取规则

产品需求与详细规范集中放在 `docs/REQUIREMENTS.md`，**按需读取**：

| 任务涉及 | 先读（docs/REQUIREMENTS.md） |
|---|---|
| 功能范围、菜单命令、列表/表单能力 | §1 |
| UI、交互、快捷键、屏幕与 DPI | §2 |
| 文案、格式、时区、币种 | §3 |
| 导入导出、路径、凭据、诊断、更新 | §4 |
| 分页、大数据量、取消、资源释放 | §5 |
| 数据网格选型与验收 | §6 |
| 新增依赖、许可、供应链 | §7 |
| 安装升级、打包、发布交付 | §8、§9 |
| 阶段规划、测试验收与放行 | §9、§10 |
| 风险核对 | §11 |

- 默认不读全文；任务涉及某领域时先读对应章节再动手，不涉及的章节不读，也不凭记忆推断。
- 两文件分工：基线、分层、目录、数据约定、错误码、命令、守则以本文件为准；功能范围、UI、安全细则、许可细则、POC 标准、测试与路线以需求文档为准。与实现冲突时以实现为准，并在同一轮修正对应文件，不保留两套说法。

## 9. 命令

```bash
flutter pub get
flutter_rust_bridge_codegen generate                        # 改 rust/src/api 后必跑
cd rust && cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test
cd rust && sqlx migrate add -s <描述>                      # 新建迁移，必须带 -s 走顺序编号
flutter analyze && flutter test
bash scripts/security-check.sh               # 许可证/来源/重复依赖/公告，报告进 build/reports/
flutter gen-l10n                                          # 改 ARB 后；也是 `flutter pub get` 之后的必做一步（生成物不入库）
pwsh -File scripts/integration-check.ps1 -Device windows   # 逐 entry 独立进程 / owned 临时目录，真实加载 Rust 库
flutter run -d windows
flutter build windows --release
```

`verify.ps1` 与 Windows CI（`shell: pwsh`）共用 `scripts/integration-check.ps1`。
脚本按名称逐个运行顶层 `integration_test/*_test.dart`，每个 entry 单独启动桌面进程，
首个失败即停止，无 entry 判失败；不复用调用方数据目录。每次创建 GUID 临时目录和 ownership marker，
在 finally 中先恢复 `KEEL_DATA_DIR` / `KEEL_FRB_TEST_TOKEN`，再校验归属并拒绝含重解析点或符号链接的清理；
guard 失败须报错并保留目录，不强删。脚本也恢复调用前的工作目录。
`Device` 仅接受 `windows`（默认）或 `linux`；`linux-desktop` CI 源码已在 Xvfb/DBus 会话内调用
`pwsh -File scripts/integration-check.ps1 -Device linux`，并准备生成物、原生工具链和显示环境。
`linux-rust` job 保留 Rust 冒烟；新增桌面 job 尚未真实运行，Linux 桌面验证仍待证据，
系统对话框、剪贴板、快捷键、字体与正式发行版范围仍需目标环境验收；§0 阶段 0 命令保留历史事实。

## 10. Agent 工作守则

- AGENTS.md 与需求文档共同构成仓库权威（分工见 §8）；与实现冲突时以实现为准，并在同一轮修正对应文件，不保留两套说法。
- 改公开类型/命令后必跑 codegen，生成物随改动提交；不手改生成区。
- 不新建空目录；不引入 DSL、事件总线、服务定位器、万能 Repository；不引入需商业授权的组件。
- 新增依赖：查来源与许可证，更新需求文档 §7.2，说明必要性；升级单独提交并测试。
- 重大决策写 ADR；需要时才建 `docs/adr/`。
- 完成前至少跑：`cargo fmt`、`cargo clippy -D warnings`、`cargo test`、`flutter analyze`、`flutter test`；跑不了的项说明原因。
- 安全项（导出/导入/路径/压缩包/凭据/更新）按需求文档 §4 实现，不以“内部工具”为由跳过。
- 性能与网格结论必须有可复现数据，不写没有证据的承诺。

## 11. 已知边界

- 本地角色/权限不防御本机管理员；SQLite 默认不加密。
- 登录保护是应用级口令门禁（Argon2id 校验值存 `app_security` 表），默认关闭且不进入可导入配置；
  不是 OS 凭据存储集成，能读取用户数据目录的人可离线尝试口令或直接删库；无持久失败锁定与管理重置流程。
- v1 不做静默自动更新；签名、Defender 扫描、SBOM 按需求文档 §7.4 执行。
- 网格高级能力与超大数据量以 POC 结果为准。
- 框架升级不承诺三方代码零修改，破坏面收敛在公共 API。
- 安全控制是风险降低措施，不承诺“绝不感染”。
