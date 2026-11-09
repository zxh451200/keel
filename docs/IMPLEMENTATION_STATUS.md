# Keel — 完整剩余项台账

核对日期：2026-11-09（按当前源码与最近实跑重扫，见下方 2026-11-08 / 2026-11-09 增量与「台账复核更正」；逐项验收记录继续按其实际证据关闭）。依据 [产品需求](REQUIREMENTS.md)、当前源码、测试源码、工作流与已有手工检查清单。本文跟踪需求剩余工作，不新增功能范围；需求章节号均指 REQUIREMENTS。§12 为参考来源，无独立实现项。

**源码已写 ≠ 生成完成 ≠ 编译完成 ≠ 测试通过 ≠ 平台验收通过。** 2026-11-08 起本机补齐工具链并实跑；2026-11-09 最新一轮：FRB/l10n 正常生成、`python -B scripts/check_sources.py` 严格模式 PASS（本次复核再次 exit 0）、Rust fmt/clippy/test 全绿（26 个测试二进制，173 项通过，其中 lib 95 项）、`flutter analyze` 0 项、`flutter test` 200 项通过（含网格语义断言 5 项）、`integration-check.ps1 -Device windows` **7/7 entry PASS**（含桌面交互/内存入口，含语义标签的最终树）、Windows Debug 构建成功（Release 需在发布门禁重跑，详见下方增量与更正节）。2026-11-08 记录的 105 项 / 5 entry 是当时快照（entry 集合后来新增了 `auth` 与 `interaction_memory`）。旧记录中的 PASS 只属于当时快照；下表中的专项运行、性能、DPI/读屏、Linux 和发布证据须独立关闭，不从 Windows 构建或本机门禁结果推导。本轮新改动也不自动继承此前构建结论。

台账状态含义：

| 标记 | 判定与关闭条件 |
|---|---|
| 待实现 | 当前没有完整实现，或只有局部实现；须补齐该行明确列出的缺口。 |
| 待验证 | 已有手写实现/测试/工作流，但缺当前版本生成、编译或执行结果；须留存对应结果。 |
| 需平台证据 | 须在目标 Windows/Linux 环境记录机器、版本、步骤与实际结果；静态核对和 mock 测试不能关闭。 |
| 外部条件 | 依赖远端管理设置、证书、授权、发布渠道或目标平台决策；本地文件不能证明已落实。 |

同一项可同时有多种状态。没有证据的项保持开放；后续关闭应附 commit、工具链、命令/场景、运行编号或报告、通过/失败/未覆盖范围，不以勾选模板或文件存在代替证据。

## 共用前置项（§7.2、§9.1、§10）

| 编号 | 状态 | 当前依据 | 剩余工作/所需证据 |
|---|---|---|---|
| G01 | 锁文件已有；本机扫描已跑，CI 联网复核待办 | `pubspec.lock` / `Cargo.lock` / `THIRD_PARTY_NOTICES` 在库；本机 `scripts/security-check.sh` 在公告库取不到时为 INCOMPLETE(exit 3)，网络恢复后同一脚本端到端 PASS(exit 0，9 项检查全 PASS)；两个网格 POC 的传递包逐包读 LICENSE 正文均通过。旧表述"许可与扫描证据尚未取得""Windows 构建是此前版本的历史基线"只属 2026-11-08 之前的快照，已被上述本机结果覆盖 | 仍须在 CI 联网环境对**当前**锁文件复跑 audit/deny/OSV/secret scanning 并留证；逐版本核 LICENSE 正文/传递依赖、NOTICE 和 §7.2；新增/变更依赖重新解析并复核，旧扫描结果不覆盖新依赖；POC 包许可不等于生产引入后的完整 NOTICE。 |
| G02 | 本机已关闭；干净检出/CI 再生成一致性待验证 | 2026-11-08 本机实跑 FRB codegen 与 `flutter gen-l10n`，补齐 11 个生成缺口（9 函数 wrapper + `audit_export_history`/`grid_preferences` 两 module）；`python -B scripts/check_sources.py` 严格模式 PASS，2026-11-09 复核仍 exit 0。原表述"当前 `check_sources.py` 默认退出 1""生成待补"只属 2026-11-08 之前的快照 | 公开 API/ARB 变更后仍须用固定兼容版本 FRB codegen 与 `flutter gen-l10n` 重生成，并在干净检出/CI 核对无非预期差异；禁止手补生成区。本轮新建的 `poc/grid_columns_trina` 只有包内独立锁，不影响根锁与根生成物。 |
| G03 | Windows 本机已跑，CI/平台证据待补 | 2026-11-09 本机：cargo fmt/clippy/test 全绿（26 个测试二进制、173 项通过，lib 95 项）、`flutter analyze` 0 项、`flutter test` 200 项、`integration-check.ps1 -Device windows` **7/7 PASS**（新增 `interaction_memory_test`，真实窗口按键与 RSS 采样）、Windows Debug 构建成功（Release 待发布门禁重跑）；`scripts/verify.ps1`、`scripts/integration-check.ps1`、`ci.yml` 入口在库但从未在真实 runner 执行 | 在 CI/目标平台用同一组命令重跑并保留日志与失败修复结果；DPI/读屏矩阵、Linux 桌面、打印/系统对话框专项仍 NOT RUN。离线 `check_sources.py --allow-pending-generation` 仅是资源/导入/依赖名检查。 |

以下所有“待验证”功能均继承 G01～G03，不在每行重复全部命令。

## 2026-11-08 本机门禁闭环增量（优先于下方历史快照）

本机补齐 Flutter 3.47.8 / Dart 3.13.7 / rustc 1.99.1 / FRB codegen 2.13.0 / pwsh 7.6.9 后，下列项在本机实跑关闭（证据为本机运行；本节写作时仓库尚无 git 元数据，故 commit 字段为空——2026-11-09 本副本已初始化并提交，提交说明见 X 表后的备注，但仍不能据此核对远端设置；CI/远端结果须单独取得）：

- **G02 生成物**：FRB codegen 与 `flutter gen-l10n` 实际执行，补齐此前 11 个生成缺口（9 个函数 wrapper + `audit_export_history`/`grid_preferences` 两 module）；`python -B scripts/check_sources.py` 严格模式 PASS。锁文件哈希与生成前后一致（pubspec.lock 9d9adb…、Cargo.lock 9d1b9c…），未手改生成区。G02 的"再次生成无非预期差异"本机已复现两次 codegen/三次 l10n。
- **G03（Windows 部分）**：`cargo fmt --check`/`clippy -D warnings`/`cargo test` 全绿（lib 89 + 全部集成测试，含 restart 子进程测试）；`flutter analyze` 0 项（清理 53 个积压 lint）；`flutter test` 105 项全过；`pwsh scripts/integration-check.ps1 -Device windows` **5/5 entry PASS**（audit_page / current_api / export_history_api / grid_store / simple，逐 entry 独立进程、隔离临时数据目录、真实加载 Rust 动态库，证据在 build/reports/integration-windows-*）；Windows Debug/Release 构建成功。DPI/读屏矩阵、Linux 桌面、打印/系统对话框专项验收仍未执行。（本条 5/5 与 105 项对应当日 5 个 entry / 105 个测试；2026-11-09 新增 `auth_test.dart` 等后为 6 个 entry、167 项测试，最近一轮 6/6 PASS，见下方 2026-11-09 各节。）
- **实际修复的产品缺陷**（由首次执行既有测试暴露）：① 打印预览在页面销毁时 busy 锁经 `showDialog` future 永久泄漏（改 Future.any + 对话框卸载监听；`route.completed` 仅在页面挂载时等待）；② 外部诊断对话框同类泄漏（同一模式）；③ 外壳 IndexedStack 在 Flutter 3.47 新实现（无键 `_VisibilityScope` 包裹子项）下，子列表收缩时按键匹配退化为按位置更新，关闭一个标签会销毁其他隐藏页状态（页面内容改用 per-kind GlobalKey，元素框架内重定位）；④ 审计筛选栏在 780px 宽度下 Row 溢出 88px（Print/Export 按钮并入 Wrap）。修复均有对应测试覆盖。
- **测试期望与实现同步**：settings_import_audit/集成 current_api 的配置版本断言按 v5 修正；grid 内存存储未保存 scope 按契约断言 null；列设置 Apply 按钮、Recheck status 等选择器按实际组件类型/文案修正；集成 simple_test 在桌面窗口高度内先滚动再点击并等待真实异步完成。
- **新增 ARB**：taskPhaseRunning/taskPhaseCancelled（持久历史行不再借用活跃进度文案 "Exporting audit records…"）。
- **环境边界**：C 盘满（os error 112，0 GB 可用）导致 cargo 注册表写入失败；本机构建须前置 `CARGO_HOME=D:\cargo-home`（D 盘 22 GB 可用），CI/其他机器不受影响。`integration-check.ps1` 临时目录清理在杀毒短暂占用新写 keel.db 时增加有界重试（12×1s；所有权/重解析点/符号链接检查全部前置不变，重试耗尽仍失败即 FAIL，清理失败仍判 FAIL 的契约未放松）。Python 回归最终 81/89 本机通过（1 skip 有理由）：本批修复 test_check_sources 的 2 个 POSIX 路径断言（脚本消息规范 `as_posix()`）、test_security_check 的 `/bin/bash` 硬编码（改 PATH 解析）与 python3 符号链接目标（改绑定运行解释器）、test_workflow_evidence 的 bash 缺失跳过与 python3 别名 shim、test_symlink_and_conflict 的大小写冲突场景在 NTFS 不可表达的 skip；剩余 8 个失败（test_security_check ×7 + grid_poc 临时目录杀毒占用 ×1）为 MSYS bash exec 符号链接与杀毒扫描的环境边界，测试夹具本为 POSIX CI 设计，权威环境是 Linux CI（cargo-license 0.7/cargo-deny 0.20.2/cargo-audit 0.22.2 本机已在 PATH）。
- **T01 查询性能（数据/查询层）本机关闭**：`scripts/grid_poc.py` 以 warm 模式实跑 10000/100000/1000000 三档（每场景 5 次重复），结果与机器环境写入 `build/reports/grid-poc/grid-poc-results.json`（SQLite 3.53.4 / Windows 11 / AMD64），合成库与按模板填写的查询层报告在 `build/reports/grid-poc/`。汇总：页面中点翻页中位数 1.53/10.27/132.11 ms，过滤页 2.46/42.41/80.64 ms，过滤计数 2.00/30.10/400.50 ms。**仅覆盖数据/查询层**；Flutter 渲染、虚拟化、剪贴板、生命周期与平台矩阵仍 NOT RUN（见 grid-poc-report.md 逐行）。其中虚拟化、剪贴板、生命周期与 Fluent 宿主已在 2026-11-08 / 2026-11-09 的隔离 POC 中补到 widget 级（见下方两节），平台矩阵仍 NOT RUN。
- **G01/D01 本机安全扫描证据部分取得**：`bash scripts/security-check.sh` 在本机实跑（python3 经 `D:\cargo-home\bin\python3.exe` shim 指向真实解释器；cargo-deny 0.20.2 / cargo-audit 0.22.2 / cargo-license 已装），结果 **status INCOMPLETE、退出码 3**：rust-licenses / deny-licenses / deny-bans-sources / dart-deps / osv / gitleaks / hygiene 全部 PASS；deny-advisories UNSURE、audit PARTIAL（RustSec 公告库本机网络取不到）。按 README 语义：无违规但公告库取不到，发布不放行，须在能联网的 CI 重跑——"unknown 严格阻断"边界保持原样，未放宽。报告在 `build/reports/security-*/summary.json`。
- **2A 候选包（poc/grid_columns）自身门禁本机关闭**：pub get 产出 pubspec.lock；`flutter analyze` 0 项；`flutter test` 21/21 全过；`dart format` 0 项。修复真实缺陷：POC ARB 的 ICU select 分支 `id{...}` 被 gen-l10n 解析器拒绝导致 gen-l10n 失败——改为五个独立列名键 + Dart switch（下拉框标题 `ID/Text/Quantity/Date/Kind` 契约不变，测试仍全过）。传递许可初核：pluto_grid 8.1.0 MIT、rxdart Apache-2.0、其余为 Dart/Flutter 官方 BSD 系（clock/fake_async/material_color_utilities 包内无独立 LICENSE 文件，正式接入时按 G01 逐版本复核）。PlutoGrid 只读 POC 页由此具备可运行门禁；生产接入决策与 §6 桌面矩阵仍开放。
- **B02 候选 ZIP 本机产出并校验通过**：Release 产物 + LICENSE/THIRD_PARTY_NOTICES/CHANGELOG 组装为 `build/release/keel-windows-v0.1.0-local`，`release_evidence.py` 生成 evidence（SHA256SUMS、SPDX 文件清单、build-info、安全扫描按哈希绑定本机 INCOMPLETE 摘要、Cargo/Dart 组件清单、锁文件快照），`package_release.py` 打出 15.6 MB ZIP，`verify_release_evidence.py --root/--zip` 均 exit 0，外部 `zip.sha256` sidecar 写入。**边界如实记录**：绑定的是本机 INCOMPLETE/exit 3 扫描摘要（公告库网络受限）；候选未签名、非正式发布；干净环境安装/升级/卸载、Defender 记录、CI 产出对照仍未执行。
- **仍然开放**（未因本批改变）：Linux 桌面验收（B03）、DPI/读屏与资源释放实测（U04/P02）、网格候选锁定与生产接入决策及 POC 桌面矩阵（T01 真实 OS 焦点/进程内存/DPI 行；虚拟化与剪贴板已在 widget 级 POC 覆盖）、打印系统专项（F01 平台项）、签名/发布链与远端标签保护（D02–D04）、CI 真实 runner 首跑、审计 CSV 两平台文件交互专项、品牌资源授权、可联网环境下的 RustSec 公告库完整扫描、干净环境安装/升级/卸载（B02 剩余）。

