# Keel — 产品需求与详细规范

最后更新：2026-10-31。技术基线与开发规范见 [AGENTS.md](../AGENTS.md)；本文件是产品需求与详细规范的权威，2026-10-31 自 AGENTS.md 拆分而来，后续独立维护。

**读取规则：按需读取，不要求全读。** 任务涉及某领域时，先读对应章节再动手；不涉及的章节不读，也不凭记忆推断。AGENTS.md §8 有“任务类型 → 章节”对照表。

## 1. 通用 Admin 功能范围

### 1.1 桌面外壳

标题栏、菜单栏、命令工具栏、可折叠左侧导航、多工作区标签（新建/切换/关闭/关闭其他/关闭全部；固定按需）、内容区（列表/详情/编辑/分步）、状态栏（数据库、当前用户、版本、后台任务）。统一命令：刷新、保存、取消、搜索、导入、导出、打印；命令注册到清晰的界面层配置，不做动态插件系统。全局搜索、最近打开、收藏分阶段加入。

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

PlutoGrid 是首选候选，不是已验收结论。必测：

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

Flutter/Dart BSD-3-Clause（引擎与包另有清单）；flutter_rust_bridge MIT；flutter_riverpod MIT；pluto_grid MIT；fluent_ui BSD-3-Clause（社区实现，维护集中度需关注，可替换）；intl / flutter_localizations BSD-3-Clause；file_selector BSD-3-Clause；SQLx MIT OR Apache-2.0；Tokio MIT；Serde/serde_json MIT OR Apache-2.0；tracing 系列 MIT；thiserror/anyhow MIT OR Apache-2.0；chrono MIT OR Apache-2.0；uuid Apache-2.0 OR MIT；csv MIT OR Unlicense；zip MIT；regex MIT OR Apache-2.0；dirs MIT OR Apache-2.0。

以下为代码清空前快照的核对记录（2026-10-31；`pubspec.yaml` 已不存在，重建时按本节重新核验）：`cupertino_icons` MIT；`flutter_lints` BSD-3-Clause（供 `analysis_options.yaml` 启用）；`plugin_platform_interface` BSD-3-Clause；`integration_test` / `flutter_test` / `flutter_driver` BSD-3-Clause（Flutter SDK）；`tempfile`（dev）MIT OR Apache-2.0；`rust_builder/cargokit` 为 vendored 源码，自带 LICENSE（MIT + Apache-2.0 文本），不得删除；`ffi` / `ffigen`（rust_builder 的 dev 依赖，不随发行物）待核。

标注：`intl`、`file_selector`、`pluto_grid`、`riverpod`、`fluent_ui` 尚未进入 `pubspec.yaml`，属计划/候选依赖；引入时按本节重新核验。

### 7.3 自动化检查

- Rust：`cargo fmt --check`、`cargo clippy`、`cargo test`；`cargo-deny` 查 license/advisory/bans/sources；`cargo audit` 查 RustSec。
- Dart：`analysis_options.yaml` 引入 `flutter_lints` 官方推荐规则；`dart format --set-exit-if-changed`、`flutter analyze`、`flutter test`。
- 桥接：生成后检查工作区无非预期差异，生成步骤可复现。
- 发布流水线产出依赖清单与许可证报告；高风险/不明许可证人工复核，不自动放行。

### 7.4 发布阻断条件

