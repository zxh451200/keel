# Keel — 产品需求与详细规范

最后更新：2026-11-08（§10.1 按当前源码复核，更正用户导入/打印/外部诊断/冻结列/真实 FRB 入口的过期描述；历史集成与扫描记录按各自快照理解，均不替代当前版本的生成、编译、测试和平台证据）。技术基线与开发规范见 [agents.md](../agents.md)；本文件是产品需求与详细规范的权威，2026-10-31 自 AGENTS.md 拆分而来，后续独立维护。

**读取规则：按需读取，不要求全读。** 任务涉及某领域时，先读对应章节再动手；不涉及的章节不读，也不凭记忆推断。AGENTS.md §8 有“任务类型 → 章节”对照表。

## 1. 通用 Admin 功能范围

### 1.1 桌面外壳

标题栏、菜单栏、命令工具栏、可折叠左侧导航、多工作区标签（新建/切换/关闭/关闭其他/关闭全部；固定按需）、内容区（列表/详情/编辑/分步）、状态栏（数据库、当前用户、版本、后台任务）。统一命令：刷新、保存、取消、搜索、导入、导出、打印；命令注册到清晰的界面层配置，不做动态插件系统。
2026-11-09：页面命令已注册到 `UiPage.commands`，由外壳渲染到命令栏与“工具”菜单（当前接入审计、往来单位、登录保护、备份、诊断、任务的刷新/导出/打印/新建/锁定）；快捷键仍由页面绑定，命令配置只做发现与统一入口。全局搜索、最近打开、收藏分阶段加入。

### 1.2 列表与表格

服务端式分页/排序/过滤（本地 SQLite 同样按分页处理）；固定列、列宽、列序、显隐；行选择、键盘导航、复制粘贴、空/加载状态；日期/数值/金额/状态格式化；基础行操作与批量操作。只读列表优先稳定交付，基础编辑作为第二阶段。高级能力（区域编辑、复杂树表、分组汇总、任意公式、超大规模剪贴板、复杂拖拽）须 POC 后才承诺。

### 1.3 表单与编辑

文本、数字、日期时间、枚举/下拉、选择器、校验错误、只读/禁用；保存/取消/删除区分，危险操作二次确认；编辑页未保存提示；UI 校验 + Rust 核心校验；长表单分区、滚动、错误摘要；Tab/Enter/Esc 行为一致。

### 1.4 日志、错误与诊断中心

UI 可查最近错误、警告、后台任务、诊断事件；错误分“用户提示”与“技术详情”，默认不显示堆栈、SQL 参数、敏感路径；日志含时间、级别、功能区域、关联 ID、错误码、脱敏摘要；诊断包导出需“预览脱敏结果 + 导出确认”；双向脱敏（导出识别隐藏；导入外部诊断/配置同样筛查）；不记录密码、令牌、完整连接串、密钥、完整业务记录；诊断包默认最小采集、可按类别选择、导出后说明位置与内容。

### 1.5 用户与权限

设计本地用户/角色/权限边界，但不包装成对本机管理员的安全隔离；高风险操作加权限检查与审计；未来接企业身份/服务端权限走明确适配，不把本地存储当 SSO；权限不能只靠隐藏菜单，敏感操作在 Rust 边界再校验。

## 2. UI 与交互规范

### 2.1 视觉定位

专业、精致、信息密度合理的桌面软件；石墨/深灰 + 浅色中性色，少量品牌强调色；主题贯穿列表、表单、菜单、弹窗、表格、状态栏；不做网页式大卡片 Dashboard。

### 2.2 主窗口布局

1. 顶部标题区（应用名/当前模块，遵循 Windows 窗口交互）。
2. 菜单栏：文件、编辑、视图、工具、窗口、帮助（按业务精简）。
3. 紧凑工具栏：常用命令，图标 + 文字，不只靠图标猜含义。
4. 左侧导航：模块树、收藏、最近访问，可折叠。
5. 工作区标签：多页面并存；关闭时释放该页状态与订阅。
6. 主内容区：标题/面包屑、筛选区、操作区、网格或表单。
7. 状态栏：数据库、任务、版本、当前用户。

### 2.3 交互

- 关键操作有快捷键且可在菜单/提示中发现；Enter、Esc、Tab、方向键、Delete、Ctrl+C/V 规则统一。
- 焦点清晰，可纯键盘操作；不只靠颜色表达状态。
- 危险/不可逆操作明确确认；普通无风险操作不加多余确认。
- 表格支持加载、空、错误、无权限、部分数据状态。
- 关闭工作区必须释放页面级 Provider、订阅、流、计时器、控制器、临时缓存、大数据引用。
- 多窗口不是 v1 必须项；先稳定单主窗口 + 多工作区。

### 2.4 屏幕与 DPI（POC 必测）

1280×720、1366×768、1920×1080；100% / 125% / 150% / 200% 缩放；最大化、缩小、拖动、多显示器迁移；长英文/德文文本与字体回退；高对比度、键盘焦点、可访问性语义。不把固定像素写死；窗口变窄时常见命令不能消失且不可访问。

2026-11-08：上述分辨率 × 缩放的十二种组合、200% 文本缩放、最小逻辑窗口（640×360）的页面搜索/打开页面
与深浅主题已由 `test/ui/shell_dpi_test.dart` 自动化覆盖（布局不溢出、关键命令可达），审计页另有 200%
文本缩放用例。据此修复首页状态 pill 与审计筛选区的真实溢出。**最大化/缩小/拖动/多屏迁移、
长德文与字体回退、高对比度、读屏语义与焦点顺序、真机 DPI 截图仍须手工验收**，自动化不替代平台证据。

## 3. 国际化

- v1 至少简体中文 + 英文；资源与业务代码分离；可见文字全走 ARB，禁止硬编码。
- 文案放 `lib/l10n/app_zh.arb` / `app_en.arb`（`flutter gen-l10n` 默认路径），`flutter gen-l10n` 生成；新增 key 两种语言同补。
- 日期、时间、数字、货币、百分比、排序用 locale-aware 格式化；不假定 `YYYY-MM-DD` 或逗号分组。
- 存储存规范化数据；时间点与本地日历日期区分。
- 金额含币种语义；不用浮点处理精确金额（整数最小单位或明确 decimal）。
- 动态文案、复数、占位符、校验错误、任务提示都要可翻译。
- 国家、语言、时区、货币是独立设置；语言切换不要求重启（除非系统能力限制）；RTL 布局预留。

## 4. 安全、日志与诊断

### 4.1 基线

UI 与 Rust 两端验证，Rust 是业务数据安全边界；SQL 参数化，禁止拼 shell 命令或路径；导入/导出/备份/恢复校验路径与权限；临时与导出文件有明确位置与清理策略；凭据用 OS 凭据存储；默认不开远程调试端口、匿名本地服务或多余网络监听；依赖升级前查安全公告与许可证变更。

**2026-11-09 登录保护（应用级口令门禁）**：新增可选的“登录后才能进入”开关，
默认关闭；开启时启动停在登录页，口令通过后发布本地用户。口令只保存 **Argon2id 加盐校验值**
（`app_security` 表），不保存明文、可逆密文或提示；口令策略 8–128 字符、不含控制字符、
不能是单一字符重复；开启/关闭/修改口令都需要管理用户权限，已有口令时须提供当前口令；
失败登录写审计并固定延迟 200ms（仅进程内，无持久锁定）。开关**不进入可导入配置**，
外部配置导入不能打开或关闭登录，避免把人锁在门外。

边界：这是离开工位时挡住随手打开的门禁，**不是 OS 凭据存储集成，也不是对本机管理员的隔离**——
能读到用户数据目录的人可以离线尝试口令或直接删库。未做：Windows 凭据管理器 / Linux Secret Service
接入、持久失败锁定与管理员重置流程、按用户口令（当前是一个应用级口令）。

### 4.2 脱敏

统一规则至少识别：用户名、主机用户名、用户目录、项目绝对路径、客户/供应商/员工名称、电话、邮箱、连接串、Token、密码、访问密钥、文件内容摘要、其他业务敏感字段。导出前显示将包含的文件、字段类别与脱敏效果；无法可靠判别的内容默认不收集或提示用户检查；不得宣称“绝不会遗漏”。

### 4.3 审计

登录/用户切换、权限变更、导入、批量删除、恢复、配置变更记录时间、操作者、动作、对象、结果、关联 ID。审计不替代数据库权限与备份，也不承诺本机防篡改。

### 4.4 恶意代码、供应链与运行时安全

目标是降低感染与篡改风险，不承诺“绝不会中毒”；Rust 内存安全不等于所有依赖、构建脚本、原生插件和业务逻辑安全。

开发与依赖：

- 只从 crates.io / pub.dev 或官方发布渠道取依赖；Git/路径/本地二进制/自定义 registry 要说明原因、锁 commit、审查。
- 不只凭包名和下载量判断；核对维护者/组织、源码与发行包对应、版本变更、许可证、维护状态、已知漏洞、是否含下载/执行、安装脚本、原生插件、多余权限。
- Cargo build script、过程宏、部分构建插件会在构建期执行代码；Flutter 插件可能带原生代码/构建步骤。不要对来源不明项目直接 `cargo build`、跑测试或代码生成；先查清单、锁文件、构建脚本与原生部分；不可信代码只在隔离、无机密、无生产凭据环境分析。
- 提交锁文件与工具链版本；正式发布用锁定依赖，不追 latest，不用浮动 Git 分支。
- 新增 native plugin、FFI、build script、proc-macro、下载器、自更新器或动态加载能力必须额外安全审查；v1 不支持任意第三方动态插件/脚本执行/远程代码加载。
- 禁止从构建期的不固定 URL 下载并执行脚本/二进制；需下载时固定版本、校验来源与 SHA-256。

本机运行：

- 以当前普通用户权限运行，不要求管理员；仅安装/系统集成由独立步骤提权。
- 不关闭 Defender、SmartScreen、防火墙；不要求用户为 Keel 加全盘/整项目排除项。
- 默认无后台常驻服务、开机自启、网络监听、进程注入、修改安全软件设置；确需时由用户显式启用并说明用途。
- 不执行从数据库、导入文件、配置、日志、远端响应读出的命令/脚本；数据永远按数据处理；禁止 shell 字符串拼接执行外部命令。
- 导入按不可信输入：校验真实格式（非只看扩展名）、大小、编码、字段数、记录数；ZIP 限制展开总大小、文件数、目录深度，防路径穿越、符号链接逃逸、压缩炸弹；写文件前校验规范化后的目标路径，不覆盖任意系统路径。
- 临时文件放用户数据目录专用位置，文件名不可预测、最小权限、不用即清；导入失败不得部分覆盖正式数据，用事务或暂存区保证可回滚。
- 网络最小化：v1 不需要的遥测、远程调试、匿名本地服务一律不开；未来联网/更新必须有明确域名、TLS 校验、超时与错误处理，不把服务端内容当可执行代码。
- 诊断包、崩溃日志、导出文件仍可能含未识别敏感信息；上传/分享前展示预览并让用户确认。

