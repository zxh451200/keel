# Keel — 技术基线与开发规范

最后更新：2026-11-01。来源：《Keel Rust + Flutter 通用桌面 Admin 技术总方案 v1.1 安全加固版》、安全发布检查清单 v1.1、2026-10-31 目录与分层评审结论、2026-11-01 阶段 0 重建与桥接验证结论。本文件是技术基线与开发规范的唯一权威；产品需求与详细规范见 `docs/REQUIREMENTS.md`（读取规则见 §8）。历史版本文档只在仓库外归档，不进仓库。README 只做入口。

## 0. 当前状态（先读，别假设）

- 2026-11-01：阶段 0 主体落地。官方 Flutter Windows 工程 + Rust crate + FRB 2.13.0 骨架可构建可运行；
  桥接三类样例（同步字符串 / 同步结构体 / 异步结构体）在 `flutter test integration_test -d windows`
  真实构建下通过，Dart 侧展示层与 FFI 接线分离，`flutter test` 不需要动态库。
- 工具链与锁定：`rust-toolchain.toml`（stable）、`rust/Cargo.lock`、`pubspec.lock` 已入库；
  codegen 与门禁命令见 README「常用命令」。新增直接依赖：`tokio`（锁定 1.54.1，仅 `time` feature，
  runtime 由 FRB 创建）。
- 依赖治理：`rust/deny.toml`（cargo-deny 0.20：许可证白名单 / 来源限制 / 重复依赖 / 公告）+
  `scripts/security-check.sh`（报告写入 gitignore 的 `build/reports/`；退出码 0 通过 / 1 违规或缺工具 /
  3 无违规但公告库取不到、发布不放行）；`THIRD_PARTY_NOTICES` 按依赖包 LICENSE 正文核对（2026-11-01）。
  2026-11-01 为清除 cargo-audit 报出的 yanked/unsound/unmaintained 跑过一次 `cargo update`
  （semver 范围内，tokio 1.34.0 → 1.54.1 等），更新后重跑全部门禁与 Windows 集成测试。
- CI 已落地（GitHub Actions，远端已确定）：`.github/workflows/ci.yml` 两个 job——`windows` 跑全部门禁 +
  桥接端到端 + `scripts/security-check.sh`，`linux-rust` 跑 Rust 层可移植性冒烟；Action 全部固定到完整
  commit SHA，osv-scanner 2.7.0 与 gitleaks 8.30.1 按官方发布物 SHA-256 校验后使用，报告作为 artifact 保留 30 天。
  `.github/dependabot.yml` 覆盖 cargo / pub / github-actions。
- 阶段 0 未完项：SBOM、签名与发布工作流、Defender 扫描记录属阶段 4 发布流水线；`.gitattributes` 已固定脚本换行符。
  CI 的 `windows` job 首次在真实 runner 上执行时仍需观察（本机会话无法代跑），失败按 §10 修因不放行。
- 本机开发注意：`C:\tools\bin\flutter` / `C:\tools\bin\dart` 包装脚本导出 `PUB_HOSTED_URL` 指向清华镜像，
  触发依赖重新解析的命令（本会话是 `flutter pub deps`）会把 `pubspec.lock` 里 35 处 `url:` 从
  `https://pub.dev` 改写成镜像地址（版本号与 sha256 不变）。提交前必须 `git diff pubspec.lock` 复核并
  还原为 pub.dev；发行构建按需求文档 §7.4 用官方 registry 重建。
- 数据网格与 SQLite/SQLx 选型验证（需求文档 §6、阶段 2）尚未开始；不以未验证网格为正式基础。

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
| 数据网格 | PlutoGrid（MIT，候选） | 未验收；不通过换组件，不自研完整引擎 |
| UI 视觉 | Flutter 组件 + Keel 设计令牌；可 POC fluent_ui | 专业桌面惯例，不做网页式大卡片 Dashboard |
| 国际化 | flutter_localizations + intl + ARB | 可见文字全部进资源文件 |
| 配置 | 版本化配置文件 + 系统用户目录 | 可变数据不进安装目录；敏感信息不明文存普通配置 |
| 构建锁定 | Cargo.lock + pubspec.lock + 工具链记录 | 发布可复现；只升级测过的组合 |

### 2.2 锁定规则

- Rust 用当前 stable，记录在 `rust-toolchain.toml`；CI 与开发机同一工具链，不跟随 nightly。
- Flutter/Dart 用 stable 同一已验证版本，CI 固定版本。
- FRB 用稳定版，固定 codegen + 运行时兼容组合。
- SQLx、PlutoGrid、Riverpod 等先通过 Windows 构建与关键行为测试，再锁进 lock 文件。
- 正式版本不用浮动 Git 分支；必须用 Git 依赖时锁到 commit 并记录原因。
- 调研参考值：FRB 2.13.0、SQLx 0.9、PlutoGrid 8.1.0——不等于可直接使用，须 POC 后锁定。

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
2. 用稳定明确的请求/响应类型（如 `ProductQuery`、`ProductPage`、`SaveProductRequest`、`OperationResult`）。
3. 不把 SQLx row、连接池、事务句柄或内部实现暴露给 Dart。
4. 列表一次分页调用返回一页；禁止逐单元格调用。
5. 批量/导入/长任务异步化，提供阶段、进度、取消；进度事件限频。
6. 错误保留可供程序判断的 code，用户提示与内部诊断分开。
7. 生成文件不手改；生成步骤写入 README/CI。
8. 跨语言 DTO 视为公共接口；破坏性改动同步更新 Rust、Dart、测试与迁移说明。