- 每次合并/定期：`cargo audit`、`cargo deny`、OSV-Scanner（扫 `Cargo.lock` 与 `pubspec.lock`，作为第二数据源）；例外必须写公告编号、影响分析、负责人、复查日期，不允许无说明长期忽略；secret scanning；`dart pub outdated` 只用于发现更新机会，升级单独提交并测试。
- 未审核的 Git 依赖、path override、子模块、直接下载二进制建单独清单；发行构建不得默默使用开发机本地覆盖。
- 工具本身也是供应链：记录 Rust、Flutter/Dart、codegen、打包器、安装器、CI Action 版本；CI Action 尽量固定到完整 commit SHA 并定期复核。
- 发布包只由受控 CI 的受保护分支/标签生成；runner 短生命周期、最小权限；普通 PR 不拿发布凭据/签名私钥/生产密钥；fork/外部贡献在无机密隔离作业构建；发布任务与测试任务分开，仅受保护标签可触发签名与发布；签名私钥不进源码、日志、普通产物。
- 发行构建记录 commit、工具链、锁文件、工作流、产物哈希；有条件下生成 SBOM（SPDX 或 CycloneDX）与来源证明/attestation；验证 attestation 要核对仓库、工作流、commit、受保护发布身份。
- 分发：官方渠道 + 版本 + commit + SHA-256 + SBOM + 许可证清单；Windows 规划 Authenticode 签名（证书与时间戳成本单列决策），覆盖 `.exe`、`.dll`、安装器，发布后验证签名与时间戳；用户可用 `signtool verify /pa /v` 与官方哈希比对；不引导用户从网盘/重打包站/聊天附件取包，不因 SmartScreen 提示让用户关 Defender 或忽略未知发布者。
- 自动更新：v1 不实现静默更新；未来更新清单必须由发布密钥签名，客户端先验签名、版本、目标平台、SHA-256 再安装；校验失败/回滚异常/来源不符即拒绝，不得“提示后仍可强制安装”；更新器不执行远程脚本、不从固定域名以外下 DLL、不自动提权；设计密钥轮换/泄露撤销/停发流程，失败保留可恢复版本与数据备份。
- 签名、哈希、SBOM、扫描是不同层次证据，不能宣称“已签名/已扫描所以绝不可能中毒”。

### 7.5 许可证文件清单（发行必需）

| 文件 | 归属 | 现状 | 要求 |
|---|---|---|---|
| `LICENSE` | Keel 自身出站许可 | 已定：MIT（2026-10-31） | 保留版权与许可声明；更换许可主体时同步本文件与 §7.1 |
| `THIRD_PARTY_NOTICES.md` | 运行时依赖的版权与 NOTICE | 缺失 | 由 `cargo-deny` + `dart pub deps` 结果生成；覆盖直接与传递运行时依赖，保留原文声明 |
| Flutter `NOTICES` | 引擎、框架与 SDK 包 | 未验证 | 构建后确认 `data/flutter_assets/NOTICES` 存在，并随 Windows/Linux 发行包发布 |
| `rust_builder/cargokit/LICENSE` | vendored 源码 | 随代码清空移除 | 重建时随 FRB 模板恢复；若保留该源码，其 LICENSE 不得删除，声明并入 THIRD_PARTY_NOTICES |
| `assets/branding/*` | 品牌图片与图标 | 无来源/授权记录 | 原创需注明归属；第三方需附许可与来源 |
| 字体文件 | 未来引入 | 暂无 | 每个字体单独附许可；OFL 字体保留版权行与保留字体名条款 |
| `rust/Cargo.lock`、`pubspec.lock` | 依赖版本 | 缺失，阶段 0 重建时生成 | 发行构建只用锁定版本 |
| SBOM（CycloneDX 或 SPDX） | 构建产物 | 缺失 | 发布流水线生成并随包保留 |
| `cargo-deny` / OSV / `dart pub deps` 报告 | 审计产物 | 缺失 | 发布前留存；例外必须带编号与到期复查日期 |

- 开发/构建期依赖（`tempfile`、`ffi`、`ffigen`、`flutter_lints` 等）不随发行物，但仍纳入许可审查与自动扫描。
- `publish_to: none` 只表示不发布到 pub.dev，不豁免许可证与 NOTICE 义务。

## 8. 配置、升级、备份与交付