告警响应：

- 依赖扫描、Defender、SmartScreen 或发行包扫描告警时暂停发布；不通过关闭防护、加排除项或让用户点“仍要运行”绕过。
- 保存告警名称、检测对象、文件 SHA-256、依赖版本、流水线、时间；隔离环境复核来源与误报；必要时撤回发行物、吊销/轮换凭据、发布修复版并通知用户。
- 防病毒未检出不代表安全；签名只证发布者身份与签名后完整性，不证明无恶意行为。

## 5. 性能与资源生命周期

- 分页、增量查询、必要的聚合；UI 只保留当前视窗与合理缓冲；不把百万行一次传到 Dart 再前端过滤。
- 大批量操作在 Rust 后台执行，批处理 + 事务，进度事件限频（不逐条发事件）。
- 导入导出流式处理，不在内存复制多份全量数据。
- 图片/文档预览用有上限的缓存，工作区关闭释放引用。
- UI isolate 不做大型同步解析/排序/数据库操作；CPU 密集用阻塞任务池或专门线程。
- 可取消任务定义取消语义；关闭页面只取消该页任务；已关闭页面不得继续持订阅与大对象。
- 泄漏测试：循环“打开列表→切筛选→开详情→加载较多记录→关标签→重开”，记录进程内存与任务/订阅数量，确认不无限增长。
- 性能结论必须写明机器、构建模式、数据规模、列数、行高、过滤条件、冷热缓存、版本；禁止无证据的“百万行流畅”承诺。

## 6. 数据网格 POC 与准入门槛

**2026-11-09 已锁定 `trina_grid 2.4.0`（MIT）**：两候选用同一套 POC 用例对比两轮
（trina 62 通过 / 0 skip，pluto 54 通过 + 2 skip；pluto 的惰性分页销毁缺陷在 trina 已修，
trina 另有快捷键覆盖与取页失败静默两项已用测试固定的绕法；Fluent 宿主同仪中 pluto 在无
Material 祖先的页面编辑失败、trina 自补透明 Material）。锁定依据与证据见
`docs/GRID_POC.md` 2026-11-09 节、`build/reports/grid-poc-trina-20261109.md` 与 ADR-012。
生产依赖已加入 `trina_grid: 2.4.0`；首个生产页面（往来单位示例）已用其行选择/虚拟滚动/
快捷键替换手写表格，`code/name/phone/email` 支持单元格内联编辑与 Ctrl+V 区域粘贴（整段一次
事务提交），kind/status/备注仍走既有对话框。**锁定不等于平台验收通过**：真实 OS 焦点与窗口、
进程内存/CPU、DPI/读屏、Linux 冒烟与 1 万/10 万/100 万端到端仍按本节与
`docs/IMPLEMENTATION_STATUS.md` 的未跑项处理。必测：

| 场景 | 验收要求 |
|---|---|
| 只读列表 | 排序、固定列、列宽、空/加载/错误状态 |
| 数据量 | 1 万 / 10 万 / 100 万条本地查询与分页；UI 只加载当前页与必要缓冲 |
| 虚拟化 | 滚动不渲染所有行；观察内存、CPU、响应 |
| 键盘 | Tab/Shift+Tab、方向键、Enter、Esc、Home/End、快捷键一致 |
| 剪贴板 | 复制单元格/行/规定范围；粘贴校验类型与边界；多行复制不卡 UI |
| 编辑 | 基础文本、数字、日期/枚举；校验失败有可理解反馈 |
| 筛选分页 | 参数经 Rust 服务层；不把整表复制到 UI 再筛 |
| 列设置 | 显隐、宽度、顺序可保存恢复 |
| 生命周期 | 反复开关大量行工作区后内存稳定 |
| 许可 | 锁定版本的直接/传递依赖与维护状态通过检查 |
| Linux | 核心交互在目标 Linux 冒烟通过 |

不通过时顺序：查 API 与是否误用全量模式 → 收缩 v1 到只读+基础编辑+复制+列管理+分页 → 同生态换组件 → 重新比较 UI 技术路线 → 商业价值明确且范围受控时才做有限适配层；不从零重写整个 DataGrid。

## 7. 依赖、许可证与供应链

### 7.1 许可政策

Keel 自身以 MIT 发布（见 §7.5），第三方依赖各按原许可执行。优先 MIT、Apache-2.0、BSD-2/3-Clause；不引入需商业授权的 UI 控件；GPL/AGPL、商业双许可、附加限制、字体/图标/素材授权不明确的依赖不自动通过，须书面审查；传递依赖、原生库、字体、图标、示例素材、构建工具都纳入；发行物附第三方许可清单与必需 NOTICE；版本或许可变更时重审。

### 7.2 初核清单（以锁定版本 LICENSE 为准，不构成法律意见）

2026-11-05：新增隔离候选包 `poc/grid_columns`，仅该包声明精确版本
`pluto_grid: 8.1.0`，用于验证列配置与候选组件 API 的适配；未接入生产应用。
已读取上游 8.1.0 标签的 LICENSE 正文（MIT，Copyright (c) [2020] [PlutoGrid]）。

2026-11-06：该隔离 POC 为中英文列设置页面增加 SDK `flutter_localizations` 与 `intl: 0.20.3`；用途为 ARB 本地化及日期/数字格式，复用根应用已选依赖种类。

2026-11-08：POC 已在包内解析独立 `pubspec.lock`（pluto_grid 8.1.0；新增传递依赖
`rxdart 0.28.0`，Apache-2.0，已读包内 LICENSE 正文），并实跑 `flutter gen-l10n`、
`flutter analyze`（0 项）、`flutter test`（48 通过 + 1 有理由 skip）、`dart format`（无差异）。
`trina_grid 2.4.0` 仅完成只读核对（MIT；归档 SHA-256 `cda88c3a…a83`；
会额外引入 `pdf ^3.11.3` 与 `shadcn_ui >=0.55 <0.58`），**未加入 POC 锁文件、矩阵 NOT RUN**。
根锁文件及其扫描仍不覆盖该候选包；候选准入、发行归档独立校验与平台验收仍未完成，
不改变生产依赖或准入结论。逐条结果见 `docs/GRID_POC.md`。

2026-11-09：新增隔离对比包 `poc/grid_columns_trina`（`trina_grid: 2.4.0`），同用例实跑
55 项全过；官方归档独立下载核 SHA-256 与元数据一致，LICENSE 正文 MIT；相对 pluto 锁
新增 58 个传递包（pdf 3.13.1 / shadcn_ui 0.57.4 树），逐包 LICENSE 扫描全部
MIT / BSD-3-Clause / Apache-2.0。该 POC 包本身仍未接入生产应用，根锁当时未动（生产锁定见本节末
2026-11-09 网格锁定段）；完整 NOTICE 核对、
security-check 与平台验收在正式引入时做。对比结论与 trina 新发现（快捷键覆盖陷阱、
取页失败静默）见 `docs/GRID_POC.md` 2026-11-09 节。

2026-11-09 宿主对比批次：两个隔离 POC 各加 dev 依赖 `fluent_ui: 4.17.0`（与根锁同版本）
和同一份 7 项 FluentApp 宿主用例；用途仅为验证生产 Fluent 外壳内的渲染、真实按键焦点、
对话框覆盖与编辑挂载，不进入两个 POC 的运行时代码。两锁重解后 URL 全为 pub.dev
（trina 91 包、pluto 35 包；SDK 下限 dart >=3.13.0 / flutter >=3.47.0），新增
`material_ui 1.10.0`、`cupertino_ui 1.1.6`、`recase 4.1.0`（BSD-3-Clause）、
`math_expressions 3.2.0`、`scroll_pos 0.5.0`（MIT），pluto 锁另加 `petitparser 7.1.0`（MIT），
均读包内 LICENSE 正文；这些包已在根锁中作为生产依赖，根 NOTICE 不变。结果：
trina 62 通过 / 0 skip，pluto 54 通过 + 2 skip（新增“Fluent 页内无 Material 祖先时编辑”
探针在 pluto 侧失败、trina 侧通过）。生产依赖、根锁与准入结论均未改变。

2026-11-09 网格锁定：生产 `pubspec.yaml` 加入 `trina_grid: 2.4.0`（MIT，包内正文
Copyright (c) [2020] [TrinaGrid]；归档 SHA-256 `cda88c3a…f463a83`），根锁由 pub.dev 重解为
110 项（102 hosted + 7 Flutter SDK + 1 本地 path），全部 URL 为 pub.dev。新增 52 个传递包，
逐包读 LICENSE 正文：MIT 28、BSD-3-Clause 66、Apache-2.0 8（含 pdf 3.13.1、barcode 2.2.9、
rxdart 0.28.0、universal_image 1.0.12 等），其余为 SDK/path；无 GPL/AGPL 或未知许可。
首个生产页面（往来单位）改用网格行选择与虚拟滚动，并接入 code/name/phone/email 内联编辑与
区域粘贴（新增原子批量更新 API，整批事务）；kind/status/备注仍走对话框。
完整 NOTICE 计数与安全扫描随本批更新，发布仍以
联网 CI 的 audit/deny/OSV 为准。

Flutter/Dart BSD-3-Clause（引擎与包另有清单）；flutter_rust_bridge MIT；flutter_riverpod MIT；pluto_grid MIT；fluent_ui BSD-3-Clause（社区实现，维护集中度需关注，可替换）；intl / flutter_localizations BSD-3-Clause；file_selector BSD-3-Clause；SQLx MIT OR Apache-2.0；Tokio MIT；Serde/serde_json MIT OR Apache-2.0；tracing 系列 MIT；thiserror/anyhow MIT OR Apache-2.0；chrono MIT OR Apache-2.0；uuid Apache-2.0 OR MIT；csv MIT OR Unlicense；zip MIT；regex MIT OR Apache-2.0；dirs MIT OR Apache-2.0。
`argon2 0.5.3`（登录口令校验）MIT OR Apache-2.0，含 `password-hash`、`blake2`（MIT OR Apache-2.0）、`base64ct`（Apache-2.0 OR MIT）、`rand_core`/`getrandom`（MIT OR Apache-2.0）；均来自 crates.io，正文随包分发。

