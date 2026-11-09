# Windows Release 验收清单

状态：未执行。本文是 Release 产物的人工验收入口，不代表当前源码、CI 或发布候选已经通过 Windows 验证。

## 记录信息

- [ ] 记录版本标签、commit SHA、构建工作流运行编号和候选包 SHA-256。
- [ ] 记录 Windows 版本、架构、Flutter/Rust/codegen 版本、验收日期和验收人。
- [ ] 使用干净的普通用户环境；不要关闭 Defender、SmartScreen 或防火墙。
- [ ] 每次失败保留步骤、实际结果、日志路径、文件 SHA-256 和是否可复现。
- [ ] 将通过、失败、未覆盖分开记录；未执行项不能记为通过。

## 产物和证据

- [ ] 候选 ZIP 只来自受保护 `v*` 标签工作流，未使用开发机本地构建目录。
- [ ] ZIP 包含应用可执行文件、DLL、`data` 目录、`LICENSE`、`THIRD_PARTY_NOTICES`、`CHANGELOG.md`。
- [ ] `data/flutter_assets/NOTICES.Z` 存在且可由 Flutter 运行时读取。
- [ ] ZIP 内包含 `evidence/SHA256SUMS`、`evidence/SBOM.spdx.json` 和 `evidence/build-info.json`。
- [ ] `SHA256SUMS` 中的路径和 SHA-256 与候选目录逐项匹配。
- [ ] SPDX 文件清单包含应用文件、Cargo 组件和 Dart/Flutter 组件；许可证未知项保留人工复核状态。
- [ ] `build-info.json` 中的 commit、锁文件哈希、工具链和工作流与实际运行记录一致。
- [ ] 安全报告包含 cargo-deny、cargo-audit、OSV 和 secret scanning 结果；公告库不可用时不得放行。

## 干净环境首次启动

- [ ] 从候选 ZIP 解压到包含空格和非 ASCII 字符的安装路径。
- [ ] 以普通用户启动，窗口、菜单、导航、工作区和桥接样例正常显示。
- [ ] 首次启动在安装目录外创建 `%APPDATA%\Keel` 数据目录。
- [ ] 数据库、配置、日志、备份和诊断导出均不写入安装目录。
- [ ] 首次启动成功完成数据库初始化和迁移；失败时只显示安全摘要、错误码和诊断 ID。
- [ ] 设置语言/主题后重启，设置仍存在且配置文件可安全替换。
- [ ] 中英文切换、日期/数字格式、窗口缩放和键盘焦点正常。

## 数据与文件边界

- [ ] 在配置、数据库、日志和备份路径中分别测试空格、Unicode、非 ASCII 用户名。
- [ ] 打开配置文件或数据库文件时模拟占用，应用显示可操作错误，不覆盖原文件。
- [ ] 预置配置临时文件、正式配置 marker、恢复临时数据库的符号链接，确认不会写入链接目标。
- [ ] 创建、登记、取消和恢复备份；恢复前确认提示正确，取消后实际状态重新读取。
- [ ] 恢复失败时旧数据库仍可启动，旧数据库和恢复临时文件按文档策略保留或清理。
- [ ] 迁移失败时迁移前备份可找到，备份清理不删除其他数据库文件或目录。
- [ ] 诊断包预览后再导出；检查密码、Token、完整连接串、用户路径和业务内容未直接暴露。

## 安装、升级和卸载

- [ ] 记录当前项目使用的目录式 ZIP 或安装器方案；未实现的安装器不得标为通过。
- [ ] 在干净环境运行候选版本并退出，确认没有残留 Keel 进程。
- [ ] 使用新版本覆盖或安装升级，确认用户数据库、配置、日志和备份仍可读取。
- [ ] 执行数据库迁移后核对 schema 版本、关键记录、唯一约束和审计记录。
- [ ] 卸载程序文件后确认用户数据目录没有被误删。
- [ ] 重装后应用能读取保留的数据，并能重新创建缺失的缓存或日志目录。
- [ ] Defender 扫描记录日期、引擎版本、扫描范围、结果和候选包 SHA-256。
- [ ] 若启用 Authenticode，逐个验证 `.exe`、`.dll` 和安装器的签名与时间戳。

## 交付结论

