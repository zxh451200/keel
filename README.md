# Keel

通用桌面 Admin 开发底座：Rust 负责业务与数据，Flutter 负责 Windows/Linux 桌面 UI。

**技术基线与开发规范见 [agents.md](agents.md)，产品需求与详细规范见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)**（按需读取）。本文件只做入口。

2026-11-04 基线：Windows Release 曾完成验证；当前副本的扩展 FRB/l10n 生成一致性仍待固定工具链重跑。
下面“已接入”表示实现已存在；具体功能、完整 DPI/性能矩阵、Linux 和发布门禁须分别验收。
本轮后续修改仍须重跑对应检查，不能自动沿用此前的 Windows 构建结果。

## 技术栈（目标基线）

| 层 | 选型 | 现状 |
|---|---|---|
| 核心 | Rust stable（`rust-toolchain.toml` 已锁 stable + rustfmt/clippy） | 可用 |
| UI | Flutter stable / Dart 3 | 可用（Flutter 3.47.8 实测） |
| 桥接 | flutter_rust_bridge 2.13.0（codegen 与运行时同版本，生成代码不手改） | 已验证：同步字符串 / 同步结构体 / 异步结构体三类调用（2026-11-01） |
| 异步 | tokio（阶段 0 锁 1.54.1；当前启用 `time` / `sync`，runtime 由 FRB 创建） | 定时器曾验证；初始化锁待本轮验证 |
| 数据库 | SQLite + SQLx | 已接入：WAL、外键、迁移、迁移前自动备份、审计日志分页列表；网格选型验证仍属阶段 2 |
| 状态 | flutter_riverpod + StatefulWidget | 已接入（语言、主题、显示区域 provider，设置经 Rust 存盘） |
| 表格 | PlutoGrid（POC 待验收） | 未引入，阶段 2 |
| 用户与权限 | 本地用户 + admin / operator / viewer 三种角色，权限检查在 Rust 边界，拒绝与切换都写审计 | 已接入；不是对本机管理员的安全隔离（`agents.md` §11） |
| 备份与恢复 | 手动备份（`VACUUM INTO`，保留 10 份）、校验后登记恢复，下次启动时替换数据库并保留旧库；取消恢复也检查权限并审计；写操作/确认防重与关闭保护 | 源码已接入，待真实验证 |
| 外壳 | Fluent 菜单栏 + 可折叠导航 + 多标签工作区 + 状态栏（`lib/ui/`） | 已有；页面在 `app.dart` 的 `_pages: List<UiPage>` 里登记，接入见二开指南 |
| 国际化 | flutter_localizations + intl + ARB（zh / en） | 已接入：运行时语言切换与区域日期/数字格式；备份大小使用二进制单位及精确字节提示；新增资源待生成验证 |
| 日志 | tracing + 滚动文件 + 诊断中心 | 文件日志已接入（按天滚动、写入前脱敏、保留 14 天）；诊断中心已接入（最近 500 条错误/警告/panic，按级别过滤，显示关联 ID） |

## 环境要求

- Windows 10/11 x64
- Visual Studio 2022 Build Tools，勾选「使用 C++ 的桌面开发」
- Flutter stable（`flutter doctor -v` 全绿）
- Rust stable（MSVC toolchain）
- flutter_rust_bridge_codegen 2.13.0（`cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked`）
- 依赖治理工具（`scripts/security-check.sh` 会检查并给出安装命令）：
  `cargo install cargo-license cargo-deny cargo-audit --locked`

## 第一天：按顺序跑通

Windows 已安装环境要求中的工具后，可先运行：

```powershell
.\scripts\verify.ps1 -ResolveDependencies
```

这是需要重新解析依赖时的入口：会重新解析依赖、生成 FRB 和本地化文件，执行源码声明检查，格式化源码，
然后跑 Rust clippy/test、Flutter analyze/test 和 Windows 桥接端到端；首个失败步骤即停止。
完整输出追加到 `verify-output.txt`（不入库，分享前检查本机路径等信息）。
脚本不安装工具、不覆盖用户数据、不自动还原改动；生成物、锁文件与格式化改动须一起核对，
新增依赖须复核许可证与 NOTICE 后才能合入。后续默认运行 `.\scripts\verify.ps1`，
会要求已有锁文件可用；可另加 `-BuildRelease` 或 `-Security`，本地验证脚本不替代 CI/发布验收。