## 2026-11-08 网格 POC 扩展与 DPI/文本缩放自动化（本批实跑）

- **网格 POC 扩展（隔离包，未接生产依赖）**：`poc/grid_columns` 新增可编辑模式、12/1k/10k/100k/1M 数据集、
  `PlutoLazyPagination` 分页、对照 `rust/src/services/grid_fixture.rs` 的 Dart 校验层与合成分页源；
  `Ctrl+V` 替换为安全动作（空剪贴板不崩溃、1 MiB 上限）。实跑 `flutter gen-l10n` / `flutter analyze`（0 项）/
  `flutter test`（**48 通过 + 1 有理由 skip**）/ `dart format`（无差异）。覆盖：范围复制 TSV、合法/非法粘贴、
  1M 行只物化 200 行且虚拟化渲染、翻页替换、只读拒绝。
- **实测 PlutoGrid 8.1.0 缺陷**（已写入 `docs/GRID_POC.md` 并用测试固定）：`rows` 列表必须可变（惰性分页会
  原地清空）；数字/日期列静默把非法输入纠正为 0；Dart `int.tryParse('0x10')` 与 Rust 解析不一致；
  内置粘贴对空剪贴板断言且无上限；**惰性分页无销毁守卫**——取页在途时销毁页面会在完成回调里
  `jumpTo` 已分离的 `ScrollController` 并断言。生产接线须自建页脚或在取页期间禁止销毁。
- **trina_grid 对比**：只读核对 2.4.0（2026-10-31，MIT，归档 SHA-256 `cda88c3a…a83`），会额外引入
  `pdf ^3.11.3` 与 `shadcn_ui >=0.55 <0.58`；当时**未加入 POC 锁文件，矩阵 NOT RUN**。暂以 pluto_grid 为候选，
  锁定决定保持开放，须用同一用例对比。报告：`build/reports/grid-poc/grid-poc-flutter-20261108.md`。
  （2026-11-09 已建独立包 `poc/grid_columns_trina` 用同一套用例实跑两轮，见下方「2026-11-09 网格候选同用例对比与 Fluent 宿主」；本节保留为当日快照。）
- **DPI/文本缩放自动化（U04）**：新增 `test/ui/shell_dpi_test.dart`（5 项）覆盖
  1280×720 / 1366×768 / 1920×1080 × 100/125/150/200%、200% 文本缩放、640×360 最小逻辑窗口的
  页面搜索与打开页面、深浅主题；`test/ui/audit_page_test.dart` 增加 200% 文本缩放用例。据此真实修复四处：
  ① 首页状态 pill 在 640×360 溢出 23px（`Flexible` + 省略号）；② 审计页 200% 文本下筛选区把表格压到 53px
  （筛选区最多占窗口高度 40%、80–400px 区间内滚动）；③ 分页页脚摘要在 200% 文本下溢出 444px
  （`Expanded` + 省略号）；④ 页头说明（`UiPageHeader` subtitle）在 2x 文本下无限增高，改为最多两行省略。
- **S03 脱敏补齐（§4.2）**：`rust/src/diagnostics/redact.rs` 新增“其他绝对路径”与“电话号码”两条规则
  （Windows 盘符、POSIX 多段路径；带 `+`/括号/分隔符的号码与 CN 手机号形态），并显式排除日期、版本号、
  相对路径和 URL 里的路径，保留既有 `<user>` 占位语义。新增 6 项单元测试（含密码/Token/连接串/邮箱/
  路径/电话混在一行的泄漏回归，以及超长数字串不得退化为 O(n²) 的规模守卫），
  `cargo test --lib diagnostics` 38/38 通过。业务名称不可规则识别，仍按“默认不收集/提示检查”处理。
- **本部门禁实跑**：`cargo fmt --check` / `cargo clippy -D warnings` / `cargo test` 全绿（30 个测试目标全 ok）；
  `flutter analyze` 0 项；`flutter test` **111 项全过**；`check_sources.py` PASS；
  `integration-check.ps1 -Device windows` 在最终源码（含 S03 脱敏改动）上 **5/5 entry PASS**
  （`build/reports/integration-windows-595bb1f54e2849d4829c5ad9476bd88c/summary.json`，14:43–14:56 UTC）。
  期间一次并发运行（13:35 UTC，与隔离 POC 的 `flutter test` 重叠）
  `simple_test` 报 `did not complete` 并以 `PathNotFoundException` 删除
  `flutter_tools` 的 listener 临时文件失败；同一 entry 在 13:27 与去并发后的 13:52、14:56 三次单独运行均 PASS，
  且改动只涉及布局与脱敏规则，判定为本机并发/临时目录抖动，不是代码回归——记录在此，不当作已修复项。
  自动化只证明布局不溢出与命令可达，不替代真机 DPI/读屏/多屏与 Linux 验收。

## 2026-11-08 往来单位参考闭环与外壳导航（二开示例，非底座业务范围）

本轮补一个可复制的业务纵向切片（列表、表单、批量操作、权限、审计），并补齐侧栏的模块/收藏/最近访问与折叠：

- **Rust**：迁移 `0005_customers.sql`（`customer` 表 + 编号唯一约束）、`data/customer.rs`
  （分页/关键词/类型/状态过滤、`code|name|kind|updated_at` 排序白名单、LIKE 转义）、
  `services/customer.rs`（编号统一大写、名称/电话/邮箱/备注校验、`customers.manage` 权限、
  创建/更新与 `customer.create` / `customer.update` 审计同事务）、`api/customers.rs`
  （`list_customers` / `create_customer` / `update_customer` /
  `delete_customers` / `set_customers_active`）。新增权限 `customers.manage`
  （admin、operator；viewer 只读），读取不分角色。
- **批量写事务**：删除与批量启停在一次事务内逐条校验并写审计
  （`customer.delete` / `customer.activate` / `customer.deactivate`）；任一记录不存在整批回滚，
  单批上限 200、空列表拒绝，权限只检查一次。
- **Flutter**：`lib/features/customers/state/customers_providers.dart`（可覆盖数据源与写入器）、
  `lib/ui/pages/customers_page.dart`（搜索/类型/状态筛选、分页、**单选/Ctrl 多选/Shift 范围**、
  **Ctrl+C 复制 TSV（含公式前缀防护）**、方向键/Home/End/Esc、**批量启用/停用**、
  **删除（二次确认、危险样式）**、编辑按钮、新建/编辑对话框、本地预检 + Rust 边界复核、
  失败保留输入、只读角色提示），已在 `app.dart` 注册为 `customers` 页。中英双语 ARB 50 键。
- **外壳导航（§2.2）**：侧栏补齐“模块 / 收藏 / 最近访问”三组与折叠态；收藏上限 50、最近 10 项，
  打开页面记访问（关闭自动选页不记），未知 kind 只隐藏不回写；`test/ui/shell_nav_test.dart` 6 项。
- **测试**：`rust/tests/customer_test.rs`（真 SQLite：校验矩阵、编号大小写唯一、分页/过滤/排序、
  更新撞号回滚、viewer 拒绝、operator 放行、审计条数与 actor）；
  `test/ui/customers_page_test.dart`（15 项：分页与末页删空回退、搜索重置页码、只读角色与按钮禁用、本地校验、
  服务端重复保留对话框、选中后编辑提交 id、Ctrl/Shift 多选与 TSV 复制、键盘导航与 Esc、
  删除二次确认/取消、批量停用、Enter 编辑/Delete 删除快捷键、RTL 布局、200% 文本缩放、
  640×360 最小逻辑窗口）；另有 `test/l10n/arb_parity_test.dart`（3 项）与 shell RTL 用例；
  `integration_test/current_api_test.dart` 新增真实桥接往返（创建/列表/更新/重复/权限/
  批量启停/删除/审计）。
  小窗口下表格整体横向滚动（最小 720），窗口高度 < 520 时整页滚动——由最小窗口用例固定。
  末页被删空（或数据收缩）时自动回退到最后一个有数据的页，不停在空页——由分页边界用例固定。
- **边界**：这是二开示例，不是 Keel 自带业务模型；审计日志仍保持只读，编辑只发生在本示例实体。
  单元格/区域粘贴与内联编辑仍只存在于隔离 POC（见 `docs/GRID_POC.md`），生产网格接入未决定。
  文本排序使用 SQLite BINARY 比较（CJK 按码点，不做拼音/本地化排序），需要 ICU 的本地化排序未实现。
- **实测**：`cargo test` 全绿（32 个测试目标）；`flutter test` **145 项全过**；
  `flutter analyze` 0 项；`check_sources.py` PASS；FRB codegen 正常生成 `lib/src/rust/api/customers.dart`
  （重命名 `CustomerListParams`/`CustomerSortKey` 消除与审计 DTO 的重名警告）；
  `integration-check.ps1 -Device windows` **5/5 PASS**
  （`build/reports/integration-windows-integration-windows-abbc92e2a96b4ac59fcb54dd181c5d52/summary.json`，21:02–21:11 UTC；
  `current_api_test` 16 项含往来单位的创建/列表/更新/重复/权限/批量启停/删除/审计真实桥接往返）。
  平台证据（真机 DPI/读屏、Linux、签名发布）仍按下方外部条件表处理。

## 2026-11-09 登录保护（可选应用门禁）

- **能力**：新增可选的“登录后才能进入”开关（默认关闭）。开启后启动停在登录页，
  口令通过后才发布本地用户；失败登录写审计并固定延迟 200ms；已有口令时改口令/关闭保护都需当前口令。
- **存储与边界**：`app_security` 表只存 **Argon2id 加盐校验值**；开关存数据库且**不进入可导入配置**，
  外部配置导入无法打开或关闭登录（避免把人锁在门外）。这不是 OS 凭据存储集成，也不是对本机管理员的隔离。
- **代码**：`rust/migrations/0006_auth.sql`、`data/auth.rs`、`services/auth.rs`、`api/auth.rs`（FRB 正常生成）、
  启动门禁（`services/startup.rs` 在锁定时不发布当前用户）、`lib/features/auth/state/auth_providers.dart`、
  `lib/ui/pages/login_page.dart`、`lib/ui/pages/security_page.dart`（导航新增 `security`）、
  用户菜单“立即锁定”；错误码新增 `KEEL-AUTH`；依赖新增 `argon2 0.5.3`（MIT OR Apache-2.0）。
- **测试**：`rust/tests/auth_test.rs`（口令策略、开启/关闭、锁定/登录、审计、不落明文）；
  `test/ui/login_page_test.dart`（锁定启动、错误口令、正确口令解锁、Enter 提交、数据库未就绪）；
  `test/ui/security_page_test.dart`（首次开启一步设口令、确认不一致、关闭/改口令需当前口令、viewer 只读、立即锁定）；
  `integration_test/auth_test.dart` 真实桥接往返（弱口令拒绝、开启、锁定、错误/正确登录、关闭、审计）。
- **实测**：`cargo test` 32 个测试目标全绿；`flutter analyze` 0；`flutter test` **149 项**；
  `check_sources.py` PASS；`integration-check.ps1 -Device windows` **6/6 entry PASS**
  （`build/reports/integration-windows-939cfd6591eb4fc792a9d04cdad2d588/summary.json`，22:22–22:26 UTC，
  新增 `auth_test.dart` 真实桥接往返，`simple_test` 改为先建库再等外壳出现）。
- **未做**：OS 凭据管理器/Secret Service、持久失败锁定与管理员重置、按用户口令、企业 SSO；
  离线爆破与删库绕过属已知边界，已写入 AGENTS §11 与需求 §4.1。

## 2026-11-09 页面命令统一注册（§1.1）

- `UiPage` 新增 `commands: List<UiCommand>`；`UiCommand` 含稳定 id、本地化标题、图标、快捷键提示、
  `isEnabled(ref)` 与 `onInvoke(context, ref)`。外壳只渲染**活动页**的命令到命令栏与“工具”菜单，
  没有命令时菜单显示占位文案。
- 已接入：审计页（刷新、导出 CSV、打印当前页）、往来单位（新建）、登录保护（立即锁定）、
  备份（刷新）、诊断（刷新）、任务（刷新持久历史）。
  打印命令改为按 Provider 重新读取当前筛选/布局，不依赖页面局部状态。
- 快捷键仍由页面自己绑定（命令只做发现提示），避免外壳与页面双触发；`Ctrl+P` 在命令上仅作提示。
- 同时修了英文复数：删除多条用 `Delete {count} entries?`，单条用 `Delete 1 entry?`（ICU plural），
  中英占位符仍由 `test/l10n/arb_parity_test.dart` 固定。