- 结论：待填写。
- 阻断问题：
- 未覆盖项目：
- 复测计划：
- 签名、attestation、Defender、安装器和正式发布是否独立放行：

---

# Windows 全面测试计划

## 1. 测试目标和结果语义

本文是交给 Windows 测试执行者或测试 AI 的完整执行清单。它覆盖依赖解析、代码生成、编译、真实 FRB、SQLite、桌面 UI、文件系统安全、性能、网格和 Release 验收。

每项必须使用以下状态之一：

- `PASS`：已在真实 Windows 环境执行并满足验收标准。
- `FAIL`：已执行但结果不符合预期。
- `NOT_EXECUTED`：没有执行，不能推断结果。
- `BLOCKED`：因工具、权限、依赖、环境或代码问题无法执行。
- `NOT_COVERED`：当前测试范围没有覆盖。

以下内容不能替代真实 Windows 证据：

- 源码中存在相关实现。
- Python 静态检查或 SQLite POC 通过。
- Mock、fake、widget test 或手写 FRB contract test 通过。
- 窗口消失但未确认进程退出。
- Debug 构建通过但没有 Release 证据。
- 单一分辨率、DPI、语言或用户权限下的结果。
- 尚未执行的测试。

## 2. 测试前禁止事项

- 不得手工修改 `lib/src/rust/**`、`rust/src/frb_generated.rs` 或 `lib/l10n/app_localizations*.dart`。
- 生成区必须通过官方生成命令更新。
- 不得用 mock 替代真实 Rust、SQLite、FRB 或 Windows 原生文件选择器。
- 不得关闭 Defender、SmartScreen、防火墙或其他安全保护。
- 不得使用用户已有的 `KEEL_DATA_DIR`，每个测试必须使用独立临时目录。
- 不得把日志中的用户名、个人路径、token、密钥或环境变量写入最终报告。
- 不得把 `NOT_EXECUTED`、`BLOCKED` 或 `NOT_COVERED` 标为通过。

## 3. 测试环境记录

测试开始前记录：

- Windows 版本和 Build。
- x64 架构。
- CPU、内存、磁盘类型。
- 显示器分辨率和缩放比例。
- 系统语言、区域和键盘布局。
- 当前用户名及是否管理员。
- Defender 和 SmartScreen 状态。
- Git commit、分支或标签。
- Flutter、Dart、Rust、FRB codegen 版本。
- 测试日期、测试执行人、测试工具名称。

必须安装或可调用：

- Windows 10/11 x64。
- Visual Studio 2022 Build Tools。
- `Desktop development with C++` 工作负载。
- Windows SDK。
- Flutter stable。
- Dart。
- Rust stable MSVC toolchain。
- Git Bash。
- PowerShell 或 `pwsh`。
- `flutter_rust_bridge_codegen` 2.13.0。
- `cargo-license`、`cargo-deny`、`cargo-audit`。

执行并保存：

```powershell
flutter doctor -v
flutter --version
dart --version
rustc --version
cargo --version
rustup show
flutter_rust_bridge_codegen --version
cargo-license --version
cargo-deny --version
cargo-audit --version
pwsh --version
git --version
```

## 4. 依赖解析、锁文件和代码生成

在仓库根目录执行：

```powershell
.\scripts\verify.ps1 -ResolveDependencies
```

确认：

- `PUB_HOSTED_URL` 为 `https://pub.dev`，或有明确批准的来源记录。
- `pubspec.lock` 没有被镜像地址意外改写。
- `rust/Cargo.lock` 已更新并包含新增依赖。
- 新增 Dart、Flutter、Rust 依赖均已锁定。
- 依赖许可证、来源、重复依赖和公告状态已检查。
- 依赖解析失败时没有继续伪造后续通过。

必要时单独执行：

```powershell
flutter pub get
cd rust
cargo fetch --locked
cd ..
flutter gen-l10n
flutter_rust_bridge_codegen generate
dart format lib test integration_test
cargo fmt --all
```

生成检查：

- l10n 生成文件包含当前中英文 ARB 资源。
- FRB 生成文件与当前 Rust API 一致。
- 生成区没有手工修改。
- 生成命令退出码为 0。
- 第一次生成后的差异已保存。
- 第二次生成不会产生非预期差异。

如果生成失败，记录命令、退出码、完整错误、缺失工具和对后续测试的影响。