- 安装目录只放程序和只读资源；配置、数据库、日志、缓存分放系统应用数据目录；数据目录与程序版本分离，升级不覆盖用户数据；路径支持空格、Unicode、非 ASCII、不同用户名。
- 数据库升级：启动读 schema 版本；按序迁移并记录；高风险迁移先备份；失败给摘要、诊断 ID、恢复指引；不自动丢弃未知列/用户数据；准备旧版本数据样本，升级前后核对记录数、关键约束与字段。
- Windows：`.exe` + 引擎 DLL + `data` 目录 + 必要运行时；v1 可选目录式 ZIP 或安装包；安装器（Inno Setup、WiX 等）先核许可、维护与打包方式。发布检查：Release 构建；干净环境安装运行；无开发机路径依赖；首次启动建数据目录并初始化；升级/卸载/重装不误删用户数据；Defender 扫描并记录日期/引擎版本/结果；签名与 SHA-256 验证；提供来源、版本、commit、哈希、SBOM、许可证，并确认 `LICENSE`、`THIRD_PARTY_NOTICES`、Flutter `NOTICES` 随包发布。
- Linux：CI 至少编译 + 基本测试；正式支持发行版范围在首个可发布版本明确；选打包格式前评估系统依赖、桌面文件、图标、文件选择、剪贴板、快捷键、字体差异；不因“能编译”宣称全发行版支持。
- v1 不做静默自动更新；签名、Defender 扫描、SBOM 按 §7.4 执行。

## 9. 测试与验收

### 9.1 合并门槛

Rust fmt/clippy/单测；Dart format/analyze/widget 测试；迁移测试与关键 API 测试；桥接可生成、类型对齐、错误映射；cargo audit/deny/OSV + 许可证检查；secret scanning、SBOM/依赖清单、产物哈希与来源记录；生成后无非预期差异。门槛只聚焦安全、数据正确性、构建、许可、升级兼容，不为所有 UI 改动设审批流。

### 9.2 POC 业务用例

启动/关闭/重启；多标签创建/切换/关闭；商品列表查询/分页/排序/筛选/复制/基础编辑；批量导入显示进度、可取消、资源回收；制造数据库错误，UI 显示安全提示且日志中心可查；导出诊断包并确认无密码/令牌/客户名/私人路径；中英切换与日期/数字/金额格式；Windows Release 在干净环境运行；Linux 构建冒烟。

### 9.3 放行条件

网格满足 §6 必测；桥接无卡死、内存失控、难定位的生命周期问题；关键工作区循环开关资源释放符合预期；迁移/备份/恢复有可重复测试；许可与传递依赖无未解决阻断项，高危告警有已验证处置；发行物来自官方渠道、哈希可比对、启用签名时验证成功；不可信 PR 无法读发布/签名凭据；`LICENSE`、`THIRD_PARTY_NOTICES`、Flutter `NOTICES` 齐全且随包发布；非原作者能按 README 在干净环境构建并完成一个新列表页和编辑页。

## 10. 阶段路线

| 阶段 | 交付 | 完成标准 |
|---|---|---|
| 0 环境与冻结 | 官方 Flutter Windows 项目 + Rust crate；集成 FRB 跑最小字符串/结构体/异步样例；固定工具链、锁文件、生成步骤；输出许可证清单与漏洞扫描；配置依赖锁定、来源审查、secret scanning、隔离 CI | 干净 Windows 按文档构建运行；生成可复现；安全扫描可运行并出报告 |
| 1 桌面外壳 | 菜单、工具栏、侧边导航、标签工作区、状态栏；主题与中英文；统一错误提示、诊断中心基础页；工作区关闭资源释放 | 可切模块、多标签开关、切主题/语言；无资源持续累积 |
| 2 数据库与网格 POC | SQLx + SQLite 初始化/迁移/备份/恢复；商品档案查询/分页/排序/筛选/保存；PlutoGrid 虚拟化/键盘/剪贴板/列设置/基础编辑；1 万/10 万/100 万测试 | 网格通过验收或明确换组件；不以未验证网格为正式基础 |
| 3 通用组件与二开 | 表单校验、统一命令、选择器、导入导出、确认对话框；模块样例与新增页面指南；日志脱敏、诊断导出、许可证报告 | 新开发者照文档加模块，无需了解全部内部细节 |
| 4 发布与兼容 | Windows Release、安装/升级/卸载测试；Linux 构建与目标环境验证；旧库迁移回归、性能、依赖安全/许可复核；恶意软件扫描、签名/哈希/SBOM/来源记录、撤回流程 | 发布清单齐全、限制明确、无未处理阻断、产物可验证、可安全升级 |

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