- 测试：`test/ui/shell_commands_test.dart`（命令栏渲染、执行、`isEnabled=false` 禁用、工具菜单镜像、
  无命令页占位）。本机门禁实跑：`flutter analyze` 0、`flutter test` **149 项**、`check_sources.py` PASS、
  `integration-check.ps1 -Device windows` **6/6 PASS**
  （`build/reports/integration-windows-518fa4b4064b4aff8bff73bd377793e2/summary.json`，02:26–02:33 UTC）。
- 未接：备份“立即备份/恢复”、诊断“导出诊断包”、导入设置页面的命令——这些需要页面内的确认/预览状态，
  统一命令只接不依赖页面局部状态的动作；需要时先把动作改为 Provider 驱动再接入。
  （2026-11-09 已补：见下节。）

## 2026-11-09 最小窗口布局兜底（§2 屏幕与 DPI）

- 补命令栏测试时在 640×360（1280×720 @200%，项目声明的最小逻辑窗口）实测到既有溢出：
  备份页 69px、诊断页 271px、审计页 102px、往来单位页横向 197px + 纵向 41px、登录保护页横向 89px；
  命令栏本身未超宽，问题是页面在去掉外壳后只剩约 148px 高度时的固定布局。
- 修复：新增 `UiScrollablePage`（`lib/ui/widgets/ui_layout.dart`，可用高度 < 640 时整页滚动并按 640
  布局，正常窗口行为不变），备份 / 诊断 / 审计 / 往来单位 / 登录保护五页接入；`UiEmpty` 在可用高度
  小于内容时改为内部滚动（不再溢出，空状态仍居中）；往来单位页脚 < 560 宽时由单行 `Row` 换成
  换行 `Wrap`（页脚键与行为不变）；登录保护状态行文本改为 `Expanded` 以便换行。
- 测试：新增 `test/ui/command_bar_small_window_test.dart`（8 项），在最小窗口下逐个打开
  备份 / 诊断 / 导入设置 / 审计 / 往来单位 / 登录保护 / 任务 / 表单样例，断言无溢出异常、
  命令栏宽度不超逻辑宽度、关键命令文案仍存在。桥接样例页在 build 时即调用 Rust，widget 测试没有
  动态库 → 未纳入；它由 `integration_test/simple_test.dart` 在真实桥接下覆盖，但那里不校验最小窗口。
  本机实跑：`flutter analyze` 0 项、`flutter test` **167 项全过**、
  `integration-check.ps1 -Device windows` 在最终代码上 **6/6 PASS**
  （`build/reports/integration-windows-791dca6e46d5476da6c0190947a45416/summary.json`，06:16–06:23 UTC；
  集成条目覆盖启动与既有审计/登录/桥接/网格流程，不点按最小窗口断言）。
- 边界：这是布局兜底，不是最小窗口的可用性验收——640×360 下页面需要整页滚动、内容密度很低，
  真机 DPI/读屏/多屏仍按 X06 人工执行；桥接样例页的最小窗口布局仍未验证。

## 2026-11-09 页面命令补全（备份恢复 / 诊断导出 / 导入设置）

- **命令可用性改为 Provider**：`UiCommand.isEnabled`（布尔闭包）删除，改为
  `isEnabledProvider: Provider<bool>`，外壳在 build 顶部统一 `ref.watch`。原因是实测缺陷——
  布尔闭包虽在外壳 build 中调用，其内部 `ref.watch` 不建立订阅：选中备份行后命令仍是禁用态，
  且外壳不再重建（调试日志确认 `backupSelectionProvider` 已更新但命令栏未刷新）。审计导出/打印、
  往来单位新建、登录保护锁定同批迁移到 Provider，行为与之前一致但状态变化会真正刷新命令栏。
- **备份恢复**：列表改为单选（点击行、↑/↓/Home/End/Esc、Enter 触发恢复；选中行强调色 +
  左侧标记 + `Semantics.selected`），新增队列滚动跟随。命令新增「立即备份」「恢复所选」
  「取消待恢复」，`features/backup/backup_actions.dart` 收拢动作，页面按钮与命令共用同一套
  二次确认、身份/权限复查与忙锁；选中项不在最新列表时命令禁用，避免用陈旧选择登记恢复。
- **诊断导出**：页面 `_exportOpen` 提升为 `diagnosticExportOpenProvider`，
  `exportDiagnosticPackAction` 统一打开单次预览/导出对话框；命令栏新增「导出诊断包」，
  对话框打开期间命令与页内按钮同步禁用。
- **导入设置**：新增 `SettingsImportPageActions` 注册表（仿 `closeGuards`，页面 initState 注册、
  dispose 注销）与 `settingsImportShellCommands()`，命令栏接入「选择配置文件 / 取消 / 重试（重载）」；
  可用性同时受权限、`settingsWritableProvider`、`workspaceNavigationWritableProvider` 与导入写保护约束。
  预览与确认仍留在页内——它们绑定当前文本框内容和单次预览句柄，未提升为全局状态。
- **测试**：新增 `test/ui/backup_page_test.dart`（4：选中驱动命令、键盘选择、待恢复命令、只读角色）、
  `test/ui/diagnostics_commands_test.dart`（2：导出命令单飞与关闭后恢复、只读角色）、
  `test/ui/settings_import_commands_test.dart`（4：文件命令走页面选择器、取消清空输入、
  重载仅在上次回读失败后可用、只读角色）；`shell_commands_test.dart` 的禁用命令改用 Provider。
  本机门禁实跑：`flutter analyze` 0 项、`flutter test` **159 项全过**、`check_sources.py` PASS、
  `integration-check.ps1 -Device windows` **6/6 PASS**
  （`build/reports/integration-windows-dea034954b5f4787b132763b74fe2a64/summary.json`，03:08–03:19 UTC）。
  Rust 未改，因此未重跑 cargo 门禁。集成条目覆盖应用启动与既有审计/登录/桥接/网格流程，
  **没有点按本轮新增的备份恢复、诊断导出、导入设置命令**；真机 DPI/读屏与备份页键盘选择仍待人工验收。

## 2026-11-09 网格候选同用例对比与 Fluent 宿主（T01 / §6）

- **两包同一套用例**：`poc/grid_columns`（pluto_grid 8.1.0）与新建的 `poc/grid_columns_trina`
  （trina_grid 2.4.0）1:1 移植（页面、fixture 契约、列适配层、缺陷探针、真实按键分发）；
  第二轮两包各加同一份 7 项 FluentApp 宿主用例（`fluent_ui 4.17.0`，仅 `dev_dependencies`）。
  **根 `pubspec.yaml` / 根锁未加网格依赖，未接生产列表**；两包各解析独立锁
  （trina 91 包、pluto 35 包，url 全为 pub.dev）。
- **门禁计数（本机 Flutter 3.47.8 / Dart 3.13.7）**：两包 `flutter analyze` 0 项、
  `dart format --output=none --set-exit-if-changed` 0 差异、`flutter gen-l10n` 正常；
  `flutter test` **trina 62 通过 / 0 skip；pluto 54 通过 + 2 skip**（pluto 两项 skip 为缺陷 5 复现用例
  与本轮缺陷 8 探针，均带理由）。证据：`docs/GRID_POC.md` 2026-11-09 两节、
  `build/reports/grid-poc-trina-20261109.md`、`build/reports/{trina,pluto}_fluent_host.log`
  与 `*_fluent_suite.log`（pluto 缺陷 8 原始失败栈在 `build/reports/pluto_fluent_host_failure.log`；
  快捷键覆盖修复的变异负控制证据在 `build/reports/trina_mutation.log`）。
- **pluto 缺陷 8（宿主层，本轮新发现）**：Fluent 页内没有 Material 祖先时，pluto_grid 8.1.0
  的单元格进入编辑即抛 `No Material widget found`（PlutoTextCell → TextField）；trina 2.4.0 在
  网格外层按需补 `Material(type: transparency)`（源码指向其 issue #423），同一断言通过。
  选 pluto 则每个网格页必须自带 Material 包裹。
- **共同宿主前提（不是候选缺陷）**：`FluentApp` 的 `localizationsDelegates` 默认只提供独立包
  `material_ui` 的代理，而非 Flutter `material` 的 `MaterialLocalizations`；网格编辑器需要后者，
  宿主必须另注入 `flutter_localizations` 的 `GlobalMaterialLocalizations`（生产应用已如此）。
  首次跑该用例即因此失败，补委托后两候选均通过。
- **trina 侧对照**：缺陷 5（惰性分页销毁守卫）已修（`mounted` + fetch version 双守卫，复现用例去 skip 通过）；
  缺陷 1（rows 必须可变）、2（数字列静默纠正）、4（内置粘贴仍强解包且无上限）与 pluto 同类，仍需同样绕行；
  新增缺陷 6（默认快捷键表按插入序取首个匹配，pluto 式 `LogicalKeySet` 覆盖会被内置粘贴静默压住）
  与缺陷 7（取页失败只 `debugPrint`，无错误事件/重试面），均已有测试固定并给了绕法。
- **供应链**：trina 官方归档独立下载计算 SHA-256 `cda88c3ad697…f463a83`，与 pub.dev 元数据一致；
  包内 LICENSE 正文 MIT。相对 pluto 锁新增 58 个传递包（pdf 3.13.1 / shadcn_ui 0.57.4 树），
  逐包读 LICENSE 均为 MIT / BSD-3-Clause / Apache-2.0。完整 NOTICE 核对与 `security-check.sh`
  留到正式引入生产依赖时做，本轮只是 POC 级扫描。
- **结论与边界**："同一用例跑两者"的对比门禁已完成并锁定 trina_grid 2.4.0（ADR-012）；
  生产依赖与首个页面接线见下方 2026-11-09 锁定/接线节。

## 2026-11-09 Windows 桌面交互与 P02 内存证据（U03 / P02 / V01）

- **新增入口**：`integration_test/interaction_memory_test.dart`（第 7 个 entry），
  由 `scripts/integration-check.ps1 -Device windows` 在真实桌面窗口 + 真实 Rust 动态库下执行；
  隔离临时数据目录中种子 1 份备份 + 120 个往来单位（含审计行）。
- **真实按键**：审计表点击选中 → ↓/↑/End/Home/Esc 驱动行选择与复制按钮可用性，
  Ctrl+K 浮层期间按键不穿透、Esc 关闭后 ↓ 恢复生效；关闭标签后按键不误触其他页；
  备份页 ↑/↓ 选择、Enter 弹出恢复确认、Cancel 后 `pendingRestore()==null`、Esc 清选后 Enter 不再弹框。
  未使用真实系统剪贴板。
- **P02 采样**（2026-11-09 含语义标签的最终树复跑）：5 轮“打开审计（筛选/翻页）→ 关闭 → 打开备份/诊断 → 关闭”，
  RSS 584.1 / 600.9 / 623.3 / 624.4 / 636.1 / 631.5 MiB，首末增量 49.7 MB（47.4 MiB），maxRss 683.5 MiB；
  5 轮无异常、无遗留 busy、末轮可重开并选行。debug 构建 + 种子数据，仅作回归护栏，不是生产基线；
  接入批次首跑序列为 633.9 → 678.6 MB（+42.6 MiB），RSS 随运行波动。
- **门禁**：`integration-check.ps1 -Device windows` **7/7 PASS**
  （`build/reports/integration-windows-13451c161d1641c9901e7d31f22c1422/summary.json`，14:22–14:35 UTC，
  含网格语义标签的最终树；native 构建包含 trina 传递依赖注册的 `jni` FFI 插件）；
  接入批次首跑为 `...504db0d2...`（11:12–11:24 UTC），首轮曾因用例自身页边界/焦点假设失败
  （`...897859ec...`，simple_test NOT_RUN），修复后重跑通过，不是环境抖动。
  `flutter analyze` 0、format 0、根 `flutter test` 200 项全过。
- **边界**：RSS 为 Flutter debug 引擎常驻 + 测试种子；隐藏页长任务、Release 构建、CPU/订阅计数、
  Linux 与 DPI/读屏仍未覆盖。Ctrl+W 快捷键只在焦点位于外壳子树内时到达（点工具条按钮后
  primaryFocus 在外壳外的路由 FocusScope），已记录，未改产品行为。
- **同日并行批次**：`UiScrollablePage` 回退阈值按宽/窄页面拆分（125% 下不再出现双纵向滚动条）、
  横向滚动条仅内容溢出时显示，新增 `test/ui/page_scroll_test.dart` 6 项（阈值回退即失败已验证），
  根 `flutter test` 180 → 186；与上述集成入口共用最终树，互不重叠。

## 2026-11-09 网格锁定与首个生产接线（T01 / F02）

- **锁定**：根 `pubspec.yaml` 加入 `trina_grid: 2.4.0`（MIT，包内正文已读），
  根锁由 pub.dev 重解为 110 项（102 hosted + 7 SDK + 1 path），新增 52 包全部为
  MIT / BSD-3-Clause / Apache-2.0（pdf、barcode、rxdart、universal_image 等 Apache-2.0），
  无 GPL/AGPL/未知；`THIRD_PARTY_NOTICES` 与需求 §7.2 已更新。决策记录：`docs/adr/012-grid-engine-selection.md`。