## 5. Rust、Dart 和 Flutter 基础门禁

执行：

```powershell
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
flutter analyze
flutter test
```

所有 warning 在 clippy 的 `-D warnings` 下都视为失败。分别记录：

- cargo fmt。
- cargo clippy。
- cargo test。
- flutter analyze。
- flutter test。

## 6. 真实 Windows FRB 集成测试

执行：

```powershell
pwsh -File scripts/integration-check.ps1 -Device windows
```

确认脚本：

- 每个 `integration_test/*_test.dart` 在独立 Flutter 进程中运行。
- 每个测试使用独立 GUID 临时目录。
- 设置 `KEEL_DATA_DIR` 和 `KEEL_FRB_TEST_TOKEN`。
- 创建 `.keel-frb-test-owner`。
- 测试结束后恢复原有环境变量。
- 清理前检查 symlink 和 reparse point。
- 清理前验证 ownership。
- guard 失败时保留目录，不强制删除。
- 每个测试单独保存日志和退出码。
- 没有测试 entry 时应失败。

真实 FRB 初始化至少验证：

- `RustLib.init()` 成功。
- `app.initDatabase()` 成功。
- SQLite 创建和迁移成功。
- 重复初始化不会破坏数据库。
- 数据只写入当前独立 `KEEL_DATA_DIR`。
- 数据库锁和连接最终释放。
- 迁移失败返回稳定错误码，不静默覆盖数据库。

## 7. 用户、身份和权限矩阵

至少测试：

- `viewer`。
- 具备审计读取权限的用户。
- 具备 `audit.export` 权限的用户。
- 具备配置导入权限的用户。
- 具备备份和恢复权限的用户。
- 不同角色组合。
- 同一进程中的用户切换。

验证：

- 权限不足时返回稳定错误。
- 权限优先顺序正确。
- 用户切换后旧回调不能修改新用户状态。
- 任务列表不泄露其他用户任务。
- 按任务 ID 重新查询时重新验证所有者、完整身份和权限。
- 配置预览句柄绑定当前用户和角色。
- 身份变化后旧句柄不能消费。
- 备份和恢复不能使用过期权限。

## 8. 审计日期范围、列表和 COUNT

日期契约：

- `start_at_ms` 包含。
- `end_at_ms_exclusive` 排除。
- Rust 使用 UTC epoch milliseconds。
- Flutter 使用本地日历日期转换为下一本地日午夜。
- 不得固定增加 24 小时计算结束时间。

建立边界数据：

- 起始时间之前。
- 起始时间恰好。
- 区间中间。
- 结束时间之前。
- 结束时间恰好。
- 结束时间之后。
- UTC 跨日。
- 夏令时变化日期（环境支持时）。
- 空区间。
- 大量记录。

确认列表、COUNT 和 CSV 使用一致的过滤条件：

- 起始边界包含。
- 结束边界排除。
- 排序稳定。
- 分页没有重复和遗漏。
- 关键词过滤和分页组合正确。
- Unicode 关键词正常。
- 非法范围返回稳定错误。
- 列表数量等于 COUNT。
- CSV 数据行数量等于 COUNT。

## 9. 审计 CSV 导出和任务生命周期

固定字段：

```text
id, at_utc_ms, actor, action, target, result
```

验证：

- UTF-8 BOM。
- CRLF。
- CSV 引号转义。
- 换行字段不会破坏结构。
- 公式前缀防护。
- 100,000 行上限。
- 64 MiB 上限。
- 最多 6 个后台任务。
- 每用户最多一个 running 任务。
- 任务进度不倒退。
- running、completed、failed、cancelled 状态正确。
- running 任务可取消。
- 取消后资源释放。
- 终态 TTL 为 5 分钟。
- 查询任务列表不会延长 TTL。
- 未知阶段按 busy 处理。
- 未知阶段允许人工 refresh。
- 未知阶段不能自动取消。
- 只有 running 阶段发送 cancel。
- 导出期间关闭窗口受到保护。
- 身份变化后旧回调不能更新新用户。
- dispose 时 running 任务会尽力取消。
- 导出不阻塞 UI。

至少执行：