2026-11-08 依赖升级：`sqlx` 0.8.6 → 0.9.0（`query*()` 的 SQL 参数改为 `SqlSafeStr`，静态语句改为
`&'static str` 常量，白名单拼出的 ORDER BY 与测试内固定 DDL 显式 `AssertSqlSafe` 并注明依据；
`cargo update` 重新解析锁文件，tokio 等直接依赖版本未变）；`flutter_riverpod` 2.6.1 → 3.5.0
（StateProvider/StateNotifierProvider 等改经 `flutter_riverpod/legacy.dart` 导入，`valueOrNull`
→ `.value`，`Ref` 去泛型，审计导出 Notifier 的 `ref.onDispose` 不再读 `state` 而改用普通字段镜像）。
升级批次门禁：`cargo fmt`/`clippy -D warnings`/`cargo test`（89 单测 + 全部集成测试）、
`flutter analyze` 0 项、`flutter test` 105 项、`integration-check.ps1 -Device windows` 全部 entry PASS；
`check_sources.py` PASS；`security-check.py` 中 deny-licenses/bans/sources、osv-scanner、gitleaks、
hygiene、dart-deps 均 PASS（新依赖许可均在白名单内）；cargo-audit 公告库本机拉取失败、
`deny-advisories` 因脚本传入 `--disable-fetch` 与 cargo-deny 0.20.2 不兼容而 UNSURE、
`rust-licenses` 工具状态识别为 UNKNOWN——三项均为与本轮升级无关的既有环境/工具版本问题，
发布门禁以 CI 联网判定为准。

以下为 2026-11-01 按**当前锁定版本**的核对记录（口径：读依赖包内 LICENSE 正文，不看元数据字段；逐条正文见 [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES)）：`flutter_rust_bridge` 2.13.0 MIT（Rust crate 发行包不含正文，按同仓库 Dart 包正文与上游声明判定）；`tokio` 1.54.1 MIT；`allo-isolate` 0.1.27 Apache-2.0 单许可（用 `license-file` 而非 SPDX 字段）；`cupertino_icons` 1.0.9 MIT；`flutter_lints` 6.0.0 与 `lints` 6.1.0 BSD-3-Clause；`plugin_platform_interface` 2.1.8 BSD-3-Clause；`integration_test` / `flutter_test` / `flutter_driver` / `sky_engine`（Flutter SDK）BSD-3-Clause；`rust_builder/cargokit` 为 vendored 源码，自带 LICENSE（Copyright 2022 Matej Knopp + MIT 正文），不得删除；`ffi` / `ffigen` 是 rust_builder 的 dev 依赖，未进入根 `pubspec.lock`，不随发行物，仍待实际启用时核；`tempfile` 未引入（代码清空前快照里的 dev 依赖）。

`cargo deny check`（`rust/deny.toml`）与 `cargo audit` 已可运行；本机到 RustSec 公告库的网络不通时以离线缓存降级，发布门禁要求 CI 联网判定。
2026-11-08 修复：security_check.py 的 deny-advisories 改为按 cargo-deny 版本探测 `--disable-fetch`/`--offline`
（仅 RustSec 快照 verified 时钉定检查），rust-licenses 版本探测兼容 CARGO_HOME 指向非工具目录，
security-check.sh 在缺 python3 的 Windows 开发机回退 python（以 `python3 -c ""` 实测判定，商店占位
stub 不算可用）；Python 工具回归 89 项全过（含测试夹具 Windows 化）。网络恢复后本机端到端实跑
PASS(exit 0)：9 项检查全 PASS，deny-advisories 与 audit 钉定同一 RustSec revision；网络受限时该脚本
按设计诚实降级为 INCOMPLETE(exit 3)。

当前源码已声明 `flutter_localizations`、`intl`（跟随 Flutter SDK）、`flutter_riverpod ^3.4.3`（锁 3.5.0）；
Rust 已声明 `serde`/`serde_json`、`sqlx 0.9`（SQLite / Tokio / migrate / macros）、
`tracing`/`tracing-appender`/`tracing-subscriber`，分别用于设置、数据库与文件日志。
已有 Tokio 直接依赖额外启用 `sync` feature，用于串行数据库初始化/恢复重试；
不新增异步 runtime、不升级版本、不新增第三方依赖。
2026-11-04 当前锁文件存在，但最新源码门禁因 ARB/FRB 生成声明未同步而退出 1；锁定版本 LICENSE 正文及传递依赖的完整复核仍须实际记录，不能沿用历史 PASS 或阶段 0 的扫描结果放行。
首次 Windows 依赖解析后须补齐锁文件、NOTICE 与本节的版本核验记录；`file_selector`、`pluto_grid`、
`fluent_ui` 仍是计划/候选，未引入。本轮只补现有界面交互及验证入口，未新增第三方依赖。

### 7.3 自动化检查

- Rust：`cargo fmt --check`、`cargo clippy`、`cargo test`；`cargo-deny` 查 license/advisory/bans/sources；`cargo audit` 查 RustSec。统一入口 `bash scripts/security-check.sh`（报告写入 `build/reports/`；退出码 0 通过 / 1 违规或缺工具 / 3 无违规但公告库取不到，发布不放行）。
- Dart：`analysis_options.yaml` 引入 `flutter_lints` 官方推荐规则；`dart format --set-exit-if-changed`、`flutter analyze`、`flutter test`。
- 桥接：生成后检查工作区无非预期差异，生成步骤可复现。
- 发布流水线产出依赖清单与许可证报告；高风险/不明许可证人工复核，不自动放行。

### 7.4 发布阻断条件

- 每次合并/定期：`cargo audit`、`cargo deny`、OSV-Scanner（扫 `Cargo.lock` 与 `pubspec.lock`，作为第二数据源）；例外必须写公告编号、影响分析、负责人、复查日期，不允许无说明长期忽略；secret scanning；`dart pub outdated` 只用于发现更新机会，升级单独提交并测试。
  现状（2026-11-01）：以上由 `.github/workflows/ci.yml` 在每个 PR 与 push main 上执行；本机实测同一条命令链——
  cargo-deny 四项判绿、`cargo audit` 在线通过（离线时 `security-check.sh` 返回 3，CI 判失败不放行）、
  OSV-Scanner 2.7.0 解析 `rust/Cargo.lock`（83 包）与 `pubspec.lock`（42 包）无告警、gitleaks 扫历史无泄漏。
- 未审核的 Git 依赖、path override、子模块、直接下载二进制建单独清单；发行构建不得默默使用开发机本地覆盖。
- 工具本身也是供应链：记录 Rust、Flutter/Dart、codegen、打包器、安装器、CI Action 版本；CI Action 尽量固定到完整 commit SHA 并定期复核。
  现状（2026-11-01）：`ci.yml` 引用的 3 个 Action 已固定到完整 commit SHA（actions/checkout v7.0.1、subosito/flutter-action v2.23.0、actions/upload-artifact v7.0.2），
  未使用需要 EULA 的 gitleaks Action，改为下载 gitleaks 8.30.1 官方二进制并校验 SHA-256；Flutter 3.47.8、FRB codegen 2.13.0、
  OSV-Scanner 2.7.0 版本写在 workflow 的 `env`，Rust 由 `rust-toolchain.toml` 固定；`dependabot.yml` 负责提出 SHA 与依赖升级 PR。
- 发布包只由受控 CI 的受保护分支/标签生成；runner 短生命周期、最小权限；普通 PR 不拿发布凭据/签名私钥/生产密钥；fork/外部贡献在无机密隔离作业构建；发布任务与测试任务分开，仅受保护标签可触发签名与发布；签名私钥不进源码、日志、普通产物。
- 发行构建记录 commit、工具链、锁文件、工作流、产物哈希；有条件下生成 SBOM（SPDX 或 CycloneDX）与来源证明/attestation；验证 attestation 要核对仓库、工作流、commit、受保护发布身份。
- 分发：官方渠道 + 版本 + commit + SHA-256 + SBOM + 许可证清单；Windows 规划 Authenticode 签名（证书与时间戳成本单列决策），覆盖 `.exe`、`.dll`、安装器，发布后验证签名与时间戳；用户可用 `signtool verify /pa /v` 与官方哈希比对；不引导用户从网盘/重打包站/聊天附件取包，不因 SmartScreen 提示让用户关 Defender 或忽略未知发布者。
- 自动更新：v1 不实现静默更新；未来更新清单必须由发布密钥签名，客户端先验签名、版本、目标平台、SHA-256 再安装；校验失败/回滚异常/来源不符即拒绝，不得“提示后仍可强制安装”；更新器不执行远程脚本、不从固定域名以外下 DLL、不自动提权；设计密钥轮换/泄露撤销/停发流程，失败保留可恢复版本与数据备份。
- 签名、哈希、SBOM、扫描是不同层次证据，不能宣称“已签名/已扫描所以绝不可能中毒”。

### 7.5 许可证文件清单（发行必需）

| 文件 | 归属 | 现状 | 要求 |
|---|---|---|---|
| `LICENSE` | Keel 自身出站许可 | 已定：MIT（2026-10-31） | 保留版权与许可声明；更换许可主体时同步本文件与 §7.1 |
| `THIRD_PARTY_NOTICES` | 运行时依赖的版权与 NOTICE | 已建（2026-11-01 按正文核对，无 `.md` 后缀） | 覆盖直接与传递运行时依赖，保留原文声明；随依赖变化同步更新 |
| Flutter `NOTICES` | 引擎、框架与 SDK 包 | 已验证：Windows 构建产物含 `data/flutter_assets/NOTICES.Z`（gzip，解压约 1.3 MB） | 随 Windows/Linux 发行包发布 |
| `rust_builder/cargokit/LICENSE` | vendored 源码 | 已随 FRB 2.13.0 模板恢复 | 该源码保留时其 LICENSE 不得删除，声明已并入 `THIRD_PARTY_NOTICES` |
| `assets/` 图片资源 | 品牌占位图 | 已于 2026-11-04 移除（无运行时引用，Windows 图标由 `windows/runner/resources/app_icon.ico` 提供） | 重新引入图片时恢复 `pubspec.yaml` 声明并补来源/授权 |
| 字体文件 | 未来引入 | 暂无 | 每个字体单独附许可；OFL 字体保留版权行与保留字体名条款 |
| `rust/Cargo.lock`、`pubspec.lock` | 依赖版本 | 已生成并入库（2026-11-01） | 发行构建只用锁定版本 |
| SBOM（CycloneDX 或 SPDX） | 构建产物 | 已有发布候选工作流与 SPDX 文件/组件清单生成源码，实际产物及完整性尚未验证（见 §10.1） | 发布流水线生成并随包保留；清单生成不替代许可证正文复核与来源证明 |
| `cargo-deny` / OSV / `dart pub deps` / gitleaks 报告 | 审计产物 | 已可产出：`scripts/security-check.sh` 写 `build/reports/`，CI 以 `security-reports` artifact 保留 30 天 | 发布前留存；例外必须带编号与到期复查日期 |