- **首个生产页面**：`lib/ui/pages/customers_page.dart`（往来单位示例）表格主体改为 `TrinaGrid`：
  6 个可见列（编号/名称/类型/联系方式/状态/更新时间）+ `id`/`active` 隐藏列，全部只读；
  `TrinaGridMode.normal` + `setSelectingMode(row)`（readOnly 模式不触发 `onSelected`），
  行选择由 `onSelected`/`onActiveCellChanged` 同步回页面既有 `_selected/_anchor/_cursor`；
  Ctrl/Shift 多选、复制 TSV、公式前缀防护、Enter/Delete/Esc、只读角色、分页、末页回退保持原契约；
  横向手写滚动移除，改由网格内部处理；空/加载/错误态与页脚不变。
- **测试**：原 15 项全部保留（仅首项增加 `TrinaGrid` 存在断言），新增 Shift+方向键锚点扩展、
  Home/End 行首末 2 项；根 `flutter test` **188 项全过**，`analyze` 0、`format` 0 差异。
- **1M 规模实测（数据/服务层）**：`rust/tests/customer_scale_test.rs` 以真实 SQLite 种子 100 万行后调用 `services::customer::list`：种子 13.78 s；首页 166.8 ms；末页（第 20000 页）325.5 ms；编号精确关键词 1.84 s；启用计数 320.6 ms；名称降序首页 162.8 ms。默认 `#[ignore]`（避免每次套件写约 100 MB 临时库），用 `cargo test --locked --test customer_scale_test -- --ignored --nocapture` 显式运行；不覆盖 UI 渲染与平台验收。
- **内联编辑与区域粘贴（同批已接）**：`code/name/phone/email` 可在网格内直接编辑，失败回滚该格并提示；Ctrl+V 从当前格起把 TSV 块写入四个可编辑列，整段经新增 `update_customers` 一次事务提交，超 1 MiB/越界/只读/空剪贴板不写入。kind/status/笔记仍走对话框。
- **边界**：网格把当前行视为选中，
  Ctrl 点击当前行取消选中的旧行为退化为无变化（无测试覆盖）；审计页仍是自绘冻结列表格；
  真实 DPI/读屏/暗色观感与 Win/Linux 平台矩阵仍 NOT RUN。trina 缺陷 6/7 的绕法已按 POC 落实
  （快捷键按默认表过滤后插入；取页错误由页面自行处理，本页为普通分页无惰性取页）。

## 2026-11-09 网格语义树断言（U04）

- **改动**：trina 单元格没有显式 Semantics，数据靠内部 `Text` 隐式暴露；往来单位网格外层加
  `Semantics(container: true, label: t.navCustomers)` 区域标签（复用现有 ARB 键，无新文案）。
- **测试**：新增 `test/ui/customers_grid_semantics_test.dart` 5 项（`ensureSemantics` +
  `find.bySemanticsLabel`）：区域/表头/单元格值进入语义树且区域节点非空壳、隐藏内部列
  （备注、原始 kind）不泄漏、只读角色与管理员暴露同样的数据标签、中文界面标签随语言切换、
  翻页后旧行标签移除新行出现。灵敏度已验证：临时移除区域标签时首项即失败，随后恢复。
- **门禁**：`flutter analyze` 0 项、`flutter test` **200 项全过**（195 → +5）、
  `check_sources.py` PASS、改动文件 format 无差异。Rust 未改，未重跑 cargo 门禁。
- **边界**：这是语义树层面的自动化回归，**不是读屏验收**——Narrator/Orca 的实际朗读顺序、
  焦点遍历与网格选中态播报仍 NOT RUN（X06）；trina 不暴露行选中语义，未伪造该断言。

## 外部条件阻塞清单（发布与平台，仓库内代码不能自证）

以下各项要么依赖仓库外的证书、账号、真实 runner、干净机器或发行渠道，要么需要产品决策；
**没有一项可以靠新增本地代码关闭**，也不因本清单存在而放宽现有门禁（未签名、`unknown`
许可/公告、缺证据一律继续阻断）。

| 编号 | 阻塞项 | 类型 | 当前证据 | 解除条件（不可降级） |
|---|---|---|---|---|
| X01 | Windows 代码签名（Authenticode + 时间戳） | 外部条件（证书/密钥）+ 产品决策 | `.github/workflows/release.yml` 第 131 行明确 `No signing keys are used`；`verify_signature_evidence.py` 对未签名/警告文件返回失败 | 取得代码签名证书与时间戳服务，在受控环境签名 `.exe`/`.dll`/安装器，采集报告并用 `--commit/--run-id/--run-attempt` 绑定；签名失败或缺失不得发布 |
| X02 | 构建来源证明（attestation） | 外部条件（仓库权限）+ 待实现 | `release.yml` 仅 `contents: read`，无 `id-token: write` / `attestations: write`，无 `attest-build-provenance` 步骤 | 新增 attestation job 权限与步骤，在真实 runner 产出并被下游验证；未实现前不得声称可追溯 |
| X03 | Defender / SmartScreen 记录 | 外部条件（干净机器、时间） | 无扫描记录；`WINDOWS_RELEASE_CHECKS.md` 全表 NOT_EXECUTED | 干净普通用户环境安装运行，记录 Defender 引擎/版本/范围/结果与候选包哈希；SmartScreen 信誉需真实分发积累，"扫描未检出"不等于安全 |
| X04 | 远端标签保护（ruleset） | 外部条件（仓库设置） | 本地 git 副本（`f554b64` 基线、`e3cf57d` POC 批次）无法核对远端；`release.yml` 由 `v*` 标签触发 | 在远端仓库配置 tag protection/ruleset 并留证据；本地文件不能证明已落实 |
| X05 | Linux 发行形态、打包与桌面验收（B03） | 产品决策 + 外部条件（缺目标机器/runner） | 无 `packaging/` 目录；`linux-desktop` CI job 从未真实执行；`LINUX_DESKTOP_CHECKS.md` 为 NOT_EXECUTED | 决定 deb/AppImage/tar 等形式与依赖策略，在目标发行版完成构建、启动、文件选择、托盘/退出与冒烟；本机为 Windows，无法代跑 |
| X06 | Windows 真机交互验收（U02 退出、U04 DPI/读屏/多屏） | 外部条件（需人工桌面会话） | 自动化已覆盖布局不溢出、命令可达与网格语义树断言（非读屏验收）；`DESKTOP_EXIT_CHECKS.md` 与 DPI 矩阵仍为 NOT_EXECUTED | 在 1280×720/1366×768/1920×1080、100–200% 缩放下人工执行叉号/Alt+F4/隐藏页草稿/多屏迁移/读屏与焦点顺序；自动化不能替代 |
| X07 | 干净环境安装/升级/卸载 | 外部条件（依赖 X05/X01） | 当前仅有 ZIP 候选（`build/release/keel-windows-v0.1.0-local`，15.6 MB，未签名） | 在无开发 SDK 的机器完成安装、升级、卸载与残留检查；ZIP 可运行不关闭该项 |
| X08 | 公告库完整安全扫描 | 外部条件（网络） | 本机 `security-check.sh` 为 INCOMPLETE(exit 3)：RustSec 公告库取不到；`unknown` 继续阻断 | 在可联网 CI 重跑 audit/deny/OSV 并钉定同一 revision；离线降级不得当作通过 |
| X09 | CI 真实 runner 首跑 | 外部条件（平台） | `ci.yml` / `release.yml` 从未在 GitHub Actions 执行，本机无法代跑 | 真实 runner 首次全绿并保留日志；YAML 与步骤断言不代替执行 |
| X10 | 品牌资源授权 | 外部条件（授权） | `assets/` 当前为空（占位品牌图已移除） | 重新引入图标/字体/素材时提供来源与许可，并按 §7.2 复核 |
| X11 | 发布者允许名单 / 身份判定 | 产品决策 | `verify_signature_evidence.py` 只校验"本次签名全部成功且哈希一致"，不评估发布者身份或允许名单 | 明确发布者身份策略与撤销/轮换流程后单独实现并留证据 |

X 表内"证据"列保留的是该表建立时的快照，不随本机进展改动；X04 已按当前事实改为"本地 git 副本无法核对远端"——
2026-11-09 本副本已初始化并提交（基线导入 `f554b64`、POC 批次 `e3cf57d`），但仍无法从本地证明远端 ruleset 已配置；
X08 的 INCOMPLETE(exit 3) 是公告库取不到时的降级结论，网络恢复后本机曾 PASS(exit 0)，而"必须在可联网 CI 钉定同一
revision 复跑"的解除条件不变。两者都仍为开放的外部条件。

## 2026-11-08 台账复核更正（按当前代码证据，优先于下方所有历史描述）

本轮逐条重扫源码与最近一次门禁报告，下列历史描述已与实现不符，按此更正；更正只改状态描述，
不新增需求范围，也不把"源码已接"升级为"平台验收通过"。证据：
`build/reports/integration-windows-8662d97c4d974f368d6b26ebc484324f/summary.json`
（2026-11-08 09:50 UTC 起，pwsh 7.6.9，status PASS，5/5 entry 退出码 0），
下列被更正文件的修改时间均早于该次运行，因此已被该轮 `cargo test` / `flutter test` / 集成执行覆盖。

| 历史描述 | 当前事实与代码位置 | 仍然开放 |
|---|---|---|
| V01「当前工作区未发现 `integration_test/current_api_test.dart`」 | 该 entry 存在；2026-11-08 更正时为 5 个 entry（audit_page / current_api / export_history_api / grid_store / simple），全部 PASS。2026-11-09 新增 `auth_test.dart` 与 `interaction_memory_test.dart` 后为 **7 个 entry**，最近一轮 `-Device windows` 7/7 PASS（见 §9 表 V01 行） | Linux 桌面逐 entry 执行、原生对话框/跨进程重启/性能泄漏的端到端证据 |
| 用户 JSONL 导入「未接产品导入界面，公开调用尚无取消句柄」 | `rust/src/api/users.rs` 已暴露 `prepare_user_import` / `run_user_import` / `cancel_user_import` / `user_import_progress`；`lib/ui/pages/users_page.dart` 经 `showUserImportDialog` 打开 `lib/ui/pages/user_import_dialog.dart`（进度条 + 取消按钮 + 取消失败/已取消文案）；`test/ui/user_import_controller_test.dart`、`test/ui/user_import_dialog_test.dart` 已存在 | 真实大文件/失败注入/取消竞争的平台执行证据；跨配置与 SQLite 事务、归档（ZIP）导入仍未实现 |
| T01 / F02「生产审计表未实现真正冻结列、列设置未完成」 | `lib/ui/pages/audit_page.dart` 已按 `GridFrozen.start/none/end` 分三段面板渲染并同步纵向滚动；列显隐/宽度/顺序/冻结经 `showGridColumnSettingsDialog` 编辑，`lib/features/grid/grid_column_preferences_provider.dart` 的 `RustGridColumnLayoutStore` 走 Rust 用户隔离 CAS 存储（`rust/src/api/grid_preferences.rs`、`rust/tests/grid_preferences_test.rs`）。隔离 POC 已补单元格/区域复制 TSV、编辑与粘贴校验、分页与行虚拟化（`docs/GRID_POC.md` 2026-11-08 节）。2026-11-09 已锁定 trina_grid 2.4.0，往来单位示例页改用网格（`lib/ui/pages/customers_page.dart`），并接入 code/name/phone/email 内联编辑与区域粘贴（`update_customers` 原子批量） | 审计页仍为自绘冻结列整页建行，是否迁移待下一批；§6 平台矩阵（真实 OS 按键焦点、进程内存、Win/Linux、DPI）仍开放 |
| F04「外部诊断输入完整流程尚未完成」 | `rust/src/api/diagnostics.rs` 已有 `prepare_external_diagnostic_text` / `prepare_external_diagnostic_file`；`lib/ui/pages/diagnostics/external_diagnostic_dialog.dart` 经服务 `prepareText` / `prepareFile` 接入文本与原生文件选择，`test/ui/external_diagnostic_test.dart` 已存在 | 两平台真实文件选择、路径/链接拒绝、TTL/单次消费与泄漏回归的执行证据 |
| 打印「未接预览、授权与 busy 界面流程」 | `lib/features/audit/ui/audit_print_actions.dart` 的 `printAuditPageFromView` 已接审计页按钮与 Ctrl+P（`lib/ui/pages/audit_page.dart`），`lib/api/desktop_print.dart` 为平台通道，`test/ui/audit_print_test.dart`、`test/desktop_print_test.dart` 已存在 | 仅覆盖审计当前页纯文本；两平台真打印、取消、Unicode/分页、驱动与退出证据；其他页面打印范围未定义 |
| I02「独立业务时区、货币仍未实现」 | 配置 v5 已有独立 `time_zone` / `currency`；`lib/ui/shell.dart` 视图菜单提供时区（系统/UTC）与币种（未指定/CNY/USD/EUR/GBP/JPY）选择，`lib/core/state/regional_settings_provider.dart` 与 `rust/tests/regional_preferences_test.rs` 已接 | 金额精度/舍入与 DST 业务语义仍待产品决策；系统区域/DST 平台事件实测；RTL 未实现 |