- 空结果。
- 单条记录。
- 包含逗号、引号、换行和 Unicode。
- 包含公式前缀。
- 大量记录。
- 导出中取消。
- 导出中切换用户。
- 导出中关闭页面。
- 导出中关闭窗口。
- 任务进入终态后等待 TTL。
- 未知任务阶段。
- 同一用户重复启动。
- 不同用户并行启动。
- 权限撤销后重新查询。
- 数据库锁定。
- 磁盘空间不足。
- 输出目录不可写。

## 10. CSV 另存副本和 Windows 文件系统安全

验证：

- 只能保存本人 completed 任务。
- 终态超过 5 分钟时拒绝保存。
- 只接受本地绝对 CSV 路径。
- 相对路径被拒绝。
- 已有目标不能覆盖。
- 使用同目录唯一临时文件。
- 发布使用 hard link。
- 发布失败清理临时文件。
- symlink 和 reparse point 被拒绝。
- Windows 文件 ID 检查符合预期。
- 文件锁返回明确错误。
- 文件句柄最终关闭。
- 取消后不会留下可误用临时文件。
- 目标路径包含空格和非 ASCII 时正常。
- 只读目标、被占用目标和恶意并发替换均有明确结果。

必须测试路径：

```text
C:\Temp\Keel Test\导出结果.csv
```

同时测试：

- 已存在目标。
- 只读目标。
- 被其他进程打开的目标。
- symlink 目录。
- reparse point 目录。
- 非 ASCII 目录。
- 长路径。
- Windows 保留设备名。

## 11. 配置导入和导入审计

输入限制：

- UTF-8。
- JSON。
- 最大 1 MiB。
- 只允许 `language`、`theme`、`format_locale`、`navigation`。
- 类型错误、非法编码、超限输入和不支持版本被拒绝。
- 未知字段和重复字段行为符合契约。
- 控制字符不能绕过校验。

预览句柄：

- 5 分钟有效。
- 最多 6 项。
- 一次性消费。
- 绑定当前用户和角色。
- 身份变化后不可消费。
- 配置源文件变化后不能错误导入旧内容。
- 确认时重新校验权限和完整身份。
- 重复消费和过期消费返回稳定错误。

配置保存和审计：

- 成功导入和允许偏好在同一次 `config::save` 中完成。
- 保存失败不覆盖旧配置。
- `settings.import` 和 `settings.change` 分开记录。
- 记录稳定错误码、操作者、时间、事件 ID 或关联 ID。
- 失败事件仅在配置健康、可写且队列有容量时入队。
- `RAISE(IGNORE)` 不能直接视为成功。
- 必须查询完整记录确认是否入库。
- 重复补写不产生重复记录。
- 补写保留原时间、操作者、动作、目标、结果和关联 ID。
- 既有记录 ID 不改变。
- 清队列不改变偏好。
- 明确记录这不是配置文件和 SQLite 的跨存储事务。

## 12. Windows 原生文件选择器

配置导入选择器和审计 CSV 保存选择器分别验证：

- 可以打开原生选择器。
- 文件过滤器正确。
- 取消返回可识别取消状态。
- 不存在文件、目录、symlink、reparse point 被正确处理。
- 空格、中文、非 ASCII 和长路径行为正确。
- 选择器期间应用保持 busy。
- 选择器关闭后 busy 恢复。
- 选择器期间关闭窗口受到保护。
- 取消后可以再次打开。
- 文件句柄关闭。
- 原生异常不会导致应用崩溃。
- 选择器失败不会伪造导入或导出成功。

## 13. 备份、恢复和迁移

验证：

- 备份和恢复权限。
- 备份临时文件唯一。
- 备份发布安全。
- 备份中途取消。
- 备份中途关闭窗口。
- 备份 busy 和退出保护。
- 恢复前二次确认。
- 恢复过程原子性。
- 恢复失败时旧数据库仍可用。
- 锁定数据库时返回明确错误。
- 坏备份不会覆盖当前数据库。
- 迁移失败可识别。
- 启动可以恢复未完成状态。
- 恢复后数据和审计记录完整。
- 所有数据库连接最终释放。

## 14. 诊断和历史日志

内存事件：

- 最近事件最多 500 条。
- 超限淘汰规则正确。
- 事件写入时已经脱敏。
- 诊断包不包含 token、密码、密钥、完整连接串或不必要个人路径。

历史日志检索：