在项目根目录依次执行，每步都对一下预期。某一步不对就停在那里，不要往下跑。

| 步骤 | 命令 | 预期 |
|---|---|---|
| 1 | `flutter doctor -v` | Windows 一栏为 ✓（含 Visual Studio C++ 工作负载） |
| 2 | `flutter pub get` | 结束无报错；**`git diff pubspec.lock` 应为空**（见下面「已知坑」） |
| 2.5 | `flutter gen-l10n` | 在 `lib/l10n/` 生成 `app_localizations*.dart`（不入库，已在 .gitignore）；改了 ARB 后重跑，并执行源码门禁 |
| 3 | `flutter_rust_bridge_codegen generate` | 结束无报错；生成物与当前公开 API 对齐，核对后提交；再次生成应可复现 |
| 4 | `cd rust && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` | 全部通过；`fmt --check` 报差异就运行 `cargo fmt` 再提交（CI 同样检查） |
| 5 | `dart format lib test integration_test && flutter analyze && flutter test` | 格式化后 `git status` 无新增改动（CI 用 `--set-exit-if-changed` 检查）；无问题、测试通过（不需要动态库） |
| 6 | `pwsh -File scripts/integration-check.ps1 -Device windows` | 按 entry 独立启动桌面进程并隔离临时数据目录，真实加载 Rust 动态库；全部通过 |
| 7 | `flutter run -d windows` | 弹出窗口，样例页能显示 Rust 返回的内容 |

CI（`.github/workflows/ci.yml`）跑的就是这些步骤再加依赖治理；本表和 CI 不一致时以 CI 为准，并改本表。

## 已知坑

- **`pubspec.lock` 被改成镜像地址。** 开发机上 `flutter` / `dart` 的包装脚本若设置了 `PUB_HOSTED_URL`（比如指向清华镜像），
  凡是触发依赖重新解析的命令（`flutter pub get`、`flutter pub deps` 等）都会把 `pubspec.lock` 里所有 `url:` 从
  `https://pub.dev` 改写成镜像地址（版本号与 sha256 不变）。提交前先 `git diff pubspec.lock`，有改动就还原；
  发行构建按 `docs/REQUIREMENTS.md` §7.4 用官方 registry。`scripts/security-check.sh` 会检查，发现镜像地址直接判失败。
- **桥接端到端使用 `scripts/integration-check.ps1 -Device windows`。** 脚本为每个 entry 单独执行 `flutter test <entry> -d windows`，避免进程级 Rust 状态互相污染；不指定桌面设备会加载不到 Rust 动态库。
- **改了 `rust/src/api` 下的公开类型或函数后必须重新 `flutter_rust_bridge_codegen generate`**，生成物随改动一起提交，不手改。
- **codegen 版本必须是 2.13.0**，与运行时依赖同版本；安装时一定带 `--version 2.13.0`，不指定会装到最新版，生成物就和运行时对不上。

## 常用命令

```bash
flutter pub get
flutter_rust_bridge_codegen generate                        # 改 rust/src/api 后必须执行
cd rust && cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test
flutter analyze && flutter test
bash scripts/security-check.sh                              # 许可证/来源/重复依赖/公告，报告进 build/reports/
pwsh -File scripts/integration-check.ps1 -Device windows     # 逐 entry 隔离的桥接端到端
cd rust && sqlx migrate add -s <描述>                       # 新建迁移（引入 SQLx 后），必须带 -s 走顺序编号
flutter gen-l10n                                            # 改 ARB 后
flutter run -d windows
flutter build windows --release
```