- 开发/构建期依赖（`tempfile`、`ffi`、`ffigen`、`flutter_lints` 等）不随发行物，但仍纳入许可审查与自动扫描。
- `publish_to: none` 只表示不发布到 pub.dev，不豁免许可证与 NOTICE 义务。

## 8. 配置、升级、备份与交付

- 安装目录只放程序和只读资源；配置、数据库、日志、缓存分放系统应用数据目录；数据目录与程序版本分离，升级不覆盖用户数据；路径支持空格、Unicode、非 ASCII、不同用户名。
- 数据库升级：启动读 schema 版本；按序迁移并记录；高风险迁移先备份；失败给摘要、诊断 ID、恢复指引；不自动丢弃未知列/用户数据；准备旧版本数据样本，升级前后核对记录数、关键约束与字段。
- Windows：`.exe` + 引擎 DLL + `data` 目录 + 必要运行时；v1 可选目录式 ZIP 或安装包；安装器（Inno Setup、WiX 等）先核许可、维护与打包方式。发布检查：Release 构建；干净环境安装运行；无开发机路径依赖；首次启动建数据目录并初始化；升级/卸载/重装不误删用户数据；Defender 扫描并记录日期/引擎版本/结果；签名与 SHA-256 验证；提供来源、版本、commit、哈希、SBOM、许可证，并确认 `LICENSE`、`THIRD_PARTY_NOTICES`、Flutter `NOTICES` 随包发布。
- Linux：CI 至少编译 + 基本测试；正式支持发行版范围在首个可发布版本明确；选打包格式前评估系统依赖、桌面文件、图标、文件选择、剪贴板、快捷键、字体差异；不因“能编译”宣称全发行版支持。
  当前源码（2026-11-02）：`ci.yml` 新增 Ubuntu 24.04 `linux-desktop`，保留 `linux-rust`。
  桌面 job 复用固定 SHA Flutter Action 与全局 Flutter/FRB 版本，显式安装 GTK3、构建工具、
  Mesa、Xvfb/xauth、DBus 与字体，检查 runner 自带 pwsh；执行 pub enforce-lockfile、
  Cargo locked 获取、FRB/l10n 生成、生成物/锁文件差异门禁（含未跟踪文件）、Dart 门禁、
  Linux Release 构建和 Xvfb/DBus 下现有隔离桥接脚本 `-Device linux`，结束后复查差异。
  仅源码已补，未执行 CI/构建/测试；锁文件与生成物尚待同步，系统交互与正式支持范围仍待验收。
- v1 不做静默自动更新；签名、Defender 扫描、SBOM 按 §7.4 执行。

## 9. 测试与验收

### 9.1 合并门槛

Rust fmt/clippy/单测；Dart format/analyze/widget 测试；迁移测试与关键 API 测试；桥接可生成、类型对齐、错误映射；cargo audit/deny/OSV + 许可证检查；secret scanning、SBOM/依赖清单、产物哈希与来源记录；生成后无非预期差异。门槛只聚焦安全、数据正确性、构建、许可、升级兼容，不为所有 UI 改动设审批流。

### 9.2 POC 业务用例

启动/关闭/重启；多标签创建/切换/关闭；示例列表页（审计日志）只读查询/分页/排序/筛选/复制；基础编辑在独立参考实体（`customer` 往来单位，二开示例）上完成创建/编辑/分页/筛选与 Rust 校验，审计日志保持只读；批量导入显示进度、可取消、资源回收；制造数据库错误，UI 显示安全提示且日志中心可查；导出诊断包并确认无密码/令牌/客户名/私人路径；中英切换与日期/数字/金额格式；开启登录保护后重启停在登录页、错误/正确口令、锁定后重新登录；Windows Release 在干净环境运行；Linux 构建冒烟。

### 9.3 放行条件

网格满足 §6 必测；桥接无卡死、内存失控、难定位的生命周期问题；关键工作区循环开关资源释放符合预期；迁移/备份/恢复有可重复测试；许可与传递依赖无未解决阻断项，高危告警有已验证处置；发行物来自官方渠道、哈希可比对、启用签名时验证成功；不可信 PR 无法读发布/签名凭据；`LICENSE`、`THIRD_PARTY_NOTICES`、Flutter `NOTICES` 齐全且随包发布；非原作者能按 README 在干净环境构建并完成一个新列表页和编辑页。

## 10. 阶段路线

| 阶段 | 交付 | 完成标准 |
|---|---|---|
| 0 环境与冻结 | 官方 Flutter Windows 项目 + Rust crate；集成 FRB 跑最小字符串/结构体/异步样例；固定工具链、锁文件、生成步骤；输出许可证清单与漏洞扫描；配置依赖锁定、来源审查、secret scanning、隔离 CI | 干净 Windows 按文档构建运行；生成可复现；安全扫描可运行并出报告 |
| 1 桌面外壳 | 菜单、工具栏、侧边导航、标签工作区、状态栏；主题与中英文；统一错误提示、诊断中心基础页；工作区关闭资源释放 | 可切模块、多标签开关、切主题/语言；无资源持续累积 |
| 2 数据库与网格 POC | SQLx + SQLite 初始化/迁移/备份/恢复；示例列表页（审计日志）查询/分页/排序/筛选；`scripts/grid_poc.py` SQLite 查询基准；`docs/GRID_POC.md` 验收矩阵与 `docs/GRID_POC_REPORT_TEMPLATE.md` 结果模板；PlutoGrid 虚拟化/键盘/剪贴板/列设置/基础编辑；1 万/10 万/100 万测试 | 网格通过验收或明确换组件；不以未验证网格为正式基础 |
| 3 通用组件与二开 | 表单校验、统一命令、选择器、导入导出、确认对话框；模块样例与新增页面指南；日志脱敏、诊断导出、许可证报告 | 新开发者照文档加模块，无需了解全部内部细节 |
| 4 发布与兼容 | Windows Release、安装/升级/卸载测试；Linux 构建与目标环境验证；旧库迁移回归、性能、依赖安全/许可复核；恶意软件扫描、签名/哈希/SBOM/来源记录、撤回流程 | 发布清单齐全、限制明确、无未处理阻断、产物可验证、可安全升级 |

### 10.1 当前源码进度与待办（2026-11-08 复核）

下表记录源码覆盖范围，**源码已写 ≠ 生成、编译、测试或平台验收完成**。
2026-11-08 基线：本机补齐 Flutter 3.47.8 / Dart 3.13.7 / rustc 1.99.1 / FRB codegen 2.13.0 / pwsh 7.6.9 后，
FRB 与 `flutter gen-l10n` 正常生成，`python -B scripts/check_sources.py` 严格模式 PASS，
Rust fmt/clippy/test 全绿、`flutter analyze` 0 项、`flutter test` 105 项通过、
`integration-check.ps1 -Device windows` 5/5 entry PASS、Windows Debug/Release 构建成功。
下方 2026-11-02/11-04 的"待生成/未编译/未接 UI"描述属于当时快照，已被
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) 的「2026-11-08 台账复核更正」逐条取代；
具体功能测试、DPI/读屏矩阵、Linux 桌面、依赖许可、安全扫描与正式发布仍须各自证据，后续改动也须重新验证。

本日多 agent 推进已补齐当前只读审计页的横向滚动、当前页多选/键盘/安全TSV复制和区域数字格式；
用户/类型样例表单的错误定位、身份与旧回调门禁；外壳批量关闭、退出全局busy复查、隐藏页隔离和活动聚合；
公共Fluent令牌与首页角色本地化；RustSec快照观察和发布扫描报告/锁文件字节校验；
当前UI二开指南及公共API迁移契约。合成SQLite三个规模的查询基准已实际运行。
这些是有限实现推进，不关闭完整网格、业务导入/打印/保存、跨功能持久任务、外部诊断导入或发布门禁。
该轮 Flutter/Cargo 不可用、源码检查因生成项缺失退出 1 的记录属于 2026-11-02 快照，已被 2026-11-08 本机门禁取代。
第二批新增的外部诊断文本完整脱敏/一次性快照核心、独立编辑/JSONL 事务导入 fixture、
Windows/Linux 原生纯文本打印与手写 Dart 适配、六类当前活动明细与页面定位，当前接线状态为：
外部诊断文本与原生文件选择已经公开 API 接入诊断中心弹窗；打印已接审计当前页预览/确认、授权复查、
busy 与 Ctrl+P；用户 JSONL 导入已接用户页对话框并具备进度/取消句柄。
独立编辑 fixture（`rust/src/services/grid_fixture.rs`、`lib/features/grid/state/grid_fixture_editor.dart`）
仍未接公开 API 与产品页面，网格编辑/粘贴验收须在隔离 POC 中完成，不修改只读审计日志。
新增打印及活动范围 ARB 已正常生成；这些接线不关闭对应平台专项与完整需求。
逐项边界及未覆盖项见 [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) 的2026-11-04批次，
执行证据见 [OFFLINE_VALIDATION.md](OFFLINE_VALIDATION.md)；下方2026-11-02表格和集成段落保留为历史快照。
按需求章节列出的未实现项、待验证项、平台证据和外部条件见
[完整剩余项台账](IMPLEMENTATION_STATUS.md)；本轮增加了 Python/脚本离线回归，记录见 OFFLINE_VALIDATION.md；没有新增 Rust/Flutter 构建或平台通过结论。