## 4. 目录结构（V1）与规则

```text
keel/
├─ AGENTS.md  README.md
├─ .github/workflows/ci.yml          # GitHub Actions（远端已定）：门禁 + 依赖治理 + 密钥扫描；Action 固定到 commit SHA
├─ .github/dependabot.yml            # cargo / pub / github-actions 升级 PR
├─ assets/branding/                # 品牌资源，须在 pubspec 声明
├─ docs/                           # REQUIREMENTS.md 产品需求；adr/ 按需
├─ lib/
│  ├─ main.dart  app.dart
│  ├─ l10n/                        # app_zh.arb / app_en.arb（gen-l10n 默认路径）
│  ├─ api/bridge.dart              # 手写桥接适配层：初始化、错误映射、DTO 转出
│  ├─ core/                        # 只放跨业务基础能力
│  │  ├─ app/ routing/ workspace/ theme/ localization/ errors/ state/
│  ├─ features/<feature>/          # 一功能一目录；推荐 view/ state/ widgets/
│  ├─ shared/                      # 只放确认 ≥2 处复用的组件
│  │  ├─ widgets/  tables/ formatters/
│  └─ src/rust/                    # ⚙ FRB 生成，禁止手改
├─ rust_builder/                    # ⚙ FRB 模板：cargokit 构建插件，挂进 flutter build
├─ rust/
│  ├─ Cargo.toml  Cargo.lock
│  ├─ deny.toml                     # cargo-deny：许可证白名单/来源/重复依赖/公告
│  ├─ migrations/                  # 000N_描述.sql，编号连续（sqlx migrate add -s）
│  ├─ src/
│  │  ├─ lib.rs
│  │  ├─ api/                      # DTO + 命令
│  │  ├─ services/                 # 业务操作 + 事务
│  │  ├─ data/                     # SQLx / 查询 / 审计
│  │  ├─ domain/                   # 按需；领域规则
│  │  ├─ diagnostics/              # 日志、事件缓冲、脱敏
│  │  ├─ tasks/  config/           # 按需；有真实功能再建
│  │  ├─ errors.rs  state.rs
│  │  └─ frb_generated.rs          # ⚙ 生成
│  └─ tests/                       # 真 SQLite 集成测试
├─ test/{core,features,shared}/    # 只镜像顶层，不做深镜像
├─ integration_test/               # 加载真实 Rust 库的端到端测试
├─ scripts/                        # security-check.sh（许可证/公告）；codegen 包装与打包按需再加
├─ windows/  linux/                # ⚙ flutter create 平台壳
├─ packaging/{windows,linux}/      # 安装器与发行物；不另建 installer/
├─ pubspec.yaml  pubspec.lock  analysis_options.yaml
├─ .gitattributes                   # 固定脚本 LF / 平台文件 CRLF（Windows 开发机 autocrlf=true）
├─ flutter_rust_bridge.yaml
├─ rust-toolchain.toml             # 已建：stable + rustfmt/clippy
├─ LICENSE                         # MIT（已建）
└─ THIRD_PARTY_NOTICES             # 已建：按依赖包 LICENSE 正文核对（2026-11-01）
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
- 错误码：`KEEL-VALIDATION`、`KEEL-NOT-FOUND`、`KEEL-DUPLICATE-SKU`、`KEEL-DB`、`KEEL-DB-MIGRATION`、`KEEL-IO`、`KEEL-IMPORT`、`KEEL-BACKUP`、`KEEL-UNINITIALIZED`、`KEEL-INTERNAL`。新增码先登记。
- 日志级别 TRACE/DEBUG/INFO/WARN/ERROR；Release 默认不输出高量调试日志；关联 ID 贯穿 Dart 调用、Rust 服务、数据库操作，不用个人敏感信息作 ID。
- 可恢复错误给重试/取消/详情；不可恢复给备份、修复或导出诊断建议。

## 7. ADR

- ADR-001 Rust 为核心语言——通过。
- ADR-002 Flutter 作桌面 UI——选定基线，须 POC。
- ADR-003 FRB 作桥接——通过；POC 起点版本 2.13.0（codegen 与运行时一致），最终版本 POC 后锁定。
- ADR-004 SQLite + SQLx——通过；具体版本 POC 后锁定；PG/MySQL 单独立项。
- ADR-005 PlutoGrid 优先候选——未验收；不通过换组件，不自研完整引擎。
- ADR-006 遵循社区惯例，不建私有框架——通过；不建 DSL/事件总线/服务定位器/过度 Repository。
- 待建：ADR-007 日志与诊断脱敏、ADR-008 国际化与时区、ADR-009 Windows 优先 + Linux 持续构建、ADR-010 依赖许可治理、ADR-011 发布签名与更新策略。新增 ADR 放 `docs/adr/`（需要时再建）。

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
flutter gen-l10n                                          # 改 ARB 后
flutter test integration_test -d windows                  # 真加载 Rust 动态库的桥接端到端
flutter run -d windows
flutter build windows --release
```

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
- v1 不做静默自动更新；签名、Defender 扫描、SBOM 按需求文档 §7.4 执行。
- 网格高级能力与超大数据量以 POC 结果为准。
- 框架升级不承诺三方代码零修改，破坏面收敛在公共 API。
- 安全控制是风险降低措施，不承诺“绝不感染”。