`verify.ps1` 与 Windows CI 共用 `scripts/integration-check.ps1`；脚本按名称顺序运行
`integration_test/*_test.dart`，首个失败即停止，没有 entry 也判失败。每个 entry 使用新 GUID
临时目录和 ownership marker，不采用调用方已有的 `KEEL_DATA_DIR`；结束时先恢复
`KEEL_DATA_DIR` / `KEEL_FRB_TEST_TOKEN`，再校验归属、拒绝重解析点或符号链接并清理自建目录。
guard 失败时保留目录并报错，不强行删除；调用前的工作目录也会恢复。
Windows PowerShell 中也可直接运行 `.\scripts\integration-check.ps1 -Device windows`。
Linux 环境可用 `pwsh -File scripts/integration-check.ps1 -Device linux`，需先准备 Flutter、
原生构建工具、生成物和桌面显示环境。新增 `linux-desktop` CI 源码使用 Ubuntu 24.04，
复用固定 SHA Flutter Action 与全局 Flutter/FRB 版本；显式安装 clang/CMake/Ninja/pkg-config、
GTK3、C++/OpenSSL、Mesa、Xvfb/xauth、DBus 和 Noto 字体，检查 runner 自带 `pwsh`，缺失即失败。
按锁文件获取依赖、生成 FRB/l10n 后检查生成物与锁文件（含未跟踪文件），运行 Dart 门禁、
`flutter build linux --release --no-pub`，再经 Xvfb/DBus 运行现有隔离脚本 `-Device linux`，
结束后复查生成物和锁文件。`linux-rust` 保留 Rust 冒烟。
这些仅为 CI 源码，尚未执行；当前锁文件/生成物待同步的问题仍会阻断门禁，Linux 桌面测试、
原生交互、正式支持发行版与打包范围仍待目标环境验证。

`scripts/security-check.sh` 退出码：`0` 全部通过；`1` 存在违规或缺工具；`3` 无违规但 RustSec 公告库取不到
（本机网络受限），此时发布门禁不放行，须在能联网的 CI 重跑。

## 数据位置（已实现，待运行验证）