| 需求 | 已有源码 | 尚未完成 |
|---|---|---|
| 诊断 ID 查询 | 输入完整 ID 与最低级别组合，搜索/Enter 提交、Ctrl+F 定位、重置、F5 保留已提交条件；Rust 缓冲内先筛选后限量；UI/Rust 双端校验，查询变化移除旧结果和复制状态 | 新查询 DTO 的 FRB 生成、Rust/Flutter 测试与 Windows 键盘实测；仅最近事件缓冲，不含历史文件检索或跨业务搜索 |
| 状态栏活动提示 | 聚合审计 CSV 导出、配置导入、备份操作/确认、诊断包准备/导出、数据库重试和设置保存的现有活动状态；活动数量、中英悬停说明、liveRegion 语义；隐藏页操作仍显示，空闲隐藏；宽度不足换行并随内容增高 | 本地化生成与 widget 测试实际运行；Windows 高 DPI、辅助技术与窄窗口验收；审计已有专用进度/取消，通用后台任务视图、历史与跨功能任务协议仍未实现 |
| 国际化展示 | 中英资源、运行时语言切换；独立显示区域菜单（en_US/en_GB/zh_CN/跟随系统），审计/诊断/备份日期、审计分页数字及备份大小使用区域格式；当前配置格式 v5 保存/导入/审计并兼容 v1–v4（v1–v3 迁移为默认区域设置，v4 保留既有字段）；字节及二进制单位模板进 ARB，支持至 TiB；悬停提示精确字节数 | 生成/迁移/保存/导入与界面测试已于 2026-11-08 本机通过；独立时区（系统/UTC）与币种设置已实现并接入视图菜单；更多地区、金额/百分比随对应业务接入；系统区域/DST 平台事件与 RTL 验证仍开放 |
| 备份操作生命周期 | 创建/登记/取消与确认同步防重，确认后复查身份权限；恢复标记采用临时文件同步写入后原子替换，拒绝已有标记符号链接；恢复临时数据库使用唯一临时路径，不跟随预置符号链接；busy 保护隐藏标签关闭及可取消退出；失败重读实际状态；Rust 取消授权与请求/成功审计，登记/取消进程内串行 | Windows 真实测试；文件与 SQLite 无共同事务，审计失败时文件可能已变更；符号链接回归当前仅有 Unix 测试；不提供跨进程协调 |
| 桌面外壳与命令 | 菜单、导航折叠、多标签、状态栏、主题/语言；模块/收藏/最近访问分组，星标增删、最近10项去重排序、收藏及折叠状态持久化，失败重试；Ctrl+K/窗口菜单页面快速搜索，名称/kind过滤与键盘选择；页面刷新共用工具栏/工具菜单/F5；用户工作区保存/取消共用工具栏/工具菜单，Ctrl+S 复用 Form 提交；命令执行复查活动标签实例、模态路由与关闭锁；焦点隔离与状态释放测试 | 其他页面命令、业务搜索/导入/导出/打印随实际功能接入；跨业务数据搜索；导航持久化、快速搜索及键盘真实运行；完整设计令牌、DPI/可访问性实测 |
| 启动与错误反馈 | 数据库失败摘要/诊断 ID/单飞重试；成功后重载查询；Rust 串行初始化，必要准备成功才发布池；独立启动恢复结果 API 与全局提示，保留首次实际恢复结论跨初始化失败/重试；失败只展示错误码/诊断 ID；确认提示不清除恢复记录；设置串行保存、失败重试、原配置保护；配置变更与待写审计同文件提交，数据库就绪后幂等补写 | Windows 真实恢复/故障重试、配置原子替换及并发补写验证 |
| SQLite 与只读列表 | 初始化/迁移/迁移前备份、分页/过滤/排序/重试；进程内并发打开串行化；迁移前备份清理只保留匹配的最新文件且不删除目录/其他文件；临时 DataTable 横纵滚动、当前页单行选择、上下/Home/End 导航、Esc 清选、Ctrl+C/按钮复制五列 TSV；查询结果更新清除选择 | 数据库并发/升级回归与性能数据的真实运行；迁移失败/文件权限和 Windows 文件锁行为；基础选择/复制的 Windows 实测；网格组件 POC、虚拟化、固定列、列设置、多选/单元格/区域复制粘贴、完整网格键盘、基础编辑、1 万/10 万/100 万验证 |
| 用户与表单 | 本地角色/权限，创建与切换用户；弹窗/工作区复用 Form，Unicode 校验、提交锁/失败重试；脏草稿关闭确认，批量关闭拒绝时保留全部页；AppLifecycleListener 处理框架收到的可取消平台退出请求，复用 canExit（用户弹窗）+ canClose（含隐藏工作区）；共享锁防重入，确认不提前销毁页面，工作区标签快照变化取消退出；busy/confirming 拒绝关闭，阻止同草稿重复确认 | 类型表单本地交互样例已登记（int32、精确 USD 金额、日期/本机日期时间、枚举、分区与多错误摘要），待生成/编译/测试；业务选择器与业务保存/核心校验待接入；普通窗口叉号/Alt+F4 的 Windows 真机验收（见 DESKTOP_EXIT_CHECKS.md）；真实键盘/DPI 验证 |
| 长任务与业务文件 | 审计筛选 CSV 已有 Rust 后台分批流式导出、100,000 行/64 MiB 上限、独立权限、进度/协作取消、所有者检查、CSV 转义/公式防护；Flutter 单飞轮询、通信失败仅重查原任务、关闭等待终态；completed 任务已有异步另存副本 API、Win COM/Linux GTK 保存选择器及 Dart auditCopy provider/面板入口，选择/复制全程 busy；诊断包预览/确认导出；配置文本/原生文件选择后复用一次性预览/确认，排空旧保存队列、回读偏好并保护关闭/退出；审计导出已有独立持久历史表、启动时 running→interrupted 恢复、终态清理和只读历史页源码 | 生成/编译/本机测试已于 2026-11-08 关闭；CSV 发布/另存/取消/清理、文件身份核对与原生对话框生命周期仍需两平台真实证据，祖先目录恶意并发替换边界仍在；用户 JSONL 批量导入已接产品对话框（进度/取消/整批事务），但跨配置与 SQLite 事务、归档导入、跨功能通用任务视图仍未实现 |
| 诊断与安全 | 日志/事件脱敏，级别过滤；诊断包默认仅采集运行环境，可显式选最近事件；完整脱敏快照预览后以单次句柄导出，权限与所有者在 Rust 检查，失败须重新预览，busy 保护关闭/退出；外部配置在设置锁内重新筛查，只合并允许偏好并保留本机队列，限普通文件/大小且拒绝预置符号链接；5 分钟/6 项一次性预览绑定身份，准备/确认检查 `settings.import`；导入成功事件与偏好同次保存，失败有条件入队，独立 `pending_settings_import_audit` 与变更队列混合总200、启动幂等补写并检测 `RAISE(IGNORE)`；交互/退出及 SQLite 审计测试源码已同步 | 桥接生成、文件选择到预览/确认、快照导出、持久队列重放与退出守卫真实运行；跨配置/SQLite 事务、文件预检与打开之间竞态、外部诊断导入、脱敏/泄漏回归；旧程序降级不保证保留新增队列；既有新增依赖锁定、LICENSE 正文/传递依赖/NOTICE 复核、品牌资源授权记录仍待完成 |
| 二开交付 | 审计列表与真实用户编辑样例，命令/关闭守卫是普通静态配置；新增页面指南见 EXTENDING.md | 新开发者照文档构建/扩展示例验收；公共 API/升级说明与兼容测试 |
| 真实 FRB 测试 | `scripts/integration-check.ps1` 逐 entry 使用独立进程与带 ownership marker 的临时目录；`integration_test/` 现有 5 个 entry（audit_page / current_api / export_history_api / grid_store / simple），2026-11-08 `-Device windows` 实跑 5/5 PASS；Linux `linux-desktop` CI 源码已接入 Xvfb/DBus 下 `-Device linux` | Linux 桌面 job 未实测；CI 真实 runner 首跑须单独取证；不等于原生文件选择/打印、审计 CSV 另存、跨进程重启恢复及性能/泄漏已获端到端证据 |
| 二开与决策记录补充 | ADR-007～011 已新增文档，分别记录脱敏、国际化/时区、Windows/Linux、依赖许可、签名/更新基线及缺口 | 文档存在不等于对应实现或验收完成；其中的平台构建、脱敏、安全供应链和签名结论仍待验证或外部条件落实 |
| 发布 | Windows/Linux 工程、CI 与依赖扫描配置；`.github/workflows/release.yml` 仅由 `v*` 标签触发 Windows 发布候选，`scripts/release_evidence.py` 已有 Cargo/Dart 组件及文件 SPDX、SHA-256、构建元数据生成源码；候选源码已接严格扫描、本次摘要路径交接、证据生成/目录校验、ZIP 内容核对及外摘要验证、严格元数据门禁；ZIP 包含证据目录与现有 CHANGELOG，诊断 always 上传，候选仅在扫描/证据/严格校验均成功时上传；公告库版本提取未实现，unknown/unavailable 仍阻断，安全报告作为 artifact 留存；已有 `docs/WINDOWS_RELEASE_CHECKS.md` 验收入口 | 首次真实 CI/候选产物验证、完整构建测试、Linux 桌面构建与目标环境冒烟、Release/安装/升级/卸载验证、签名、attestation、Defender 记录、正式发布与撤回流程；标签保护须另在远端仓库 ruleset 配置并核验，`v*` 名称检查不构成保护 |

退出守卫接入无新依赖，未修改 native `SetQuitOnClose`；强杀或不可取消退出不保障。
上述退出行为仅按生产源码记录，尚未执行测试或 Windows 手工验收。

启动恢复结果使用独立 `StartupRestoreStatus`，未改变 `AppStatus` 字段。Rust 仅缓存首次实际恢复
尝试（成功或失败），无待恢复项不会覆盖旧结论；记录发生在打开/迁移数据库前，因此恢复成功
不等于数据库已就绪。UI 监听数据库重试的开始和结束，失败重试也重读恢复结论，提示可在本次
运行确认隐藏。公开结果不含备份名、路径、原始错误；失败的错误码/关联 ID 与诊断事件一致。
诊断导出已删除旧的直接采集导出入口；二开调用方须使用 `prepare_diagnostic_pack(request)` →
预览 `content` → `export_prepared_diagnostic_pack(preview_id)`，并重新生成桥接。
本轮无新依赖；新增 API、本地化与测试仍须 Windows 生成、编译和实际运行验证。