## 2026-11-06 Linux 与离线门禁增量（历史快照，用户导入与生成状态已被上方更正取代）

本次接线：导入弹窗/服务/关闭保护、时区币种菜单/启动/保存/导入回读、审计/诊断/备份时间显示及查询导出时区边界已写。新增 ARB 与回归源码待生成、编译和执行；严格源码门禁因 FRB/l10n 待生成退出 1。网格仍仅为隔离 POC，生产网格和平台验收开放。

最新实跑：Python 全量 88 项通过，包含桌面采集器九项 mock 回归。FRB 生成实际执行因缺少 Flutter 退出；当前生成缺口为 9 个函数 wrapper 与 2 个 API module，共 11 个独立缺口。导入已新增绑定身份版本的 prepare/run/cancel 句柄；配置 v5 已补独立 time_zone/currency 的 Rust 保存、导入与 API。前端接线、编译和平台验收继续开放。以下段落保留较早执行快照。

本轮补充（历史快照；导入接线状态已被 2026-11-08 更正取代）：真实 `app_user` JSONL 批量导入的 data/service 已接入模块及 `users.import_users_jsonl` API；新增 `rust/tests/user_import_test.rs` 检查成功用户与审计同事务、后行错误/重复/触发器 IGNORE 回滚、取消与权限拒绝审计。当时尚未编译、生成 FRB 或接入产品导入界面；**当前已有** `prepare_user_import` / `run_user_import` / `cancel_user_import` / `user_import_progress` 公开句柄与用户页导入对话框（进度 + 取消），FRB 已正常生成并通过本机门禁。`scripts/generate-frb.sh` 固定兼容工具版本并约束锁文件。

验签证据采集增加 `run_attempt`，校验器要求 commit/run/attempt 匹配和合法 UTC 时间顺序，拒绝超过当前时间五分钟的报告；候选 workflow 传入当前运行参数，并新增对应 Python 边界测试。本轮已修复采集器与测试不同步的问题，`python3 -B -m unittest discover -s scripts/tests -p 'test_*.py'` 全量 75 项通过，覆盖新增四项边界测试；真实 SignTool/Actions 未执行。

此前 71 项结果不覆盖新增发布绑定测试，已由上述 75 项实际执行结果替代。编辑工具仍偶发保存超时，新增功能必须回读并通过终端执行核实。网格生产接线、独立时区/货币、打印/DPI/退出及正式发布专项验收仍开放。

- `scripts/check_sources.py` 已检查公开 Rust API 模块和生成 Dart wrapper，
  新增四项回归，Python 离线测试共 67 项通过。严格源码检查目前失败：
  外部诊断 text/file 两函数、任务历史和网格偏好两模块仍缺 FRB 生成绑定。
- CI 将严格源码检查放在 Linux 本地化/FRB 正常生成之后；
  纯 Python job 保留回归测试。l10n 产物被 Git 忽略，不能在未生成的干净检出中
  将其不存在误判为提交缺失。正常 codegen 后的 Git 差异门禁仍保留。
- `verify.ps1 -Device linux -BuildRelease -Security` 已支持 Linux 构建、隔离集成和
  原生 Bash 安全扫描，Windows 才检查 Git Bash 路径。执行清单见
  `LINUX_DESKTOP_CHECKS.md`；PowerShell/真实桌面执行仍为 NOT_EXECUTED。
- 已确认 `rust/tests/audit_export_history_restart_test.rs` 落盘：
  通过独立 seed/recover/recover 子进程检查历史保留、中断时间幂等、部分 CSV
  不被误判为完成以及旧操作句柄不恢复。源码存在不代表该测试已执行。
- 网格 Rust 单元测试增加两个列表的宽度边界、冻结顺序、隐藏冻结、缺列/未知列和
  JSON 未知字段拒绝测试；仍待 Rust 工具链编译执行。
- 配置导入的顺序回归增加真实 `app_user` 完整行快照对比，
  断言成功/失败导入及 outbox 补写不修改用户，也不在产品库创建网格 fixture 表。
  这些 Rust 断言尚未运行。
- 本轮 CI YAML 解析、先生成后检查的步骤顺序断言和 Bash 语法检查通过；
  不代表 GitHub Actions 或 Rust/Flutter 测试已执行。
- 集成执行器新增每次独立的 `build/reports/integration-<device>-<id>/`，
  保留逐入口日志及 JSON 状态/时间/退出码汇总。后续未执行项为 NOT_RUN，
  数据目录清理失败仍判 FAIL；Linux CI 使用 always 上传已有报告。
  新增不依赖 Flutter 的 PowerShell 假命令回归，覆盖成功、非零退出、抛异常、
  环境/工作目录恢复、独立数据目录和日志。CI 接线已补，YAML 和上传条件断言通过，
  但本机缺 PowerShell，执行器及新增回归均未执行。

本机 PATH 未发现 Flutter/Dart/Rust/FRB/PowerShell；尝试连接官方 Rust 下载站
`static.rust-lang.org:443` 失败，尚不能在当前环境补齐工具链。
因此 FRB 正常生成、Rust/Flutter 编译测试和目标平台验收仍开放。
以上没有新增业务实体、任务续传或生产网格接线。

## 2026-11-05 后续源码增量（历史快照）

本轮主会话应用子 agent 的只读建议，实际落盘如下；各领域总项仍开放。

| 工作流 | 新增源码与测试 | 仍开放 |
|---|---|---|
| 外部诊断 | 独立 `selectExternalDiagnosticFile` Dart/Windows/Linux 通道；服务注入与文件预览按钮；六项 widget 测试源码覆盖选择/准备期间身份失效、异步失败、移除弹窗后 pending 生命周期、取消、单飞和确认；另有四项通道契约/错误脱敏测试源码 | 现有公开 Rust API 对应 FRB 正常生成、Dart/Rust/native 编译、测试与真实文件选择端到端执行 |
| 打印 | 当前审计页 Ctrl+P 复用按钮的完整预览/确认流程，按钮提示快捷键；两项键盘测试源码覆盖重复按键、忙碌与隐藏页 | 当前版本 Flutter 测试、Windows/Linux 真打印与取消/Unicode/分页/驱动/退出证据 |
| 任务历史 | 现有 SQLite 持久历史终态允许相同结果幂等重试、保留首次完成时间；拒绝冲突/已中断/忽略写入；worker 与 supervisor 对 BUSY/LOCKED 有限重试三次 | 新增真实 SQLite 回归源码未执行；临时锁释放/重试耗尽运行证据、真正进程重启；独立时区与货币仍未实现 |
| 发布 | 验签采集已接入候选 workflow；新增 `verify_signature_evidence.py` 在打包后核对可信报告的 commit、目标覆盖、状态、参数及当前文件哈希；候选上传要求采集和绑定校验成功，保留报告与阶段状态 | 不签名、不评估发布者允许名单；Windows/PowerShell/SignTool/Actions 未运行；真实证书、attestation、Defender 和正式分发未验收 |
| 网格 | 新增独立 `poc/grid_columns` 候选包：不可变列配置模型、与 Rust 相同的边界校验、PlutoGrid 8.1.0 实际列类型适配、14 项布局/工厂边界测试源码；上游标签 MIT 正文已读 | 候选自己的锁文件、发行归档/传递许可、format/analyze/test 均未完成；不接生产列表或 FRB；完整网格/持久化/编辑接线与平台验收开放 |
| 导入恢复 | 增加混合 outbox 的真实 SQLite 故障注入测试源码：change 已入库后首条 import SQL 失败，保留配置字节和完整队列，数据库重开后幂等补写并清理 | Rust 测试未运行；未新增领域业务或产品导入入口，fixture 与 outbox 不等于业务跨资源原子提交 |

实际执行：`python3 -B -m unittest discover -s scripts/tests -q` 共 63 项通过，
其中 16 项为验签采集及报告绑定的 mock/拒绝边界测试，不是真实 Authenticode 验证。
发布 YAML 语法及步骤 ID 唯一性检查通过，不代替 Actions 表达式与 PowerShell 执行。
`python3 -B scripts/check_sources.py` PASS，只覆盖资源/导入/依赖名。
新 Flutter/Rust 测试、format/analyze/clippy、FRB 生成与平台测试均未运行：
PATH 和有限常见安装位置未发现相关工具链，现有 `.dart_tool/package_config.json` 指向 Windows SDK。
生成区未手工修改，生产应用依赖与锁文件未变；独立 POC 声明精确候选版本但尚未解析，
根源码检查不覆盖该包。根 analyzer 排除该独立包，包内提供独立 analyzer 配置与运行命令。

独立验签采集入口（Windows，报告目录须已存在，输出文件须不存在）：

```powershell
python scripts/collect_signature_evidence.py --root <candidate-directory> --signtool <absolute-signtool.exe> --output <outside-candidate-report.json>
python scripts/verify_signature_evidence.py --root <candidate-directory> --report <trusted-report.json> --commit <full-commit-id> --run-id <run-id> --run-attempt <attempt>
```

该报告的 PASS 只表示被枚举文件的本次 SignTool 验证全部成功且采集期间哈希一致，
不代表通过所有发布门禁。离线核对依赖可信采集来源；JSON 本身未签名，
不能用自填 PASS 的报告证明 Authenticode、发布者身份或来源证明。
缺工具、未签名和警告继续阻断候选，OSV unknown 严格阻断保持不变。

## 2026-11-05 多 agent 复核与推进顺序

本轮后续实际落地：`verify_release_evidence.py --zip` 已从仅比对外摘要扩展为独立校验包内载荷、
证据清单与 SPDX 覆盖/哈希；先检查路径、重复/规范化冲突、文件目录冲突、普通文件类型及加密标记，
限制 10,000 项、单文件展开 1 GiB/总展开 4 GiB，再在私有临时目录流式暂存并清理。
新增篡改后重算 sidecar、危险条目和资源上限回归；Python 脚本回归 47 项通过，
`check_sources.py` PASS。仅关闭候选 ZIP 内部完整性脚本缺口，不关闭来源证明、签名或真实发布门禁。
详见 [OFFLINE_VALIDATION.md](OFFLINE_VALIDATION.md)。

源码复核另发现外部诊断公开 Rust API、Dart 包装和文本预览 UI 已有接线；当前仍缺对应 FRB
正常生成、文件选择 UI 与实际运行证据。原“公开 API/UI 未接”应按此更正，禁止重复实现或手补生成区。

本轮并行核对需求、实现和任务依赖，主会话复核当前台账与源码。以下为当前推进顺序，
不将历史条目的“未生成”“未构建”覆盖到已经确认的 Windows Release 基线。
审计页当前是 Fluent Row/分页列表，已有 Ctrl 多选、Shift 范围选择和 TSV 复制
（`lib/ui/pages/audit_page.dart`）；不能继续按旧 DataTable/单选快照重复开发。

| 顺序/工作流 | 当前缺口 | 独立交付范围 | 关闭条件 |
|---|---|---|---|
| 1 / 集成 | 第二批源码缺本轮生成、编译和运行证据 | 单一集成者负责 FRB/l10n、锁文件和完整门禁；先跑现有基线，再接新功能 | 固定工具链生成、Rust/Dart 门禁、真实 FRB 及目标平台结果分别留证 |
| 2A / 网格 T01、F02 | 固定列、列配置/用户隔离持久化已有；POC 的编辑/粘贴/分页/虚拟化已实跑；生产接线与候选锁定未定 | 核对候选组件发行包及传递许可后接网格，复用现有偏好与独立编辑 fixture；不重做已有行多选，不给只读审计增加编辑 | 真实按键焦点与键盘矩阵、进程内存、Win/Linux 与 DPI 矩阵分别通过，且 `pluto_grid` / `trina_grid` 用同一用例对比后锁定 |
| 2B / 外部诊断 F04、S03 | 核心、公开 Rust API、Dart 包装与文本 UI 已有；对应 FRB 生成与文件选择 UI 未闭环 | 先正常生成桥接并验证文本流程，再补独立诊断文件选择，复用单次快照 | 输入上限、无效编码、所有者/TTL/消费、泄漏与平台路径回归通过 |
| 2C / 打印 F01 | 原生适配、审计当前页按钮、完整预览、身份/权限复查及单飞/关闭守卫已有源码 | 核对正常生成与当前版本回归，补键盘命令接入；不重复实现已有预览 | 两平台编译、取消、Unicode/分页、驱动与退出场景留证 |
| 2D / 业务导入 S02、F03 | SQLite fixture 事务已有，真实业务/产品入口及跨存储一致性未闭环 | 先明确业务对象与提交点，再接暂存、校验、进度/取消和整批提交；保持配置审计补写与业务事务语义独立 | 真实 SQLite 失败注入、部分写入回滚、并发、重放/幂等；不以 fixture 关闭业务验收 |
| 2E / 发布 D01–D04、B02 | 证据脚本已有，attestation、签名、Defender 与正式发布未闭环 | 脚本/工作流独立推进；证书、官方渠道与远端 ruleset 单列外部条件 | 真实扫描、来源验证、签名与干净环境分发证据；unknown 扫描快照继续阻断 |
| 3 / 国际化与任务 | 独立时区/货币已实现（配置 v5 + 视图菜单）；金额精度/舍入与业务时区语义待产品决策；审计导出持久任务历史与启动中断恢复已接入并通过本机门禁 | 审计导出独立保存任务元数据，终态清理 30 天/1000 条，启动将 running 标记为 interrupted，不自动重放；不预建通用调度器 | DST/金额边界与系统区域平台事件实测、身份隔离与清理的两平台证据、真实进程重启证据（本机 restart 子进程测试已过，目标环境仍须取证） |
| 贯穿 / 平台与二开 | Linux 桌面、DPI/读屏、资源释放及非原作者接入证据 | 可并行准备验收；使用集成后的同一版本执行 | 机器/版本/步骤/实际结果完整，未执行项保持开放 |