- 授权后才能检索。
- 身份加载后才开始扫描。
- 扫描后再次复查完整身份。
- 固定应用 `logs` 目录。
- 合法每日文件名。
- 拒绝 symlink 和 reparse point。
- 最多 256 个目录项。
- 最多扫描 14 个文件。
- 最多读取 4 MiB。
- 最多返回 200 行。
- 输入行最多 8192 bytes。
- 输出最多 2048 Unicode scalars。
- 完整行脱敏后再进行字面匹配。
- 控制字符和恶意查询输入被拒绝。
- 无权限时不泄露文件存在性。
- 第 257 个目录项不会被取出或处理。
- 0、255、256、257 项边界均执行。

## 15. UI、快捷键、表单和焦点

验证菜单、工具栏、导航、工作区标签、状态栏、错误、空状态、加载状态、用户切换和权限刷新。

快捷键：

```text
Ctrl+K
Ctrl+Tab
Ctrl+Shift+Tab
Ctrl+W
F5
Ctrl+F
Ctrl+S
```

每个快捷键分别记录触发位置、预期行为、实际行为、输入冲突、系统冲突和结果。

焦点验证：

- 初始焦点正确。
- Tab 和 Shift+Tab 顺序合理。
- 校验失败后聚焦错误控件。
- 弹窗打开后焦点不泄露。
- 弹窗关闭后焦点恢复。
- 复制、粘贴和键盘导航正常。
- 屏幕阅读器可以识别关键控件。
- 高对比度下文字和边框可见。

表单至少覆盖：

- Unicode 用户名。
- 角色选择。
- 必填字段。
- 错误摘要和错误聚焦。
- 脏草稿和关闭保护。
- int32 边界。
- 日期和日期时间。
- 精确最小货币单位。
- 枚举选择器。
- 长表单滚动。
- 本地时间和 UTC 预览。
- 中英文资源和 placeholder。

本地 form sample 通过不代表真实业务保存、Rust 业务校验、全局时区、货币设置或 RTL 已完成。

## 16. 桌面退出和关闭保护

逐项执行：

```text
docs/DESKTOP_EXIT_CHECKS.md
```

普通窗口叉号和 Alt+F4 必须分开记录。

至少覆盖：

- 无草稿退出。
- 可见 dirty 页面。
- 隐藏 dirty 页面。
- 弹窗 dirty 状态。
- 提交 busy。
- 诊断包 busy。
- 备份 busy。
- 恢复确认。
- 取消后重试。
- 多草稿全部允许。
- 多草稿后项拒绝。
- 重复退出。
- 标签关闭和窗口退出竞态。
- 标签快照变化。
- 确认期间草稿变化。
- 用户切换。
- busy 结束后重试。

退出后必须检查：

- Keel 进程已退出。
- 子进程已退出。
- 关键文件句柄已释放。
- 数据库锁已释放。
- 没有异常临时文件。

不能以“窗口消失”作为进程退出证据。

## 17. DPI、分辨率和辅助功能

至少测试：

- 100%、125%、150%、200% 缩放。
- 1920x1080、2560x1440、4K。
- 多显示器和跨显示器移动。
- 高对比度。
- Windows 深色和浅色模式。
- 大字体。
- 中英文系统区域。
- Unicode 用户名和路径。

检查：

- 文本不截断。
- 按钮不重叠。
- 表格可读。
- 弹窗不超出屏幕。
- 键盘焦点可见。
- Tooltip 不被裁剪。
- 最小窗口尺寸可用。
- 最大化、还原和 DPI 变化正常。

## 18. 网格 POC 和真实 UI

先执行 SQLite 查询层：

```powershell
python scripts/grid_poc.py --output build/reports/grid-poc-sqlite.json
```

至少使用 10,000、100,000、1,000,000 行。

SQLite POC 只能证明查询层，不能证明 Flutter 渲染、虚拟化、滚动、键盘、剪贴板、列配置、编辑、内存或生命周期。

真实 UI 必须另外验证：

- 固定列。
- 列宽调整。
- 列显示、隐藏和排序。
- 多选。
- 单元格复制。
- 范围复制。
- 粘贴到外部文本编辑器。
- Home、End、PageUp、PageDown。
- Ctrl+Home、Ctrl+End。
- 搜索定位。
- 横向和纵向滚动。
- 单元格编辑和取消编辑。
- 批量操作。
- 10k、100k、1m 行。
- 内存增长。
- 页面关闭后的资源释放。
- Windows Release 模式。
- 多 DPI。