显示区域由“视图 → 显示区域”独立控制，当前限定 en_US、en_GB、zh_CN 或跟随系统；
它不修改界面语言，不改变存储时间、币种或本机时区。跟随系统读取平台 locale，
中文系统映射 zh_CN，en_GB 使用英国格式，其他系统区域回退 en_US；
运行中接收系统 locale 变化时刷新显示，不写配置或新增审计。
当前接入范围为审计/诊断/备份的日期、审计分页数字、备份大小及精确字节提示；
状态栏计数与其他 ARB 数字占位符仍沿用界面语言，不宣称所有数字都已解耦。
日期模式与数字符号使用 intl 自带本地数据，无网络请求；无新依赖。
Rust Settings DTO 新增 `format_locale: Option<String>`（Dart `formatLocale`），严格白名单校验，
保存其他设置时必须保留此字段，null 表示明确恢复跟随系统；旧调用方须同步构造参数并重新生成 FRB。
配置 v1–v3 导入通过校验后按旧版语义把显示区域恢复为跟随系统；v4 导入使用新字段，缺失时也跟随系统。
所有版本显式提供的区域字段均须符合白名单和类型约束；非法值或错误类型会被拒绝，
本地损坏配置保留原文件并禁止覆盖，不通过迁移静默修复。
新区域与语言/主题共用保存队列、失败重试、导入门禁和两份快照回读保护，坏配置启动后仅临时显示。
回归源码包括 `test/core/regional_settings_test.dart`、`test/core/regional_formatters_test.dart`、配置导入 widget 测试，
以及 Rust 配置/设置审计/API/导入筛查/区域偏好测试；2026-11-08 已本机编译运行通过。
更多地区与 RTL 仍未完成；独立时区/币种已在配置 v5 实现（见下方 v5 说明），不再列为未实现。

配置 v5 在 v4 基础上新增两个独立字段，与语言/主题/显示区域互不推断：
`time_zone` 为 `null`（跟随本机时区）或 `"UTC"`（`rust/src/config/mod.rs` 的 `SUPPORTED_TIME_ZONES`）；
`currency` 为 `null`（未指定）或 `CNY`/`USD`/`EUR`/`GBP`/`JPY`（`SUPPORTED_CURRENCIES`）。
白名单外的值或错误类型被拒绝，不静默回退。v1–v4 读取时在内存迁移为两个字段均 `null`，下次保存写 v5；
导入沿用同一白名单与写保护，外部配置中的待写审计队列不采纳。两字段与其余偏好共用配置锁、
原子替换、`settings.change` 审计 outbox 与失败重试；币种只是显示偏好，不改变金额存储的整数最小单位，
也不引入汇率换算。视图菜单提供选择入口，审计/诊断/备份的时间显示按所选时区呈现，存储仍为 UTC epoch 毫秒。
金额精度/舍入规则、更多时区集合与 DST 输入歧义处理仍待产品决策，未实现前不得宣称支持业务排程或跨币种结算。

配置审计源码采用 v4 JSON：语言/主题/显示区域与待写事件一同保存，事件只含 ID、原始 UTC 时间、
操作者和变更字段名，不收集设置原值/新值、路径或完整配置。数据库补写使用
`settings.change` / `application`，按事件 ID 去重，全部成功后才清队列；
补写失败保留队列并输出固定安全告警，不把已落盘设置误报为保存失败。
`pending_settings_audit` 与 `pending_settings_import_audit` 混合总计最多 200 条、文件最多 1 MiB；
满队列且数据库可用先补写，仍满则拒绝新偏好变更或成功导入。
启动在必要准备成功并发布池后补写，与设置保存共用进程内锁，不提供多进程文件并发控制。
v1–v3 读取时在内存升级，显示区域迁移为跟随系统，下次保存写 v4；
新增导入队列仍使用 v4，serde 缺失默认空，已有 v4 配置可继续读取；外部配置中的两类 pending 不采纳。
旧程序降级不保证保留新增队列；更早的程序不能直接使用 v4，不得手删队列或更改版本号来降级。
恢复旧数据库可能回退已经补写并清除的历史审计，本地队列不是独立的永久审计日志。
原子替换的 Windows 行为与断电持久性仍需实测；不宣称具备跨文件事务或本机防篡改能力。

配置导入的直接字节、文件和预览确认路径共用持久结果审计，动作/对象为
`settings.import` / `application`，结果为 `ok` 或 `failed:稳定错误码`，使用非空关联 ID；
记录操作者，不记录源路径、输入内容或底层数据库错误。文件读取前先检查导入权限，
等待设置锁后复查姓名与角色；预览也绑定完整身份，同名且同样具备权限的其他角色不能消费。
成功事件进入独立 `pending_settings_import_audit`，与允许偏好在同次 `config::save` 中原子保存；
即使导入偏好值未变化，也记录本次成功结果。失败从磁盘重新加载原配置，
仅在本机配置健康、可写且混合队列有容量时持久入队；坏配置、满队列、磁盘故障等可能无法记录失败，
只输出固定安全诊断，不改变原失败结果。成功提交后，无池/补写失败不撤销或误报偏好保存。
健康可写且有容量的配置可为持久化失败审计而规范化或迁移 JSON，原始字节可能变化；保证允许偏好语义不变，既有事件保留至确认入库。
坏配置、未来版本、不可写配置或补写后仍满的队列不得为记录失败而强行覆盖或挤出既有事件，不泛称所有失败均保持原文件字节不变。
两类事件由启动及后续设置保存/导入共用的补写逻辑处理，按动作/事件 ID 幂等插入，
保留原时间、操作者和结果；随后核对完整记录，检测 `RAISE(IGNORE)` 静默不插入或同 ID 内容冲突，
全部事件确认入库后才保存清空队列。部分插入、取消或清理保存失败保留磁盘队列供下次重放。
这不是配置文件与 SQLite 的跨存储事务，也不保证记录发生在持久提交前的所有取消/崩溃；
仅支持单进程配置写者。准备预览失败和 API 路径解析失败不在此审计边界内。
真实 SQLite 回归源码见 `rust/tests/settings_import_audit_test.rs`，尚未实际编译运行。
跨语言直接字节写入 API `import_external_config` 已删除，调用方须迁移为
`prepare_external_config(input)` → 展示 `preview` 并取得确认 →
`import_prepared_external_config(preview_id)`；手写 Dart bridge 已接入这两个入口，FRB 生成仍待执行。
确认仅使用缓存快照，不能替换输入；进入写入阶段后即消费句柄，保存失败也须重新准备。
Rust 服务层 bytes/file 入口仍保留作内部服务验证，不通过桥接暴露。
缓存单测覆盖精确 TTL 边界、容量淘汰、过期清理、姓名/角色绑定及单次消费，
API 回归覆盖准备不写入、重复提交和目标配置损坏后句柄不可重用，均尚未实际运行。
此 API 协议不能证明用户已阅读预览；Flutter 文本及 native 文件选择入口已编写显式预览/确认，
文件选择/文件预览及持久审计补写已有源码，尚待生成、编译和两平台实测。

Flutter 的“导入设置”工作区先提供无需新依赖的 JSON 文本入口，用户主动粘贴，
不自动读取剪贴板，不把输入视为路径。Flutter 限制编辑长度及编码后的 1 MiB 字节上限，
Rust 再验证编码、版本与结构。拒绝超限编辑时不截断 JSON，也不允许误用此前文本发起预览。
准备成功后清空原文本控制器，显示 Rust 返回的有限长度脱敏预览；不持久化原文或句柄，
不承诺清除 Flutter 编辑历史/系统剪贴板或内存中的所有副本。确认前可以取消或关闭页面放弃此次输入；
取消会清空原文和当前预览，并使旧确认回调失效；Rust 缓存快照仍按 TTL/容量规则清理。
交互回归源码见 `test/features/settings_import_test.dart`：覆盖 UTF-8 与编辑长度上限、
取消和旧回调、双击确认、两条保存队列的完成顺序、回读失败不部分应用、
关闭后状态栏重开只读重试、恢复后拒绝旧重试回调、权限/坏配置保护、
隐藏/模态覆盖和可取消平台退出；尚未执行。
确认同步清掉 UI 句柄，先封闭新的设置/导航写入并等待旧保存队列排空，再调用 Rust 确认。
成功后回读设置和导航，两份均成功才更新语言、主题、显示区域及导航内存状态，不调用保存入口。
已打开标签和草稿不被重建，回读失败则保持偏好写保护，提供仅重读的重试入口；
导入页关闭后仍可从状态栏重新打开，或重启恢复。导入错误不显示原始异常正文。
预览/导入进行中保护该标签关闭与可取消系统退出，状态栏显示一类导入活动。
本轮无新增依赖；文本交互、队列竞态及退出回归源码仍待真实 Flutter/Windows 运行，
系统原生配置文件选择已有 Windows COM / Linux GTK 手写接入，`keel/desktop_files`
仅返回单个本地路径，不读取内容、不执行外部进程。Rust `prepare_external_config_file`
执行权限校验、受限读取和同一份快照缓存；确认仍消费预览句柄，预览后源文件变化不会替换导入内容。
Flutter 在选择期间保持 busy，关闭/退出守卫继续生效；取消不准备、不提交，返回时复查身份和活动页面。
原生接口、路径拒绝、持久审计与生命周期回归源码仍须生成桥接、编译并在两平台运行；批量业务导入仍未完成。

审计页已接入“导出筛选结果 CSV”页面命令和面板，使用已提交的关键词与排序，
忽略当前页码，导出全部匹配项，限 100,000 行 / 64 MiB。独立 `audit.export` 权限允许
admin/operator，viewer 只读不能导出。任务由 Rust 持有，UI 每 500ms 单飞读取进度；
取消为协作请求，若文件已完成则保留完成结论，不能把已生成文件谎报为已取消。
通信失败保留任务 ID、暂停自动轮询，重试只查询原任务，不重复启动导出。
隐藏页面继续显示状态栏活动，关闭审计页仅请求取消该页任务，终态前保留页面和句柄。
CSV 使用固定机器可读字段 `id,at_utc_ms,actor,action,target,result`、UTF-8 BOM 与 CRLF，
时间为 UTC epoch 毫秒，文本做引号转义和公式注入防护；不按界面区域重写机器字段。
导出文件包含业务审计信息，不等同于脱敏诊断包；页面说明字段类别，分享前由用户检查文件。
原始文件保存在应用数据目录 `exports`，不覆盖已有文件；completed 后已有“另存 CSV 副本”入口：
Rust `pub async fn save_audit_export_copy(task_id: String, destination: String) -> Result<String, ApiError>`
成功返回目标路径，只接受本人完成且终态未满 5 分钟的内存任务，要求 `audit.export`，
在阻塞工作排队前、读取前、异步授权等待后及发布前复查完整身份/权限/TTL，不接受任意源文件路径。
Win COM / Linux GTK 的 `chooseAuditCsvSavePath` 经 `keel/desktop_files` 仅返回目标路径，
取消返回 null；保存对话框的覆盖确认不授予 Rust 覆盖权限。
Dart `auditCopyPickerProvider` / `auditCopyWriterProvider`、`saveAuditCopyFromView` 和面板按钮已接入，
选择器及复制期间 `savingCopy` 纳入 busy，禁重复启动并保护标签关闭和可取消退出，
返回后复查同一任务、身份、权限与活动页面；结果路径只向所有者展示。
Rust 验证本地绝对 CSV 目标与普通源文件，限 64 MiB，拒绝既有目标、预置符号链接/重解析点和非法路径；
流式复制到目标同目录唯一临时文件，校验后 hard link 发布完整文件，禁止覆盖，
不支持 hard link 时失败，不回退为直接写目标；临时文件按生命周期清理。
源元数据、长度和内容指纹检测普通损坏/变化，指纹不是安全 hash，不承诺密码学防篡改；
Windows 另以 `GetFileInformationByHandle` 的卷号/文件索引核对完成源句柄、读取及重新打开的文件身份，
不能只凭大小/时间戳相同认定同一文件。祖先目录检查与打开/发布间仍有恶意并发替换 TOCTOU 边界。
另存结果审计 `audit.export.copy` 仅记经校验的任务 ID 和结果，不记录目标路径；
它与文件发布没有共同事务，审计失败只告警。
本轮无新依赖；新增 API、资源及原生交互尚待 FRB/l10n 生成、编译、Win/Linux 测试，
不以回归源码存在认定通过。当前本人进程内任务列表与选回、审计导出持久历史及启动中断恢复已写入源码；打印已有当前审计页预览/确认、快捷键和测试源码，但仍待生成、编译、运行及两平台打印证据；跨功能通用后台任务视图和批量业务导入仍未实现，持久历史与恢复仍待生成、编译、测试和真实重启证据。