并行写入边界：各工作流只维护所属业务源码与测试，FRB/l10n 生成区、锁文件和共享接线
由集成者统一处理；共享配置/API 修改需先交接，不能按目录不同就假定没有语义冲突。
企业登录/凭据、归档导入、安装器均按现有条件范围处理，不擅自升级为 v1 必选；
ZIP 可作为 Windows 发行形式，静默自动更新仍为非目标。

本轮实际执行 `python3 -B scripts/check_sources.py` 返回 PASS，仅证明该脚本覆盖的源码、
资源和依赖引用检查。本机 PATH 未找到 Flutter、Dart、Cargo 或 FRB codegen；
子 agent 的写入/工作区可见性不一致，开发派发未产生功能代码改动。
公开接口变更的正常生成、Rust/Flutter 编译及平台验收保持阻塞，不记为已完成。

## 2026-11-04 第二批推进（优先于下方旧快照）

| 对应项 | 实际落地范围 | 仍开放 |
|---|---|---|
| F04 / S03 外部诊断 | 独立文本筛查、输入及完整脱敏输出各1MiB上限；JSON外观不走配置解析；拒绝归档/无效UTF-8/控制字符；复用绑定姓名/角色的六项、300秒、单次消费快照 | 内部核心未接公开API/FRB/UI和诊断文件选择；Rust测试源码未执行；继承安全读取的路径竞态及脱敏规则边界 |
| T01 / S02 fixture | 独立SQLite表的文本/int32/日期/枚举校验、Create/Update、流式JSONL整批事务、限频进度及提交前协作取消；12项回归源码 | 不接产品startup/正式迁移，不写audit_log；未接网格、FRB和UI，不等于真实业务保存/导入；Rust未编译/测试 |
| F01 打印（历史快照） | Windows GDI/Uniscribe、Linux GTK/Pango/Cairo纯文本适配；Dart通道与五列/最多200记录/1MiB报告构建；7项Dart边界回归源码 | 后续源码已补界面按钮、完整预览、确认前身份/权限复查、busy/关闭守卫；当前仍待两平台编译与取消/Unicode/分页/驱动/退出专项验证 |
| 当前活动 | 六类实时活动明细，状态栏及任务页共用；活动存续与注册页面复查后定位，不提供通用取消或持久历史 | widget/provider回归未运行；活动范围资源待正常生成后接入；原生窗口和隐藏/模态/关闭交互待验证 |
| G02 本地化 | 中英文新增打印6键及currentActivitiesScope | 必须执行flutter gen-l10n；生成文件尚未更新。check_sources PASS仅核对其有限检查范围，不能证明生成一致 |

第二批没有新增依赖或手补生成物。源码、测试源码、公开接线和平台验收分别记账；
Windows既有构建验证仍有效，但不覆盖这批改动。

## 2026-11-04 第一批推进（优先于下方旧快照描述）

本批由六路实现与独立只读检查推进；外壳分工因子 agent 缺补丁工具未落地，由主 agent 接手实现。
以下“已有源码”均不表示本轮 Flutter/Windows 验收通过，本机无 Flutter/Cargo。

| 对应项 | 本批实际落地 | 仍开放 |
|---|---|---|
| F02 / I01 | 当前 Fluent `Row`/分页列表补齐横向同步、当前页单选/Ctrl多选/Shift范围选择、上下/Home/End/Esc、按钮/Ctrl+C安全TSV；查询/身份变化清选；总数/页码按显示区域格式化 | 固定列、列调整与用户隔离持久化、单元格/区域操作、基础编辑、批量操作和完整网格准入 |
| F03 / U03 | 用户与类型样例表单补错误摘要语义/定位滚动、Tab/Enter/Escape、隐藏/模态旧回调门禁；用户身份loading/error拒绝保存；草稿修订防止旧确认复用 | 业务选择器、真实业务保存与Rust校验；类型样例仍只在本地预览；实际键盘/下拉/读屏 |
| U01 | `lib/ui/tokens.dart` 集中表面/语义色、尺寸/字体；主题、公共组件与首页接入；首页角色本地化 | 其他页面令牌迁移、完整设计一致性/DPI验收 |
| U02 / 活动聚合 | 外壳批量检查后统一关闭，退出/关闭共用锁，确认后复查标签/活动页/守卫快照及busy；退出兜底全局任务；按kind保留页面实例，隐藏页禁用焦点/动画；状态栏纳入导出、配置导入、重试并可换行 | 新增生命周期回归源码未运行；原生退出、高DPI、读屏、内存释放需实测 |
| D03 | RustSec 使用本次独立缓存及同一快照，记录URL/revision/tree/干净状态并前后复查；发布证据纳入本次summary、报告及锁文件字节，严格校验commit/状态/哈希/扫描命令 | 真扫描工具/Windows/Git Bash/Actions实测；OSV在线全局快照仍unknown阻断；attestation与签名未实现 |
| T01 | 合成SQLite 10k/100k/1m的warm/重连查询实际运行，返回值与边界校验通过；PlutoGrid 8.1.0官方元数据/标签源码/许可初核已记录 | 未加入网格依赖，归档独立校验、传递许可、Flutter渲染、编辑fixture和平台矩阵仍开放 |
| V03 | `EXTENDING.md` 更新为当前UiPage/KeelShell接入；新增 `PUBLIC_API.md` 边界与升级迁移契约；集成测试使用隔离执行器 | 非原作者干净环境接入、兼容回归与升级实际验收 |

实际验证：42项Python回归通过，源码/资源/锁文件检查PASS，Shell语法通过；
新增Dart回归尚未运行。完整运行与环境副作用记录见 [OFFLINE_VALIDATION.md](OFFLINE_VALIDATION.md)。
下方早期条目中对 DataTable、已删除目录和“列选择尚无”等描述按本节更新解释；
没有本批证据覆盖的业务、性能、平台和发布门禁继续开放。

## §1 通用 Admin 功能范围

| 编号/需求 | 状态 | 已有源码与边界 | 剩余项 |
|---|---|---|---|
| F01 / §1.1 外壳与命令 | 待验证（真机）、源码已补 | 菜单、工具栏、标签、状态栏、Ctrl+K 页面搜索；侧栏 **模块 / 收藏（上限 50）/ 最近访问（上限 10）**三组与折叠态（Rust 导航偏好持久化）；**页面命令已注册到 `UiPage.commands`**，外壳按活动页渲染到命令栏与“工具”菜单（审计：刷新/导出/打印；往来单位：新建；登录保护：立即锁定；备份：立即备份/恢复所选/取消待恢复/刷新；诊断：刷新/导出诊断包；导入设置：选择文件/取消/重试；任务：刷新），可用性统一由 `isEnabledProvider: Provider<bool>` 控制（外壳 build 顶部直接 watch）；`test/ui/shell_nav_test.dart`、`shell_commands_test.dart`、`backup_page_test.dart`、`diagnostics_commands_test.dart`、`settings_import_commands_test.dart` 覆盖 | 导航保存失败重试与身份/写保护交互仍待真机验证；Ctrl+Tab、活动页/模态/关闭锁检查按 U02 行执行；**快捷键仍由页面自己绑定**（命令配置只做发现，不重复绑定以免双触发）；备份页键盘选择与命令的动作链（含二次确认）仅 widget 测试覆盖，真机焦点/读屏待验。页面入口搜索不等于跨业务数据搜索。 |
| F02 / §1.2 列表 | 部分待实现、需平台证据（生成/编译/测试已于 2026-11-08 本机关闭，见上方更正） | 审计页（只读）：服务端式分页/文本过滤/三列排序、单选与 Ctrl 多选/Shift 范围选择、键盘定位与五列 TSV 复制、日期筛选、start/none/end 冻结列与 Rust 用户隔离 CAS 列设置。**可编辑列表已有参考实现**：`customers` 页（分页/搜索/类型/状态筛选、行选择、表单编辑，见上方「往来单位参考闭环」） | 审计页保持只读是产品约束；跨单元格区域粘贴、内联编辑与行虚拟化仍只在隔离 POC 完成（行级复制/批量启停/删除已在示例列表实现），生产表整页建行（页上限 200），随 §6 生产网格决策处理；两平台键盘/剪贴板/DPI 实测仍开放。验证入口：`cargo test --manifest-path rust/Cargo.toml audit`；`flutter test test/audit_query_test.dart test/ui/audit_page_test.dart test/ui/customers_page_test.dart`；`pwsh -File scripts/integration-check.ps1 -Device windows`。 |
| F03 / §1.3 表单 | 部分实现、需平台证据 | 用户表单（`lib/features/users/`）：Unicode 校验、保存/取消、失败保留输入、错误聚焦/滚动、脏草稿确认；**业务表单已有参考实现**：`customers` 新建/编辑对话框（本地预检 + Rust 复核、重复编号保留对话框、只读角色禁用、失败保留输入）与删除二次确认；`form_samples` 覆盖文本/int32/精确 USD/日期时间/枚举与多错误摘要 | 用户表单的 Enter/Tab/Shift+Tab/Ctrl+S、防重与确认期间内容变化仍须真机实测；业务选择器（下拉联动另一实体）、业务批量保存/导入与长表单分区仍随具体业务定义；示例实体之外的字段与事务同样如此。 |
| F04 / §1.4 诊断中心 | 部分待实现、需平台证据（生成/编译/测试已本机关闭，见上方更正） | `lib/ui/pages/diagnostics_page.dart` 与 `diagnostics/` 三个弹窗、Rust events/diagnostic_pack：最近500条缓冲内按 ID/级别过滤，最多返回200条、ID复制、类别选择、一次性快照预览确认导出；历史文件检索为独立受限扫描入口；外部诊断文本与原生文件选择已经 `prepare_external_diagnostic_text/file` 接入弹窗 | 验证筛选/复制生命周期、快照所有者/TTL/失败重预览、两平台真实文件选择与路径/链接拒绝；通用后台任务查询仍未实现。不得把缓冲查询写成历史日志检索，也不得把外部诊断筛查写成完整业务导入。 |
| F05 / §1.5 权限 | 待验证 | `rust/src/domain/permissions.rs`（8 项权限，含新增 `customers.manage`）、`services/access.rs` 与用户 UI；角色矩阵有单元与集成断言（admin/operator/viewer × 全部权限，`customer_test` 覆盖 viewer 拒绝与 operator 放行） | 等待锁后复查身份、旧回调/快照/任务所有者回归与真机切换体验仍待实测；目前不是 SSO 或本机管理员安全隔离。 |

## §2 UI 与交互

| 编号/需求 | 状态 | 当前依据 | 剩余项/平台证据 |
|---|---|---|---|
| U01 / §2.1–2.2 视觉布局 | 待验证、部分待实现、需平台证据 | Flutter Theme、菜单/工具栏/导航/标签/状态栏已有；工具栏横向滚动，活动提示可换行 | 完整设计令牌尚待整理；验证主题贯穿所有页面/对话框、信息密度、窄窗口命令可访问，不以已有 Material 控件推断视觉验收通过。 |
| U02 / §2.3 关闭与退出 | 待验证、需平台证据 | `workspace_shell.dart`、`workspace_page.dart`、用户草稿与各 busy 守卫；AppLifecycleListener 接可取消退出；未改 native `SetQuitOnClose` | 执行 [退出清单](DESKTOP_EXIT_CHECKS.md)，覆盖普通叉号/Alt+F4、隐藏页草稿、批量关闭、并发确认/标签快照变化、导入/导出/备份 busy。强杀和不可取消退出无保障。 |
| U03 / §2.3 键盘与资源 | 部分验证、需平台证据 | `test/core/`、`test/features/` 有焦点、关闭守卫、复制、搜索、导出轮询等回归源码；2026-11-09 新增 Windows 真实窗口集成入口 `integration_test/interaction_memory_test.dart`：审计表 ↓/↑/End/Home/Esc 选择与复制按钮联动、Ctrl+K 浮层期间按键不穿透且 Esc 关闭后恢复、切页/关页后按键不误触；备份页 ↑/↓ 选择、Enter 弹恢复确认、Cancel 不登记、Esc 清选后 Enter 不再弹框。以可观察按钮可用性与行高亮断言，未用真实剪贴板 | 隐藏页禁用焦点/动画、关闭释放控制器/Provider/计时器/订阅仍须在目标桌面按 P02 循环执行；OS 读屏/多屏/焦点顺序未验；Ctrl+W 仅在外壳焦点子树内生效（工具条按钮点击后 primaryFocus 在外壳外）已实测记录，未改产品行为 |
| U04 / §2.4 DPI | 自动化覆盖已有，平台证据仍缺 | `test/ui/shell_dpi_test.dart` 实跑 5 项：1280×720 / 1366×768 / 1920×1080 × 100/125/150/200% 十二种组合、200% 文本缩放、640×360 最小逻辑窗口的页面搜索与打开页面、深浅主题；`test/ui/audit_page_test.dart` 增加 200% 文本缩放用例。本轮据此修复两处真实溢出（首页状态 pill 在 640×360 溢出 23px，审计页筛选区在 200% 文本下把表格压到 53px，改为高文本缩放下筛选区限高滚动、页脚摘要省略） | 仍需目标机实测：最大化/缩小/拖动/多屏迁移、长英文/德文与字体回退、高对比度、辅助技术（读屏）语义与焦点顺序、真实 DPI 缩放下的截图；自动化覆盖布局不溢出、关键命令可达，以及 2026-11-09 新增的网格语义树断言（5 项，见上方专节；不等于读屏验收）。 |