- 数据库、日志、备份、诊断包放系统应用数据目录：Windows `%APPDATA%\Keel\`，Linux `~/.local/share/keel`
- 程序安装目录只放只读资源，升级不覆盖用户数据。
- Linux 优先使用 `XDG_DATA_HOME/keel`；开发或测试可用绝对路径 `KEEL_DATA_DIR` 隔离数据。

## 当前交互

- 状态栏：显示备份操作/确认、诊断包处理、数据库重试、设置保存和配置导入的进行中数量，
  悬停可查看具体说明；切页仍显示未结束操作，空闲隐藏。窄窗口自动换行，新增行为待 Windows 验证。
- 诊断中心：输入完整诊断 ID 后搜索/Enter 精确匹配，可与最低级别组合；`Ctrl+F` 定位搜索，
  `F5` 保留已提交条件刷新，重置恢复全部级别和空 ID。查询仅覆盖本次运行保留的最多 500 条事件，
  最多显示 200 条匹配结果；新增查询 DTO 需重生桥接。
  事件旁的“复制诊断 ID”按钮只复制关联 ID，支持 Tab 聚焦后用 Enter/空格操作；
  复制失败显示安全提示，刷新或离开页面后不显示过期结果。新增交互仍待 Windows 验证。
- 审计日志：搜索按钮或 Enter 提交，重置恢复默认过滤与排序；点击时间/操作者/动作表头在 Rust 排序；
  刷新和错误重试、分页与页码、横向/纵向滚动。`Ctrl+F` 聚焦搜索，`F5` 刷新。
  当前页可单选行；表格焦点内用上下/Home/End 定位，`Esc` 清选，
  `Ctrl+C` 或“复制选中行”复制五列 TSV；新查询结果清选，搜索框保留文本复制行为。
  新增“导出筛选结果 CSV”，导出全部匹配记录而非当前页，提供进度、取消和失败后查询重试；
  原文件留在应用数据目录 `exports`；completed 后可通过 Win COM / Linux GTK
  `chooseAuditCsvSavePath` 另存 CSV 副本。Dart `auditCopyPickerProvider` / `auditCopyWriterProvider`
  与面板入口调用异步 Rust `save_audit_export_copy(task_id, destination) -> Result<String, ApiError>`，
  成功返回目标路径；只允许本人、有 `audit.export` 权限且终态未满 5 分钟的任务。
  选择器和复制全程 busy，保护关闭/可取消退出，返回后复查任务、身份和活动页。
  Rust 只接受本地绝对 CSV 路径，校验普通源文件、64 MiB 上限、源元数据/内容指纹及 Windows 句柄 file ID；
  指纹仅检测普通损坏，不是安全 hash。目标同目录唯一临时文件写完后 hard link 发布，禁止覆盖，
  不支持 hard link 时失败；拒绝预置链接/重解析点，但祖先目录恶意并发替换仍有 TOCTOU 边界。
  本轮无新依赖；上述接口、原生交互与后台实现仍待 FRB/l10n 生成、编译及两平台真实验证。
- 工作区：`Ctrl+W` 关闭当前标签，`Ctrl+Tab` / `Ctrl+Shift+Tab` 循环切换；
  关闭当前标签优先选右邻居，最右侧关闭后选左邻居。切换保留输入，关闭销毁页面状态。
- 导航：模块旁星标增删收藏，最近访问保留 10 项；收藏、最近访问和折叠状态保存到本地配置，
  保存失败可重试。重启只恢复导航入口，不恢复标签或未保存草稿。
- 页面快速搜索：`Ctrl+K` 或“窗口 → 打开页面”，按页面名称筛选，方向键选择、Enter 打开、
  Esc 取消。已打开页面直接激活；搜索范围为注册页面入口。
- 退出守卫（源码已接入，待验证）：`AppLifecycleListener.onExitRequested` 处理 Flutter 框架收到的
  可取消平台退出请求，先以 `canExit` 检查用户弹窗，再以 `canClose` 检查全部已打开工作区（含隐藏脏页）。
  与标签关闭共享锁防重入；确认期间不提前销毁页面，工作区标签快照变化即取消退出。
  提交 busy 或同草稿正在确认时拒绝关闭，避免重复确认；取消后可重新请求。
  无新依赖，未修改 native `SetQuitOnClose`；普通窗口叉号 / `Alt+F4` 的目标行为尚需 Windows 真机确认，
  强杀或不可取消退出不保障。手工验收见 [桌面退出清单](docs/DESKTOP_EXIT_CHECKS.md)。
- Windows Release 验收清单见 [WINDOWS_RELEASE_CHECKS.md](docs/WINDOWS_RELEASE_CHECKS.md)；
  覆盖候选证据、数据目录隔离、备份恢复、升级卸载和 Defender/签名记录，当前状态仍为未执行。
- 页面接入：当前 Fluent 外壳使用 `UiPage` 与 `KeelShell`；页面在 `app.dart` 的 `_pages` 中静态登记。
  页面操作、权限、关闭守卫与本地化接线见 [二开指南](docs/EXTENDING.md)；
  旧版 `WorkspacePage.commands` 不再是当前接入接口。
- 故障恢复：数据库启动失败显示可翻译摘要和诊断 ID，重试期间禁重复点击，成功后重载已打开查询。
  Rust 在用户和启动审计准备成功后才报告数据库可用。
- 外部配置导入的 Rust 核心确认写入会在设置锁内重新校验输入，只合并语言、主题、显示区域和导航，
  保留本机待写审计队列，并通过配置原子替换保存；文件读取只接受大小受限的普通文件并拒绝符号链接。
  Rust 预览缓存使用 5 分钟 TTL、最多 6 项并绑定当前用户，确认时一次性消费并重新校验。
  跨语言直接字节写入入口已删除，只保留准备快照与提交句柄两步；确认写入失败后须重新准备预览。
  预览和确认均要求 Rust `settings.import` 权限，viewer 不能修改本机配置。
  直接、文件和预览确认导入共用 `pending_settings_import_audit` 持久结果队列：
  成功事件与偏好同次 `config::save`，失败仅在本机配置健康、可写且有容量时入队，不改变原失败结果。
  与 `settings.change` 队列合计最多 200 条，满时先补写，仍满拒绝新变更/成功导入；
  配置仍为 v4，新增字段 serde 默认空，外部 pending 不采纳并保留本机队列。
  启动和后续保存按动作/事件 ID 幂等补写，核对完整记录检测 `RAISE(IGNORE)`，
  全部确认入库后才清队列；无池/补写或清理失败保留已落盘事件，不撤销已保存偏好。
  不记录输入或路径；不是配置/SQLite 跨存储事务，仅支持单进程写者，
  旧程序降级不保证保留新增队列。测试源码已补，尚未运行。
  导航的“导入设置”页已编写 JSON 文本入口：主动粘贴、受限 UTF-8 编码、脱敏预览、显式确认；
  预览成功清空原文本，确认前排空旧偏好保存队列，导入后只回读并应用语言、主题、显示区域与导航，不重新写盘。
  预览/导入期间禁用偏好修改，保护导入标签关闭及可取消退出；回读失败时继续暂停偏好写入，
  状态栏可重新打开导入页并仅重试读取，避免重放已消费的句柄。未确认的文本和快照不持久化。
  另有系统配置文件选择入口：Windows COM / Linux GTK 返回路径，Rust 限量读取后复用同一预览确认流程，
  Flutter 不读取文件内容。缓存/API/界面/原生实现均待生成、编译和平台真实运行；
  批量业务导入、跨配置/SQLite 事务仍未完成；系统另存副本目前仅接入审计 CSV。
- 设置：语言/主题/显示区域立即生效，文件写入串行执行；失败显示未保存提示并可重试。
  启动时读坏配置或更新版本配置会保护原文件，本次只临时切换设置，不允许重试覆盖。
  偏好与待写审计在 v4 配置中一同提交，数据库恢复后补写；v1–v3 可读取，保存后写 v4。
  “视图 → 显示区域”可选美国、英国、中国或跟随系统，独立于界面语言；
  审计/诊断/备份的日期、审计分页数字和备份大小使用此格式。系统中文映射中国、
  英国英语使用英国格式，其余系统区域回退美国格式；系统区域变化会更新跟随系统的显示。
  时区仍使用本机时区；货币和其他区域尚未接入。`Settings` 新增 nullable `formatLocale`，
  保存语言或主题时须保留该字段，null 表示恢复跟随系统；需重生 FRB 和本地化。
  配置兼容及补写边界见 [扩展指南](docs/EXTENDING.md)，新增测试仍待 Windows 执行。
- 表格仍为临时 `DataTable`，不代表 PlutoGrid POC、虚拟化或大数据量性能已通过。

## 当前状态

2026-11-01：阶段 0 骨架曾完成 Windows 验证，
同步字符串 / 同步结构体 / 异步结构体三类桥接在 `flutter test integration_test -d windows` 真实构建下通过；
`rust-toolchain.toml`、`Cargo.lock`、`pubspec.lock`、`THIRD_PARTY_NOTICES`、`rust/deny.toml`、
`scripts/security-check.sh`、`.gitattributes` 均已入库。

当前新增功能未编译，缺少新增依赖锁定和 FRB 再生成；先执行上面的 Windows 验证入口。
编写机可运行 `python3 scripts/check_sources.py --allow-pending-generation`，检查 ARB 键与占位符、
本地导入、直接依赖是否出现在锁文件，并列出待生成项；这不是编译或许可证扫描。去掉参数则待生成项也判失败。

未完项：CI（GitHub Actions）已配置——`.github/workflows/ci.yml` 在 PR 与 push main 上跑代码门禁，
外加依赖治理与密钥扫描；`dependabot.yml` 负责 cargo / pub / Actions 升级 PR。首次真实 runner 运行仍需观察。
`.github/workflows/release.yml` 已补由 `v*` 标签触发的 Windows 发布候选证据链，远端标签保护仍需配置，会生成候选包、
SHA-256、包含 Cargo/Dart 依赖组件的 SPDX 文件清单、构建元数据与安全报告，且证据目录随 ZIP 打包，
但尚未在真实 runner 执行。
签名、attestation、安装器、Defender 和干净环境发布验收仍属阶段 4 后续门禁；数据库实际运行验证与网格 POC 属阶段 2；
表单、导入导出、任务取消及更多页面命令仍待补齐。按需求逐项的源码进度与缺口见需求文档 §10.1。

## 许可

MIT，见 [LICENSE](LICENSE)。第三方依赖许可与随包文件见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) §7。