导航偏好通过独立 `WorkspaceNavigationPreferences` API 读写，同样由 Rust 读取完整配置并在
同一配置锁内只改导航字段，不覆盖语言/主题/显示区域和待写事件，不生成偏好变更审计。
最近访问最多 10 项、收藏最多 50 项；kind 为 1–64 个 ASCII 字母数字、`-` 或 `_`，
UI 对各列表去重并保留顺序，Rust 拒绝重复项。显式打开、激活和循环切换记访问，关闭后的自动邻页选择不记录。
未知 kind 保留在配置但不显示，页面权限仍由各功能检查。只保存入口和导航折叠状态，
不保存页面数据、不自动恢复已打开工作区或未保存草稿。启动任一配置读取失败时禁止本次
运行写回，仍可临时操作导航；保存失败全局提示并支持重试。此功能无新增依赖。

页面快速搜索覆盖当前注册的页面入口：Ctrl+K 或“窗口 → 打开页面”进入，按当前语言的名称
或稳定 kind 忽略大小写匹配，保持注册顺序；方向键选择、Enter 打开、Escape 取消。
选中已打开页面仅激活同一标签并更新最近访问；取消或空结果不打开页面、不更新访问。
关闭检查期间或其他模态路由打开时不叠加搜索，确认结果执行前重新校验页面注册。
本阶段不查询用户、审计记录、诊断事件或任意业务数据；跨业务数据搜索范围、权限及查询索引
随对应功能设计。此接入无新依赖、不改变 Rust API；仍需生成本地化资源并实际运行测试。

用户工作区保存命令复用现有校验、Unicode 规范化、管理权限和同步提交锁；失败保留输入。
本地校验失败聚焦用户名，并在错误布局完成后将其滚动到可见区域；弹窗、Enter、工具栏
和 Ctrl+S 复用同一路径。延迟滚动检查页面生命周期、焦点和当前路由，模态覆盖时拒绝保存。
已补焦点回归、短容器滚动及 Tab/Shift+Tab 测试源码，尚待 Flutter/Windows 实际运行；
用户创建表单仍仅校验用户名；独立 form_samples 已有多字段分区与错误摘要本地样例，待验证，不代表用户业务表单已扩展。
成功重置但保留标签。取消命令复用脏草稿确认，选择继续编辑保持输入，放弃则重置而不关页。
控制器按 ProviderScope 隔离，编辑器卸载解除连接，弹窗继续使用独立草稿与回调。
取消未绑定工作区 Escape，保留该键给下拉菜单和弹窗自身处理。相关测试源码已补，
仍待 Flutter/Windows 实际运行，本轮无新增依赖或 Rust API 变更。

审计列表的基础选择/复制仅针对当前已加载页：点击单选，表格焦点内上下/Home/End 定位，
Esc 清除，Ctrl+C 或按钮复制时间、操作者、动作、对象、结果五列；时间与当前界面格式一致。
复制 TSV 对制表符、换行、双引号做引用转义，对去除前导空白后以 `= + - @` 开头的字段
添加前导单引号作为文本，界面原文不改；不同电子表格的粘贴解释仍需实际验证。
搜索框保留自身文本复制；剪贴板失败使用安全错误提示。新结果、加载或错误不沿用旧选择，
不持久化选择、不跨页收集数据。此项无新依赖，不等于网格 POC 或大规模剪贴板验收完成。

备份大小沿用 1024 进制计算，单位明确为 KiB / MiB / GiB / TiB，避免误标为十进制 KB/MB。
大单位按独立显示区域保留一位小数，原始整数大小不变；精确字节数按同一区域格式化后交给 ARB 文案，
英语区分单字节与复数，中文显示“字节”。格式器在语言变化后重建，不为显示变更重新读取备份。
`test/features/backup_view_test.dart` 已补零值、单字节、单位边界、舍入、精确字节提示及中英原位切换
的测试源码，尚未实际运行；本轮无新依赖或 Rust API 变更，需在 Windows 重新生成本地化并验证。

SQLite 打开流程使用进程内异步锁，避免多个启动调用同时判断待迁移状态或生成同名迁移前备份；
备份保留清理只处理匹配前缀的普通文件，最多保留最新三份，清理失败不阻断迁移。
并发打开和清理边界测试源码已补，仍需在真实 Rust 工具链下验证；这不代表跨进程并发、
Windows 文件锁、权限错误或性能验收已经完成。

备份恢复的标记文件先写入同目录唯一临时文件并同步，再替换正式标记；已有标记若为符号链接
会被拒绝。恢复复制不再使用固定 `.restore-tmp` 目标，而使用进程号、时间和尝试序号组成的
唯一临时路径，避免跟随预置链接。Unix 符号链接回归已补，Windows 文件替换和权限行为仍需实测。

诊断事件的非空关联 ID 增加逐行复制按钮，提供中英提示与成功反馈，支持 Tab 聚焦后
Enter/空格激活。按钮只把该事件 ID 写入剪贴板，不包含摘要、错误码、路径或其他事件字段；
无 ID 的事件不显示复制按钮，原有文本选择仍保留。单按钮同步防重，失败走安全错误提示。
刷新进入加载状态、新结果替换事件列表后旧按钮卸载；被模态路由覆盖或隐藏时拒绝旧复制回调，
复制完成时若页面已卸载/隐藏/被覆盖，不显示过期提示。已发给系统的剪贴板写入不能撤回。
回归源码见 `test/features/diagnostics_copy_test.dart`，仍待 Flutter 与 Windows 实际运行；
本轮无新依赖或 Rust/桥接 API 变更，不代表诊断包导出或完整列表键盘导航验收完成。

状态栏活动提示只监听已有状态，不启动操作或订阅页面查询，不保留新的任务历史。
备份 busy 包括恢复确认，不能把它描述为“备份正在后台写入”；诊断包只在准备/导出 busy 时计入，
仅打开预览对话框不计入。设置串行队列尚未全部结束时持续计为一类活动，失败后交回原安全错误提示。
计数表示活动类别数，不是 Rust 线程数、排队请求数或百分比进度；数据库重试和设置保存仍沿用现有退出行为。
状态聚合留在 `app.dart`，通过 `statusTrailing` 注入，通用外壳不反向依赖具体功能。
回归入口为 `test/core/activity_status_test.dart`，源码仍待 Flutter/Windows 实际运行；
本轮无新依赖或 Rust/桥接 API 变更，不代表完整后台任务能力验收完成。

诊断中心按关联 ID 精确、区分大小写匹配；两端按 Rust Unicode White_Space 去除首尾空白，
空 ID 表示不按 ID 限制。去除首尾空白后最多 128 个 Unicode 标量，不允许控制字符，
无效输入的提示不回显原始内容。输入框保留未提交草稿，只有搜索/Enter 才提交 ID；
更改最低级别沿用已提交 ID，刷新不偷偷提交草稿，重置恢复 info 与空 ID。
相同条件的重复提交在加载中不重复请求，新条件可以替换正在等待的查询；旧结果不能覆盖新条件，
加载/结果替换时旧事件按钮卸载。隐藏页、模态覆盖或卸载后的旧搜索与局部快捷键回调不执行。
搜索只扫描本次运行内最多 500 条已脱敏事件，先按级别和 ID 筛选，再从新到旧取最多 200 条；
已淘汰或上次运行的事件不在结果中，无匹配不等于故障未发生。页面明确展示查询范围与无匹配提示。
搜索不改变诊断包的类别、快照或导出范围，不自动把筛选条件应用到导出。
公开入口由 `recent_events(limit, min_level)` 改为
`recent_events(DiagnosticEventQuery { limit, min_level, correlation_id })`；
手写 bridge/source 与测试同步，必须重新生成 FRB，不手补生成物。本轮无新依赖。
测试源码见 `test/features/diagnostics_search_test.dart`、`rust/tests/diagnostics_api_test.rs`
与事件缓冲内单测，仍待真实编译运行。

## 11. 风险清单

| 风险 | 等级 | 缓解 |
|---|---|---|
| Rust/Dart 双语言维护 | 中 | Rust 管核心、Dart 管 UI；DTO 稳定；生成物不手改 |
| 网格不达 ERP 需求 | 高 | 阶段 2 POC；收缩 v1；不自研完整引擎 |
| Flutter 非原生控件 | 中 | 按桌面交互规范验证；必要时有限平台适配 |
| SQLite 转服务端库非零成本 | 中 | SQL/事务边界清晰；provider 单独迁移测试 |
| 三方组件维护变化 | 中 | 锁版本、记录替换成本、关键组件保持可替换接口 |
| 许可/传递依赖变更 | 高 | 锁文件、自动许可检查、发布清单、人工复核 |
| Flutter/桥接升级不兼容 | 中 | 同步升级工具链并验证生成结果；不单独升级 codegen |
| 诊断包泄露 | 高 | 最小采集、双向脱敏、预览确认、脱敏回归测试 |
| 恶意依赖/构建工具 | 高 | 锁文件、来源限制、audit/deny/OSV、隔离构建、无机密 PR、SBOM/attestation |
| 发行包被替换/伪造 | 高 | 官方渠道、SHA-256、Authenticode 规划、发布后验证、撤回流程 |
| 恶意导入文件 | 高 | 格式/大小限制、路径规范化、解压上限、暂存+事务回滚、不执行导入内容 |