## §3 国际化

| 编号 | 状态 | 已有源码与边界 | 剩余项 |
|---|---|---|---|
| I01 | 待验证、需平台证据 | 中英 ARB、运行时切换、独立 en_US/en_GB/zh_CN/系统显示区域；审计/诊断/备份日期、分页数字、二进制文件大小与精确字节数已接入；**`test/l10n/arb_parity_test.dart` 固定两语言键集、消息占位符与模板元数据一致**；英文删除确认使用 ICU 复数（1 entry / N entries）；`shell_dpi_test`/`customers_page_test` 含 RTL 方向用例（布局与命令可达） | 语言切换保留区域、配置 v1–v5 迁移/导入、系统 locale 变化、时区/夏令时边界仍须实测；状态栏计数等 ARB 数字跟随界面语言（未逐项解耦）；RTL 只是“预留”验证，未做阿语翻译与完整镜像审查。 |
| I02 | 部分待实现、需平台证据、外部条件（生成/编译/测试已本机关闭，见上方更正） | 审计本地日历半开区间、独立 `formatLocale`（`en_US`/`en_GB`/`zh_CN`/跟随系统）；配置 v5 另有独立 `time_zone`（系统/UTC）与 `currency`（未指定/CNY/USD/EUR/GBP/JPY），`lib/ui/shell.dart` 视图菜单可选，保存/导入沿用写保护与审计 outbox；2026-11-09 新增 13 项自动化（`test/core/format_locale_system_test.dart`、`test/ui/regional_display_test.dart`、`test/ui/shell_regional_menu_test.dart`）：系统 locale 跟随/显式固定、视图菜单落盘、审计时间列区域与时区重排（本机偏移实算） | DST/系统 locale 事件、时区切换后显示与查询边界仍须在目标桌面实测（自动化只覆盖 TestPlatformDispatcher 广播与单一时区偏移）；金额精度/舍入与业务时区语义待产品决策；RTL 未实现。显示区域、时区、币种是三个独立设置，不得互相推断。验证入口：`flutter test test/core/regional_settings_test.dart test/core/format_locale_system_test.dart test/ui/regional_display_test.dart test/ui/shell_regional_menu_test.dart`；`cargo test --manifest-path rust/Cargo.toml regional_preferences_test`；再在目标桌面执行系统区域切换和 DST 场景并留记录。 |

## §4 安全、日志与诊断

| 编号/需求 | 状态 | 已有源码与边界 | 剩余项/证据 |
|---|---|---|---|
| S01 / §4.1、§4.4 配置文件导入 | 待验证、需平台证据 | `lib/api/desktop_files.dart` 与 Windows `flutter_window.cpp` COM / Linux `my_application.cc` GTK 已新增 native 选择；channel 只返回路径；Rust `prepare_external_config_file` 限普通文件/大小/编码/结构，再复用绑定身份的一次性快照 | 不是“文件选择未实现”：须编译并测试两平台对话框取消/销毁、Unicode/空格路径、权限/链接拒绝、返回时身份/活动页复查、源文件变化不替换快照。文件预检与打开之间竞态仍需评估，不能声明消除所有路径竞态。 |
| S02 / §4.1、§4.4 导入一致性 | 待验证、部分待实现 | `services/settings.rs`、`config/mod.rs` 与 `lib/features/settings_import/` 已实现文本/文件准备、一次性确认句柄、设置锁内复查、允许字段合并、原子替换、旧保存队列排空及导入后回读；`pending_settings_import_audit` 已纳入源码契约 | `flutter gen-l10n`、FRB、Rust/Flutter 测试和 Windows/Linux 文件选择器仍待运行。需实跑缓存 TTL/容量/单次消费、坏配置保护、并发保存/身份变化、回读失败只读重试；跨配置/SQLite 事务、通用批量业务导入的暂存/事务回滚、归档导入和 ZIP 边界仍未实现。验证入口：`cargo test --manifest-path rust/Cargo.toml settings_api_test`；`flutter test test/desktop_files_test.dart test/ui/shell_lifecycle_test.dart`；`pwsh -File scripts/integration-check.ps1 -Device windows`。JSON 筛查不能代替归档防护。 |
| S03 / §4.2 脱敏 | 部分验证、需平台证据 | `rust/src/diagnostics/redact.rs` 现覆盖密钥键值、Bearer、URL 账号密码、邮箱、用户目录、**其他绝对路径（Windows 盘符 / POSIX 多段）与电话号码**（带 `+`/括号/分隔符且最多 5 组，或 CN 手机号形态；排除日期、版本号、相对路径与 URL 路径）；12 项单元测试含混合行泄漏回归与超长数字串规模守卫。日志默认最小采集、recent_events 显式选择、预览快照与一次性确认仍在 | 客户/供应商/员工等业务名称无法靠规则可靠识别，按“无法可靠判别的内容默认不收集或提示用户检查”处理；仍需在真实诊断包上核对预览与导出文件一致、失败/过期提示，以及外部诊断文件完整导入（后者待实现） |
| S04 / §4.3 审计 | 待验证、部分待实现 | `services/settings.rs`、`config/mod.rs`、`data/audit.rs`：`settings.import` 独立 `pending_settings_import_audit`，成功事件与允许偏好同次 `config::save`；失败仅健康、可写、有容量时入队；与 `settings.change` 混合队列总200，满时先补写、仍满拒绝新变更/成功导入；v4 新字段 serde 默认空，外部两类 pending 不采纳；启动/后续保存按动作与事件 ID 幂等补写，核对完整记录检测 `RAISE(IGNORE)`/内容冲突，全部确认后才清队列。健康可写且有容量的失败导入可为持久失败审计规范化/迁移 JSON（raw bytes 可能变化），保证允许偏好语义不变、既有事件保留至确认入库；坏/未来/不可写配置或补写后仍满的队列不得强行覆盖或挤出事件，不保证所有失败原文件字节不变。 | 实跑原操作者/时间/结果、混合满队列、坏配置/无池/数据库失败、部分插入、清理保存失败、取消/重启重放与不重复；失败事件不保证全部可入队，提交后补写失败不撤销偏好。不是配置/SQLite 跨存储事务，仅单进程写者；旧程序降级不保证保留新增队列，恢复旧库可能丢已清队列的历史。恢复文件与 SQLite 也无共同事务。权限变更/批量删除等随对应业务补审计；本轮无新依赖。 |
| S05 / §4.1 凭据 | 部分实现、边界明确 | **应用级登录保护已实现**：`app_security` 表只存 Argon2id 加盐校验值，默认关闭；开启后启动停在登录页，口令正确才发布本地用户；开启/关闭/改口令需管理用户权限，已有口令须提供当前口令；失败登录写审计并固定延迟 200ms；开关不进入可导入配置（外部配置无法打开/关闭登录）。测试：`rust/tests/auth_test.rs`、`test/ui/login_page_test.dart`、`test/ui/security_page_test.dart`、`integration_test/auth_test.dart` | **未采用的仍是 OS 凭据存储**（Windows 凭据管理器 / Linux Secret Service）：当前校验值在 SQLite，能读取数据目录者可离线尝试或删库；无持久失败锁定、管理员重置流程、按用户口令、企业登录（SSO）；日志与配置未出现明文口令（有测试断言），但发布前仍须按 §7 复核。 |
| S06 / §4.4 运行与告警响应 | 需平台证据、外部条件 | 扫描脚本、只读 CI 权限和固定下载校验已有配置 | 验证普通用户运行、无多余监听/自启/安全软件改动；native/FFI/构建脚本的供应链复核与当前扫描结果待补。Defender/SmartScreen 告警隔离复核、撤回/轮换/通知流程须可执行且留记录，不能以“扫描未检出”承诺安全。 |

## §5 性能与资源生命周期

| 编号 | 状态 | 当前依据 | 剩余项/证据 |
|---|---|---|---|
| P01 审计 CSV | 待验证、部分待实现、需平台证据 | `rust/src/services/audit_export.rs`、`data/audit.rs`、`lib/features/audit/` 已实现固定快照、流式分批、100,000 行/64 MiB、权限/所有者、CSV 防护、进度/取消/清理、单飞轮询和关闭保护；`save_audit_export_copy`、Win COM/Linux GTK 选择器、Dart copy provider/面板入口及持久历史 API 也已有源码 | FRB/l10n、Rust/Flutter 测试和两平台执行仍待完成。须实测普通源文件/64 MiB、本地绝对 CSV 目标、同目录 hard link 发布、链接/重解析点拒绝、文件锁/权限/清理、TTL/身份/授权复查、取消竞争和原生对话框生命周期；祖先目录并发替换 TOCTOU 与另存审计无共同事务仍是边界。验证入口：`cargo test --test audit_export_test --manifest-path rust/Cargo.toml`、`cargo test --test audit_export_history_test --manifest-path rust/Cargo.toml`、`flutter test test/ui/tasks_page_test.dart test/ui/current_activities_test.dart`、`pwsh -File scripts/integration-check.ps1 -Device windows`。源码存在不表示 CSV 行为或平台门禁已通过。 |
| P02 生命周期与测量 | Windows 已取证、Linux/DPI 需平台证据 | 2026-11-09 Windows 真实窗口集成入口 `interaction_memory_test.dart`（含网格语义标签的最终树复跑）：同一进程 5 轮“打开审计→筛选→翻页→关闭→打开备份/诊断→关闭”，RSS 序列 584.1 → 600.9 → 623.3 → 624.4 → 636.1 → 631.5 MiB，首末增量 49.7 MB（47.4 MiB，maxRss 683.5 MiB），5 轮全部完成、无遗留 busy、末轮可重开并选行；隔离临时数据目录，debug 构建，阈值为只防失控的 300 MB | 隐藏页长任务、真实 Release 构建、CPU 与订阅/任务计数、Linux 与 DPI/读屏矩阵仍 NOT RUN；RSS 含 Flutter debug 引擎、trina 依赖与测试种子（120 往来单位/1 备份），不能当作生产内存基线。报告：`build/reports/integration-windows-13451c161d1641c9901e7d31f22c1422/summary.json` 与 `interaction_memory_test.log` |

## §6 数据网格 POC

| 编号 | 状态 | 当前依据 | 剩余项/证据 |
|---|---|---|---|
| T01 | 部分实现、需平台证据、外部条件（查询层基准、POC 交互门禁与候选同用例对比已完成，见上方 2026-11-08 / 2026-11-09 增量） | Rust 用户隔离/CAS 布局 API 与 Flutter `RustGridColumnLayoutStore` 已接通；生产审计表已实现 start/body/end 冻结列渲染与列设置持久化；两个隔离 POC（`poc/grid_columns` pluto_grid 8.1.0、`poc/grid_columns_trina` trina_grid 2.4.0）用同一套用例对比并实跑两轮：本机 **trina 62 通过 / 0 skip、pluto 54 通过 + 2 skip**，两包 analyze 0 项、format 无差异，覆盖范围复制 TSV、粘贴合法/非法、1M 行单页物化与虚拟化、翻页替换、只读拒绝、5 项缺陷探针与 7 项 FluentApp 宿主用例（含 pluto 无 Material 祖先时编辑失败）；`scripts/grid_poc.py` 查询基准已实跑 10k/100k/1M | 仍未关闭：真实 OS 焦点与键盘矩阵、进程内存/CPU 与生命周期稳定性、Windows/Linux 桌面与 DPI/读屏、锁定版本的完整 NOTICE 与 security-check、目标 Linux 冒烟。**已锁定 trina_grid 2.4.0**（ADR-012；缺陷 5 已修、原生校验钩子可用、Fluent 宿主无需 Material 壳；代价是 +52 生产传递包，缺陷 1/2/4 仍需同样绕行、缺陷 6/7 需按其固定绕法）。根 `pubspec.yaml` 已加入该依赖并重解锁文件；往来单位示例页已改用网格行选择/虚拟滚动/快捷键，并接入 code/name/phone/email 内联编辑与 Ctrl+V 区域粘贴（一次事务），另有语义树断言 5 项（区域标签/数据暴露/隐藏列不泄漏/语言切换，非读屏验收）；审计页仍为自绘冻结列表格。详见 `docs/GRID_POC.md` 2026-11-09 节与 `build/reports/grid-poc-trina-20261109.md`。查询层、1M 规模测试与 widget 级结果不能关闭桌面验收。 |