如果采用 PlutoGrid 或其他第三方网格，还要记录版本、lock 文件、许可证、传递依赖、Windows 结果、Linux 结果和已知限制。不能通过自研完整 DataGrid 引擎规避网格准入要求。

## 19. 性能和生命周期

记录冷启动、热启动、数据库初始化、页面切换、列表首屏、分页、搜索、导出启动、取消响应、配置导入、备份、恢复、历史日志扫描、网格首屏和退出释放时间。

至少记录：

- 最小值。
- 最大值。
- 平均值。
- 异常值。
- 冷缓存或热缓存。
- CPU 峰值。
- 内存峰值。
- 测试数据量。

没有正式阈值时必须填写实测数据，不能写“性能正常”。

## 20. Release、干净用户和升级

执行：

```powershell
.\scripts\verify.ps1 -BuildRelease
```

继续执行本文前面的 Release 验收清单。

干净普通用户环境必须验证：

- 从候选 ZIP 解压。
- 使用包含空格和非 ASCII 的路径。
- 不安装开发工具链。
- 不使用管理员权限。
- 启动、初始化数据库、创建用户。
- 配置导入。
- CSV 导出。
- 备份和恢复。
- 诊断查看。
- 正常退出。
- 数据位于 `%APPDATA%\Keel`。

升级、卸载、重装必须验证：

- 旧版本数据迁移。
- schema 版本。
- 关键记录和审计记录。
- 用户数据是否按约定保留。
- 卸载后无残留 Keel 进程。
- 重装后可读取保留数据。
- 缓存和日志目录可以重新创建。

签名、attestation、Defender、SmartScreen、安装器和正式发布必须单独给出结论，不能因为 ZIP 能运行就合并判定通过。

## 21. 统一证据目录和结果模板

建议使用：

```text
build/reports/windows/<run-id>/
```

至少保存：

- `environment.txt`
- `versions.txt`
- `verify-output.txt`
- 依赖解析日志
- 代码生成日志
- cargo fmt、clippy、test 日志
- flutter analyze、test 日志
- integration-check 日志
- 每个集成测试独立日志
- 截图和录屏索引
- ZIP、SHA256SUMS、SBOM、build-info
- 许可证和安全扫描报告
- 性能数据
- 网格 POC JSON
- 退出测试记录
- 失败复现步骤
- 阻断问题清单

每项测试使用以下格式：

```text
测试编号：
测试名称：
前置条件：
Windows 版本：
Flutter/Dart/Rust/FRB 版本：
Git commit 或标签：
执行命令：
预期结果：
实际结果：
状态：PASS / FAIL / NOT_EXECUTED / BLOCKED / NOT_COVERED
退出码：
日志路径：
截图路径：
SHA-256：
是否可复现：
阻断原因：
关联问题：
复测计划：
```

## 22. 发布阻断条件

以下任一项存在时，不得宣布 Windows 全面验收通过：

- 生成失败或生成区不一致。
- FRB 版本不匹配。
- 锁文件不可复现。
- Rust、Flutter 或 Dart 基础门禁失败。
- 真实 FRB 集成测试未执行或失败。
- Windows 原生文件选择器未执行或失败。
- 退出保护未完整执行。
- 进程、数据库锁或文件句柄残留。
- 数据目录隔离失败。
- symlink 或 reparse point 可绕过安全检查。
- 已有导出目标被覆盖。
- 任务所有者、权限或 TTL 检查失败。
- 配置预览句柄可重复消费。
- 身份变化后旧回调仍能修改状态。
- 数据库迁移失败导致数据丢失。
- Release ZIP 缺文件或哈希不一致。
- SBOM、构建信息或安全报告缺失。
- 签名、Defender 或 attestation 未执行且被错误标为通过。
- 只验证 SQLite 网格 POC，没有真实 Flutter UI 证据。
- 只验证 Debug，没有 Release 证据。

最终结论必须分别写明：

- 已通过项目。
- 已失败项目。
- 未执行项目。
- 被阻断项目。
- 未覆盖项目。
- 发布前阻断项。
- 复测计划。
- 是否可进入内部测试。
- 是否可生成 Release 候选。
- 是否可进入发布审批。
- 是否可正式发布。