## 12. 参考来源

版本与许可证在实际锁定依赖时再次复核。

1. Flutter Desktop Support：<https://docs.flutter.dev/platform-integration/desktop>
2. Flutter Windows Build/Distribution：<https://docs.flutter.dev/platform-integration/windows/building>
3. Flutter FAQ（框架 BSD-3-Clause、引擎与包许可说明）：<https://docs.flutter.dev/resources/faq>
4. flutter_rust_bridge package：<https://pub.dev/packages/flutter_rust_bridge>
5. flutter_rust_bridge Quickstart：<https://github.com/fzyzcjy/flutter_rust_bridge/blob/master/website/docs/quickstart.md>
6. SQLx docs.rs：<https://docs.rs/crate/sqlx/latest>
7. PlutoGrid package：<https://pub.dev/packages/pluto_grid>
8. PlutoGrid license：<https://pub.dev/packages/pluto_grid/license>
9. flutter_riverpod package：<https://pub.dev/packages/flutter_riverpod>
10. fluent_ui package：<https://pub.dev/packages/fluent_ui>
11. Rust Release Announcements：<https://blog.rust-lang.org/releases/>
12. RustSec Advisory Database：<https://rustsec.org/advisories/>
13. cargo-audit：<https://github.com/rustsec/rustsec/tree/main/cargo-audit>
14. cargo-deny checks：<https://embarkstudios.github.io/cargo-deny/checks/index.html>
15. OSV-Scanner 支持的锁文件：<https://google.github.io/osv-scanner/supported-languages-and-lockfiles/>
16. OWASP Software Supply Chain Security Cheat Sheet：<https://cheatsheetseries.owasp.org/cheatsheets/Software_Supply_Chain_Security_Cheat_Sheet.html>
17. GitHub Artifact Attestations：<https://docs.github.com/en/actions/concepts/security/artifact-attestations>
18. Microsoft SmartScreen reputation：<https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation>
19. Microsoft SignTool / Authenticode：<https://learn.microsoft.com/en-us/windows/win32/seccrypto/using-signtool-to-verify-a-file-signature>
20. Authenticode 时间戳指南：<https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures>

### 本轮离线纠偏与开放契约

- F02/P01：Dart 本地日期转换与 Rust `AuditQuery`/`ListParams` 可选 UTC 毫秒边界已对齐；`start_at_ms` 包含、`end_at_ms_exclusive` 不包含，两端都有值时拒绝 start >= end。列表/COUNT/导出预检及批次共用参数化 WHERE，SQLite/API/跨批次/快照回归源码已有；FRB/l10n 生成、Rust/Flutter 编译测试与 DST/平台执行仍待完成。
- F03：现有用户名/角色短表单、单字段错误摘要、草稿与命令待执行验证；类型输入、多字段分区与摘要已在 form_samples 本地样例编写；实际键盘/取消/焦点及保存业务仍待验证或实现。
- T01：固定列（start/body/end 三段渲染）、列配置持久化（Rust 用户隔离 CAS）与当前页多选已实现；隔离 POC 已实跑范围复制 TSV、编辑/粘贴合同校验、1M 行单页物化与虚拟化、翻页替换（见 `docs/GRID_POC.md`）。`pluto_grid`/`trina_grid` 同用例对比已于 2026-11-09 实跑两轮（trina 62 项全过；pluto 54 项 + 2 skip；缺陷 5 已修、快捷键覆盖陷阱、取页静默失败与 Fluent 宿主 Material 祖先差异三项，见 GRID_POC.md 该节与 `build/reports/grid-poc-trina-20261109.md`）；**已锁定 trina_grid 2.4.0**（ADR-012），往来单位示例页已改用网格，`code/name/phone/email` 已接内联编辑与 Ctrl+V 区域粘贴（原子批量更新），audit 页仍为自绘冻结列表格。Fluent 宿主已在 widget 级同仪验证（真实按键、对话框覆盖、深浅主题），真实 OS 焦点/窗口、进程内存、Win/Linux 与 DPI 矩阵仍开放，[网格报告模板](GRID_POC_REPORT_TEMPLATE.md) 对应行默认 NOT RUN。
- 活动聚合仅展示现有 busy 类别，待验证；审计本人内存任务列表已有源码、待生成与验证（Registry 最多6项、终态5分钟 TTL）；审计导出已有独立持久历史表、30天/1000条终态清理和启动时 running→interrupted 恢复，不自动重放，也不根据 CSV 文件推断完成。审计事件不是任务恢复记录。
- I02：配置 v5 已实现独立时区（系统/UTC）与币种（未指定/CNY/USD/EUR/GBP/JPY）设置并接入视图菜单；DST/系统区域平台事件与更多地区仍待实测，数字/复数统一与 RTL 未实现；金额精度/舍入与业务时区语义仍须产品决策，不从语言或区域推断币种。
- 批量业务导入已有 `app_user` JSONL 一例（整批事务、进度、协作取消、权限与审计）；其他实体仍须先明确格式/编码、大小/字段/记录上限、唯一键/重复策略、整批或部分提交、取消点与审计。打印当前仅覆盖审计当前页纯文本，其他范围/布局须先产品定义。跨配置与 SQLite 事务、归档导入仍未实现。

本轮 Python/脚本离线验证见 [OFFLINE_VALIDATION.md](OFFLINE_VALIDATION.md)，不构成桌面、编译或正式发布放行。

**发布与平台的外部条件**（Authenticode 签名、构建来源 attestation、Defender/SmartScreen 记录、
远端标签 ruleset、Linux 发行形态与打包、干净环境安装升级卸载、公告库完整扫描、CI 真实首跑、
品牌资源授权、发布者允许名单）逐条列在
[IMPLEMENTATION_STATUS.md 的外部条件阻塞清单](IMPLEMENTATION_STATUS.md#外部条件阻塞清单发布与平台仓库内代码不能自证)，
仓库内代码与脚本不能关闭这些项，也不因此放宽任何既有门禁。

### 本批集成记录：任务视图与类型表单样例（2026-11-02）

`KeelApp._pages` 通过 `UiPage` 静态登记 tasks 与 form_samples；任务页读取当前进程 Rust Registry 本人审计 CSV 列表，
最多6项，创建时间倒序、任务ID打破平局；所有终态满300秒隐藏、查询不续期，原文件保留。
按ID选回须重新查询Rust所有者/TTL；启动、请求、复制或非终态任务期间禁止替换句柄。
显示与旧操作回调检查用户加载/错误、所有者和 audit.export；仅本人已完成结果可显示路径并另存。
迟到未知阶段也保留句柄保护。独立历史页读取持久化任务元数据；启动时把 durable running 标记为 interrupted，
不自动重放或恢复旧操作句柄，不增加通用调度框架。
审计页与任务页共用关闭守卫，未确认终态（含未知阶段）、启动、请求与复制 busy 均保留关闭保护；
原 app canExit 的孤立导出保护保持，不能因为仅打开任务页而放行全局导出 busy。
未知协议阶段保留 busy 和关闭保护，允许所有者在身份就绪且具备 audit.export 权限时人工只读重查；
任务视图与审计面板均提供入口，失败保留句柄与保护，确认终态才释放。取消与自动轮询仍仅支持
已知 running 阶段，未知阶段不重发 start/cancel，不声称实现任意协议恢复。

form_samples 是普通 StatefulWidget，由作用域内稳定 GlobalKey 连接关闭守卫，监听独立显示区域；
文本、int32、BigInt 精确 USD 最小单位、1900–2100 日历日期、本机日期时间和枚举仅作本地预览。
金额固定 USD 两位小数、非负上限 9,999,999.99；三个支持区域统一 . 小数和可选 , 三位分组。
日期时间拒绝归一化/DST 缺口，重复时间沿用宿主选择；无时区选择或业务排程保证。
预览不保存，编辑清预览，关闭仍确认；批量关闭批准不提前清草稿。合法区域转换保留含义，
无效旧日期要求显式重编辑。预览/重置和延迟聚焦滚动检查 mounted、当前路由、隐藏状态；
隐藏页 canClose 仍可确认。无 Rust 业务校验、桥接变更、依赖新增或生成区手改。

中英各补34条资源，四个带参条目按调用顺序声明 String placeholder。
独立源码复核修复共享审计面板/操作在身份重载时读取旧身份，以及未知阶段未计入全局 busy；
补真实 appPages 注册 fixture、隐藏草稿关闭/可取消退出、旧回调和未知阶段回归源码。
`python3 -B scripts/check_sources.py` 当前退出 1，报告 l10n 声明、FRB 函数及 FRB 模块/文件缺失；如使用 `--allow-pending-generation`，退出 0 只表示 PARTIAL，不能关闭生成、编译或测试门禁；
`python3 -m unittest discover -s scripts/tests -v` 实际退出0，30项通过。
`command -v flutter`、`command -v dart`、`command -v cargo` 均未找到工具（退出1）；
未执行 l10n/FRB生成、Dart格式化/analyze/widget tests、Rust门禁及桌面验收，源码检查不等于编译。

### 本批集成：历史诊断文件检索（2026-11-02，源码待验证）

独立显式提交的文字检索，不改变最近500条事件缓冲查询。Rust复用diagnostics.export，
读取前授权、spawn_blocking完成后复查完整姓名/角色及权限；UI身份加载/失败立即隔离旧数据和回调。
目录固定为应用数据logs，不接受路径；只读合法keel.log.YYYY-MM-DD普通文件，拒绝链接祖先、symlink及Windows重解析点。
最多枚举256目录项、读取14文件、扫描4MiB、返回200行；输入128 Unicode标量，输入行8192字节，输出行2048标量。
完整行二次脱敏后区分大小写字面匹配，非法UTF-8/超长/不完整行跳过并标记truncated；有限枚举不保证覆盖全部最新文件。
保留tracing文本，不解析成事件；脱敏可能遗漏，祖先目录恶意并发替换TOCTOU仍在。
关闭弹窗丢弃迟到结果，底层有界单飞扫描持有许可直至结束；日志保留可能跨进程，但不是任务持久历史或恢复协议。

网格仍未准入：缺目标版本发行包源码/API、LICENSE正文/哈希与传递依赖证据，缺可用工具链及新桥接，
缺Windows/目标Linux完整矩阵实测。先定义按用户稳定标识+列表ID隔离列偏好/独立编辑fixture，接包与准入须补上述证据。