## §7 依赖、许可证与供应链

| 编号/需求 | 状态 | 当前依据 | 剩余项/证据 |
|---|---|---|---|
| D01 / §7.1–7.3、§7.5 | 待验证、外部条件 | MIT/NOTICE、deny配置、扫描脚本、Dependabot、Action SHA 固定已有；历史扫描对应旧锁定范围 | 完成 G01 后重跑 audit/deny/OSV/secret scanning，补全部运行/构建/原生/素材授权；品牌资源来源授权仍缺。复核实际发行包 Flutter NOTICES。网络公告库不可用返回3仍阻断发布；未知许可不自动通过。 |
| D02 / §7.4 标签保护 | 外部条件 | `release.yml` 只有 `push.tags: ["v*"]` 与名称检查；默认 `contents: read` | 远端 ruleset 配置并核验发布分支/标签保护、允许创建者/绕过权限及发布身份；不得把通配匹配写成“已受保护标签”。本轮未查询远端，保护状态未知。 |
| D03 / §7.4–7.5 发布证据 | 待验证、部分待实现 | `release_evidence.py` 已新增文件哈希、Cargo/Dart 组件 SPDX、锁文件哈希/工具链/commit 元数据；候选 workflow 组装 ZIP 与上传 artifact | 首次真实运行后检查清单完整性/有效性、未知许可证、构建元数据、随包 evidence 和报告留存范围；当前仅有生成源码，不能记 SBOM 交付通过。完整来源 attestation 生成/验证尚未实现；元数据不是来源证明。 |
| D04 / §7.4 签名与分发 | 待实现、需平台证据、外部条件 | 发布候选只上传 artifact，不执行正式发布或签名；ADR-011 已记录基线 | Authenticode 证书/密钥托管/时间戳方案与成本决策、签名流程、exe/dll/安装器签名验证、官方渠道/版本/commit/哈希比对和撤回流程待落实；PR/fork 无秘密、发布任务最小权限须核验。静默更新为 v1 非目标；未来签名更新清单/轮换撤销不记作当前已实现。 |

## §8 配置、升级、备份与交付

| 编号 | 状态 | 当前依据 | 剩余项/证据 |
|---|---|---|---|
| B01 数据库/配置/恢复 | 待验证、需平台证据 | `data/mod.rs` 初始化/顺序迁移/迁移前备份与最多三份清理、进程内打开锁；`backup.rs` 创建/登记/取消/启动恢复；`startup.rs` 首次实际恢复结论独立于就绪；配置v4兼容v1–v3 | 实跑并发打开、清理边界、旧库升级记录/约束核对、坏库/迁移失败/配置失败、重启恢复成功与失败/重试；Windows 文件原子替换、锁/权限/Unicode路径，Unix链接回归均待运行。进程内锁不提供跨进程协调，恢复成功不等于数据库就绪。 |
| B02 Windows 交付 | 待验证、需平台证据、部分待实现 | 工程、Release候选源码与 [Windows清单](WINDOWS_RELEASE_CHECKS.md) 已有；清单状态未执行，CHANGELOG 已存在 | 验证Release、干净普通用户首次启动、目录/运行时无开发机依赖、覆盖升级/卸载/重装不丢数据、Defender日期/引擎/对象哈希/结果，及签名证据。安装器尚未实现；v1 可选ZIP，先明确发行形式，选择安装器时再核许可/实现，不虚标安装器已完成或必选。 |
| B03 Linux 交付 | 待验证、部分待实现、需平台证据、外部条件 | `ci.yml` 保留 linux-rust，新增 Ubuntu 24.04 linux-desktop 源码：固定 SHA Flutter Action/全局 Flutter与FRB版本、显式 GTK3/构建/Mesa/Xvfb/DBus/字体依赖、pwsh 检查、锁文件约束、FRB/l10n 生成与差异门禁、Dart 门禁、Linux Release、Xvfb 下隔离真实桥接及结束后差异复查；GTK配置选择与审计CSV保存选择已有源码 | 桌面 job 尚未执行，先补齐锁文件/生成物，再留存 Flutter Linux 编译/真实FRB与目标环境基本测试证据；明确正式支持发行版/系统依赖/打包格式，验证桌面文件、图标、选择器、剪贴板、快捷键、字体。不以 CI 源码或 Rust 冒烟代替 Linux 桌面验收。 |

## §9 测试与验收、§10 阶段路线

| 编号/需求 | 状态 | 当前依据 | 剩余项/证据 |
|---|---|---|---|
| V01 / §9.1 真实 FRB | Windows 本机已关闭、Linux 需平台证据 | `integration_test/` 现为 **7 个 entry**（audit_page / auth / current_api / export_history_api / grid_store / interaction_memory / simple）；`scripts/integration-check.ps1 -Device windows` 于 2026-11-09 在含网格语义标签的最终代码上 **7/7 PASS**，报告 `build/reports/integration-windows-13451c161d1641c9901e7d31f22c1422/summary.json`（14:22–14:35 UTC，独立进程、owned 临时目录、真实加载 Rust 动态库；native 构建包含 `jni` FFI 插件）；接入批次首跑为 `...504db0d2...`。更早的 6/6（`...791dca6e...`）与 5/5（`...8662d97c...`）分别是当时 6 / 5 entry 的快照 | Linux 桌面 job 逐 entry 执行仍为 NOT_EXECUTED；集成条目覆盖启动、审计/登录/桥接/网格/最小窗口与桌面按键/RSS，但**未点按**备份恢复执行、诊断导出、导入设置命令，native 文件对话框/打印、跨进程重启恢复、DPI/读屏的端到端证据保持开放。CI 真实 runner 首跑结果须单独取得，不由本机结果推导。 |
| V02 / §9.2–9.3 POC与放行 | 待验证、部分待实现、需平台证据 | Rust SQLite测试、Flutter widget测试和错误/退出/导入/导出回归已有源码，部分POC功能仍缺 | 完成前述各行与§6；实跑启动/重启、多标签、列表/基础编辑、批量导入进度取消、故障诊断、脱敏、语言/格式、Windows干净Release、Linux桌面。保留关键迁移/备份恢复可重复结果，不能据测试文件数量宣称达标。 |
| V03 / §9.3 二开与兼容 | 待验证、部分待实现 | [EXTENDING](EXTENDING.md) 已有新增页面/命令/关闭守卫指南及审计列表、用户编辑样例 | 非原作者在干净环境按指南构建并新增列表/编辑页；明确公共API与升级迁移说明并做样例兼容回归，特别是诊断prepare/export、DiagnosticEventQuery、format_locale、导航和配置文件准备接口。 |
| V04 / §10 阶段结论 | 待验证、待实现 | 阶段0有历史样例结果，阶段1–3已有交叉实现，阶段4有候选脚本 | 当前不宣布任一新增阶段整体完成：阶段0补 CI 联网复跑的当前依赖/生成/门禁；阶段1补UI/生命周期证据；阶段2列配置/冻结列与两个 POC 的候选对比已有，但候选锁定与生产接线未定、平台矩阵未跑；阶段3补通用表单/业务导入导出/二开验收；阶段4补平台与发布独立门禁。 |
| V05 / 决策记录 | 待验证、外部条件 | [ADR-007](adr/007-logging-and-diagnostic-redaction.md)、[008](adr/008-internationalization-and-time-zones.md)、[009](adr/009-windows-first-and-linux-continuous-build.md)、[010](adr/010-dependency-license-governance.md)、[011](adr/011-release-signing-and-update-strategy.md) 已新增 | 记录本身已存在，无需再列“待编写”；其脱敏/国际化/平台构建/许可/签名基线所涉及实现与证据仍依本台账开放，不把ADR文档存在或设计选定当作运行验证完成。 |

## 条目级可复现验证命令

以下命令从仓库根目录执行，记录的是验证入口，不是本机已经通过的结果。命令成功也只关闭其覆盖范围；仍需按条目补齐真实桥接、平台和外部条件。

```bash
python3 -B scripts/check_sources.py
flutter gen-l10n
flutter_rust_bridge_codegen generate
cargo fmt --manifest-path rust/Cargo.toml --check
cargo test --manifest-path rust/Cargo.toml audit_export
cargo test --manifest-path rust/Cargo.toml settings_api_test
flutter test test/audit_query_test.dart test/core/regional_settings_test.dart
flutter test test/features/audit_export_history_provider_test.dart test/desktop_files_test.dart
pwsh -File scripts/integration-check.ps1 -Device windows
# Linux 需在具备 Flutter、GTK、Xvfb、DBus 和 pwsh 的目标环境执行：
pwsh -File scripts/integration-check.ps1 -Device linux
```

`check_sources.py` 只检查资源、导入和依赖引用；`gen-l10n`/FRB 只产生或更新生成物；Rust/Dart 命令只覆盖对应测试；集成命令才加载真实桌面动态库。任何命令未执行、工具缺失或只得到源码静态结果，都保持“待验证”。

## §11 风险关闭依据

§11 的风险表继续有效；本文不把缓解方案当成风险已关闭。双语言/桥接兼容对应 G02、V01/V03；网格与资源对应 T01、P02；Flutter桌面形态对应 U01–U04；许可/依赖/构建工具对应 G01、D01；诊断泄漏/恶意输入对应 S01–S04；发行伪造与供应链身份对应 D02–D04、B02。SQLite转服务端数据库是独立工程边界，不扩写为本轮待实现的万能数据库抽象。

## 活动与任务的独立关闭条件

| 范围 | 状态 | 关闭条件 |
|---|---|---|
| 当前活动聚合 | 已有源码，待验证 | 状态栏计数是 busy 类别数；实跑隐藏页/结束/失败移除，不推导百分比或取消能力 |
| 当前审计单任务视图 | 已有源码，待验证 | `tasks` 读取本人 Registry 列表，选回重查；所有者/权限/加载隔离、取消通信失败重查、隐藏页关闭与退出须实际验证 |
| 审计内存任务列表 | 已有源码，待生成与验证 | 复用最多6项 Registry 与终态5分钟 TTL，暴露仅本人列表、稳定排序和选回；身份隔离且单飞轮询 |
| 持久任务历史 | 待验证 | `audit_export_history` 独立保存任务元数据，已有留存、权限、清理和只读页面源码；审计操作事件不作为任务状态历史 | FRB 生成、Rust/Flutter 编译测试、历史分页/身份隔离和真实跨重启证据 |
| 跨重启恢复 | 部分实现、待验证 | 审计导出启动时将 durable `running` 标记为 `interrupted`，不自动重放，也不根据 CSV 文件推断完成 | 真实进程重启、清理和不重放场景证据；其他长任务仍未定义恢复语义 |

发布脚本局部补齐：分层哈希、离线校验与严格扫描模式的源码/fixture 测试仅覆盖脚本契约。正式 SPDX schema/完整语义验证、许可复核、工作流严格模式和 ZIP 外摘要接线已有源码；生成后脏树门禁的实际执行及真实扫描仍开放（D01/D03）。

复核补充（2026-11-02）：本次离线30项通过，check_sources --allow-pending-generation 返回0/PARTIAL，仍17项PENDING，详见 OFFLINE_VALIDATION.md。release workflow 已接严格扫描、本次摘要路径交接、证据生成、目录完整性、打包内容核对、ZIP外摘要及严格元数据校验，诊断 always 上传，候选要求扫描/证据/严格校验均成功。公告库版本提取仍未实现，工具退出0时严格扫描仍返回3，元数据亦保持 unavailable 并阻断。哈希绑定不证明外部报告真实性、扫描成功或候选绑定；Windows/Git Bash、PowerShell、Actions真实执行仍待验证。修复诊断包测试误用旧 audit::list 签名，改为 list_filtered；未编译。无Git元数据，无法证明历史改动范围。

本批集成复核（2026-11-02）：tasks/form_samples 已静态登记，复用原关闭/退出流程和孤立导出保护；
中英各31个 formSample 资源键，表单使用作用域稳定key；本轮修复了日期时间尾随空白接受问题，并补齐预览/时间显示调用所需键和9个 placeholder。具体修复及边界见 REQUIREMENTS「本批集成记录」。
审计面板/操作的用户重载旧身份隔离、未知阶段全局busy、表单隐藏旧回调保护已有源码及回归源码。
当前分别记录进程内任务列表选回、持久历史与跨重启恢复的独立状态；本地预览不关闭业务保存或Rust核心校验剩余项。
本机最终离线源码检查0/PARTIAL、17项PENDING；Python脚本30项通过，未运行Flutter/Dart/Cargo门禁。

本批集成：任务列表终态满300秒隐藏、查询不续期、运行任务不受终态TTL影响；原文件保留。
选择时有启动/请求/复制/非终态任务一律拒绝替换；迟到未知阶段仍保留句柄与关闭保护。
历史日志与内存事件分开，固定目录受限异步读取、完整行脱敏、返回前复查姓名/角色及权限；身份加载/错误隔离。
T01下一步阻断：目标版本发行包源码/API、LICENSE正文/哈希及传递依赖证据；生成/编译工具链；Windows和目标Linux完整矩阵实测。
可先设计用户稳定标识+列表ID隔离的列偏好和独立fixture契约，不能用全局导航偏好充当用户隔离，不能据候选类名编造网格API。
