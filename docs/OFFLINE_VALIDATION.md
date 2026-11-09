# 本轮离线实施与验证记录

当前结论以最新对应批次和当前副本实测为准；此前章节是前序快照，保留其当时命令与退出码，不能覆盖当前状态。当前 `python3 -B scripts/check_sources.py` 因 l10n/FRB 生成项缺失退出 1；它是源码/资源/引用门禁，不是编译器或测试运行器。

## 2026-11-04 第二批：诊断、fixture、打印与当前活动

实际新增外部诊断完整文本筛查与快照准备内部核心、隔离SQLite编辑/JSONL导入fixture、
Windows/Linux打印适配及手写Dart通道、六类当前活动明细和定位。
Rust fixture 12项、Dart打印7项以及活动8项新增回归均仅为测试源码，未执行。
外部诊断和fixture尚无公开API/FRB/UI入口；打印尚无完整预览、授权复查或busy界面接线。
不把内部模块和方法通道存在记为完整功能交付。

本批实际重跑：

| 命令 | 退出码 | 结果 |
|---|---:|---|
| `python3 -B -m unittest discover -s scripts/tests -v` | 0 | 42项，1.511秒，全部通过；原有脚本fixture/stub回归，不覆盖新增Rust/Dart/native |
| `python3 -B scripts/check_sources.py` | 0（历史快照） | 当时仅通过有限资源/导入/锁文件检查；不代表当前状态、生成一致性或编译检查 |
| `bash -n scripts/security-check.sh` | 0 | Shell语法通过 |

新增中英文打印6键和currentActivitiesScope尚未正常生成，未修改生成Dart；
因此 G02 仍存在待生成工作；即使历史快照中的 check_sources 返回 PASS，也不能关闭当前生成门禁。
本机仍无可用Flutter/Dart/Cargo和匹配的原生桌面构建环境，未重跑平台编译或真实打印。
已确认的Windows构建基线只覆盖此前版本。

实现后独立复核发现并实际修复：外部诊断共享分类函数的crate可见性；
fixture服务SQL委托给data层且集成测试包含同一data源码；未接产品入口的内部模块仅局部
豁免dead_code（fixture库测试目标同样没有调用方）；审计范围说明移至审计面板；
Windows清除旧last-error后捕获StartDoc明确取消；Linux仅渲染完整content，
window_removed提前取消打印和瞬态对话框，shutdown保留兜底。
这些是源码修复，未作为Rust/native编译或运行通过记录。
最终两路独立只读复核针对已落盘文件完成：Rust可见性、共享data测试接线、局部dead_code及SQL分层，
原生取消/正文一致性、提前退出清理、对象与信号生命周期均未发现明确阻断。
该复核不能替代编译；原生复核确认本机pkg-config缺少gtk+-3.0及pangocairo。

本记录只覆盖文档、Python SQLite 合成基准、发布证据完整性和安全扫描控制流。测试使用 Python 标准库、自动清理的临时 SQLite/发行文件 fixture 和本地工具 stub；未运行真实安全扫描、默认大规模基准或桌面工具链。本地副本无 Git 元数据，本记录不证明提交来源。

## 修改文件

- 文档：`GRID_POC_REPORT_TEMPLATE.md`（新增，默认 NOT RUN）、`GRID_POC.md`、`IMPLEMENTATION_STATUS.md`、`REQUIREMENTS.md`、本记录。
- 发布：`scripts/release_evidence.py`、新增 `scripts/verify_release_evidence.py`、`scripts/tests/test_release_evidence.py`。
- 基准：`scripts/grid_poc.py`、新增 `scripts/tests/test_grid_poc.py`。
- 扫描：`scripts/security-check.sh`、新增 `scripts/security_check.py`、`scripts/tests/test_security_check.py`。

AGENTS.md 的模板链接经核对已因补齐模板而成立，无须修改。未修改 Rust/Dart/Flutter、生成物、锁文件、依赖或工作流。

## 主实现阶段离线命令（复核后的结果见文末）

从仓库根执行：

| 命令 | 退出码 | 结果 |
|---|---|---|
| `python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 0 | 最终 22 项全部通过（0.753 秒）；覆盖本批三个测试模块 |
| `bash -n scripts/security-check.sh` | 0 | Shell 语法通过 |
| `test -s docs/GRID_POC_REPORT_TEMPLATE.md` | 0 | 模板存在且非空 |
| `python3 -B scripts/check_sources.py` | 1 | 实施前后相同的 17 项 PENDING，无新增，未放宽规则 |

17 项具体基线：Dart 直接依赖 `flutter_localizations`、`flutter_riverpod`、`intl` 未入锁；Rust 直接依赖 `serde`、`serde_json`、`sqlx`、`tracing`、`tracing-appender`、`tracing-subscriber` 未入锁；缺少 `lib/l10n/app_localizations.dart`；缺少 `lib/src/rust/api/` 下 `app.dart`、`audit.dart`、`backup.dart`、`diagnostics.dart`、`error.dart`、`settings.dart`、`users.dart`。源码检查不是编译器，17 项不涵盖所有跨层契约缺口。

## 发布证据入口和边界

以下为使用示例，未对真实发行物执行。必须从仓库根运行，锁文件与 rust-toolchain.toml 从当前目录读取。先完成适用的签名，冻结发行载荷，再生成证据：

```bash
python3 -B scripts/release_evidence.py --root /path/to/release --output /path/to/release/evidence --version VERSION --commit COMMIT --cargo-metadata /path/to/cargo.json --dart-deps /path/to/dart.json
python3 -B scripts/verify_release_evidence.py --root /path/to/release
python3 -B scripts/verify_release_evidence.py --root /path/to/release --strict
```

可用 `--scan-summary /path/to/summary.json` 绑定现有扫描摘要哈希；这只绑定字节，不判定扫描通过。运行信息来自 GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT/GITHUB_SERVER_URL/GITHUB_REPOSITORY/RUNNER_NAME/KEEL_TARGET_ARCH，缺失如实写 unavailable。扫描数据库版本仍为 unavailable，因此当前默认生成物不能通过严格元数据检查，不能手填虚构值放行。

载荷 SHA256SUMS 覆盖全部普通文件（含隐藏文件），排除 evidence 子树；EVIDENCE_SHA256SUMS 覆盖另外三份证据，排除自身。拒绝链接、不安全路径（含 Windows 设备名/非法字符）和规范化冲突；重复生成不把旧证据混入载荷。文件应保持静止，未承诺抵御恶意并发路径替换。SBOM 是构建依赖 inventory，filesAnalyzed=false；NOASSERTION 仍需许可复核，固定 epoch creationInfo 不代表实际构建时间。正式 SPDX schema/完整语义、发行依赖范围及来源认证未完成。

完成压缩后，在 ZIP 外写摘要并校验：

```bash
python3 -B scripts/release_evidence.py --hash-zip /path/to/release.zip
python3 -B scripts/verify_release_evidence.py --zip /path/to/release.zip
```

ZIP 校验先比较外部 sidecar 与归档字节，再检查内部条目并在私有临时目录逐文件流式暂存，
复用目录验证器核对载荷、证据清单和 SPDX 文件覆盖/哈希；结束或失败后清理暂存目录。
拒绝路径穿越、绝对路径、重复/大小写/Unicode 规范化冲突、文件目录冲突、链接/特殊文件和加密条目；
上限为 10,000 个文件、单文件展开 1 GiB、总展开 4 GiB，暂存前检查清单，读取时复查声明长度。
不使用 extractall，不执行包内程序。摘要和内部自洽检查不提供可信签名或来源证明，
攻击者同步改写载荷与所有证据仍需独立的可信发布摘要/签名防御。
--strict 仍必须同时指定 --root，ZIP 内容校验不替代严格扫描、签名或来源认证门禁。

2026-11-05 本轮执行 `python3 -B -m unittest discover -s scripts/tests -v`：47 项通过。
新增回归覆盖载荷/证据被篡改且外部摘要同步重算、危险条目及清单资源上限；原有完整候选打包与
工作流命令回归继续通过。该结果仅覆盖 Python 脚本契约，不代表真实候选发布或平台验收通过。

## 基准契约

保留 synthetic-grid-poc，增加重复原始样本和 min/median/max/mean、COUNT 实值、环境元数据及计时外结果校验。new-connection 每样本新连接；warm 每查询同连接先执行一次不计时。两者均未控制 OS 缓存。小规模测试验证过滤、完整行值、稳定排序、尾页和越界页，并拒绝损坏数据。未生成工作区数据库或性能报告，不代表真实 audit_log 或 Rust/FRB/Flutter 性能。

## 扫描入口和边界

`verify.ps1 -Security` 和 `-ResolveDependencies` 现在把安全脚本以 `--strict` 调用；缺工具、失败、部分结果或 unknown 数据库版本均阻断后续编译。普通 `security-check.sh` 本地模式仍允许明确标记为 SKIP 的可选扫描，但其 `LOCAL_INCOMPLETE` 不能作为发布通过。

`bash scripts/security-check.sh` 为普通本地模式；`bash scripts/security-check.sh --strict` 要求全部工具存在且检查状态 PASS，并要求 audit/deny-advisories/OSV 的公告库版本已知；缺工具/失败退出 1，未知或部分结果退出 3。当前未实现公告库版本提取，因此即使所有工具退出 0，严格模式仍返回 3、UNKNOWN/INCOMPLETE，不能放行。普通模式允许 OSV/gitleaks 缺失时 SKIP、退出 0，但摘要为 LOCAL_INCOMPLETE，不能据退出 0 当成完整扫描。

每次实际扫描写入独立 `build/reports/security-*/`，输出 summary.json 路径；失败日志保留，audit 离线 fallback 另存，不覆盖原失败。记录工具版本、起止时间、退出码、报告哈希、可用 commit 和 KEEL_CANDIDATE_SHA256。数据库版本当前记录 unknown；普通模式的工具退出成功只表示本地控制流成功，严格模式按未知结果阻断。真实工具 CLI、Windows/Git Bash 兼容、公告库版本/时间提取及真实扫描待验证。

历史快照（2026-11-04 前）：报告目录结构改变时，CI/release 的上传路径、失败时 always 上传和严格模式尚未接线。当前 YAML 已补齐这些源码接线；尚未取得的是远端 Actions、真实扫描和目标平台的实际运行证据。不得根据 stub 测试填写真扫描或目标平台通过。

## 保持开放的阻塞

- P1 日期过滤：Dart 侧已有字段，Rust API/data/共享 SQL 缺少时间契约；重新生成不能修复，列表/COUNT/导出需一并补齐并跑真 SQLite/FRB 测试。
- G01–G03：依赖锁定/许可复核、FRB/l10n 正常生成、编译与真实集成。未运行 cargo fmt/clippy/test、flutter analyze/test，当前限定环境与本轮范围仅支持离线脚本验证。
- 网格固定列/列配置/多选/独立编辑样例、类型输入/多字段长表单、本人内存任务列表仍待实现；持久历史和跨重启恢复另有契约。
- DST 专项执行、配置导入合法成功 fixture、复数/RTL、生成后差异门禁、标签来源与远端规则待后续批次。
- 正式 SPDX/许可证、在线扫描、签名/attestation/Defender、Windows/Linux 桌面/安装升级/性能证据未取得。
- 业务导入、打印和时区/币种设置仍需产品边界，不新增虚构业务实体或通用任务框架。

最终回归：22 tests，OK，退出 0。中间一次参数替换误将可选 scan-summary 变为必填，回归退出 1（13 个发布 fixture 初始化错误）；已恢复可选条件，随后全部 22 项通过。Shell 与模板检查退出 0。

## 独立复核与修复（2026-11-02）

复核按所列文件全文进行：此副本无 Git 元数据，无法生成 diff、确认主实现的历史修改范围或证明生成区此前未改。核对 AGENTS.md 与需求台账，保留日期过滤、网格、表单、任务及平台证据开放状态。本次仅修改三个 Python 实现、两个测试文件、本记录和台账；没有修改生成区、锁文件、依赖、Rust/Dart 或工作流。

修复内容：严格扫描不得在公告库版本 unknown 时返回 PASS；超时保留已捕获输出并返回124；报告和证据 JSON 显式 UTF-8；元数据哈希拒绝非法值；--strict 拒绝仅指定 --zip；发行路径补拒 Windows 设备名、非法字符及 DEL。增加6项回归，并把原严格全绿 stub 改为普通模式全绿测试，另测严格未知数据库阻断。未伪造数据库版本。

| 本次实际命令 | 退出码 | 结果 |
|---|---|---|
| `python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 0 | 28项，0.876秒，OK；包含临时SQLite、发行fixture、扫描stub和模拟超时 |
| `bash -n scripts/security-check.sh && test -s docs/GRID_POC_REPORT_TEMPLATE.md` | 0 | Shell语法及模板非空通过 |
| `python3 -B scripts/check_sources.py` | 1 | 17项PENDING，与上文主实现记录逐项一致；不能独立证明实施前基线 |
| `git rev-parse --is-inside-work-tree` | 128 | 非Git仓库，无法审查历史差异 |

工具探测仅找到 Python，PATH 中未找到 cargo、flutter、dart、pwsh；Rust fmt/clippy/test、Flutter analyze/test、完整verify.ps1及两平台构建未执行。没有运行真实扫描或默认大规模基准。

工作流源码复核：release.yml 已上传整个 build/reports/，所以目录嵌套本身不破坏该路径；尚缺失败时 always 上传、严格调用、扫描摘要绑定、根目录严格校验、最终ZIP摘要生成/验证。当前工作流不能据离线28项通过宣称发布门禁已闭环。真实OSV 2.7 CLI、Windows编码/路径和扫描日志兼容性仍需目标工具实跑。

## 本批联合复核（2026-11-02）

本次按指定范围检查当前文件；无 Git 元数据，未取得历史 diff。实际修复 `rust/tests/diagnostic_pack_test.rs`：将接收 `ListParams` 的调用从旧六参数 `audit::list` 改为 `audit::list_filtered`，避免签名不匹配。同步本记录、IMPLEMENTATION_STATUS.md、REQUIREMENTS.md、AGENTS.md，未新建报告模板、手补生成物或改锁文件。

日期合同核对：Rust `Option<i64>` 对应桌面 Dart 可空 int；Dart 用下一本地日历日午夜作为排他上界，非固定24小时。API 传递两边界，列表/导出共用 `validate_date_range`，列表、COUNT、导出原始字节预检和所有批次共用 data/audit.rs 的 FILTER，使用参数绑定。已检查手写 AuditQuery/ListParams literals；生成 API 仍缺失，当前不能构建。新增 Rust SQLite/API/401行跨批次/快照测试只是源码，未实际执行。

发布命令核对：30项回归实际运行 release.yml 的证据 Bash 块及脚本 CLI，覆盖 ZIP 内容/隐藏文件、外摘要、篡改、未知元数据阻断与 pipefail。当前摘要通过 GITHUB_OUTPUT 传递；诊断 always 上传，候选要求扫描/证据/严格校验成功。公告库版本提取仍未实现，严格扫描即使所有 stub 工具退出0也返回3，严格元数据拒绝 unavailable。摘要哈希绑定不等于扫描成功、外部真实性或候选身份认证。

| 本次实际命令 | 退出码 | 结果 |
|---|---|---|
| `python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 0 | 30项通过（1.385秒），fixture/stub测试，非真实扫描 |
| `python3 -B scripts/check_sources.py --allow-pending-generation` | 0 | PARTIAL；17项PENDING（9项直接依赖未入锁，8项生成文件缺失），不代表可编译 |
| `git rev-parse --is-inside-work-tree` | 128 | 非Git仓库 |

PATH 探测只有 Python，未找到 cargo、flutter、dart、pwsh、flutter_rust_bridge_codegen、osv-scanner、gitleaks。Rust fmt/clippy/test、FRB/l10n 生成、Flutter analyze/test、真实安全扫描、Windows/Git Bash 路径及输出交接、PowerShell、Actions 条件/失败上传、Windows/Linux 构建及真实发行物打包均未验证。G01–G03、平台与正式发布门禁继续开放，不宣称本任务或任一阶段全部完成。

补充静态核对：手写 Rust 共13处 AuditQuery/ListParams 定义及 literals 均含两日期字段；包含 job 默认 shell 的24个 workflow Bash 多行块及 security-check.sh 经 bash -n 通过（退出0）。仅语法检查，不是 Actions/PowerShell 执行。

## 本批修复：审计导出未知阶段人工重查（2026-11-02）

已先读 AGENTS.md、需求相关章节、audit_export_provider.dart、task_view.dart、
audit_export_panel.dart 及三个导出/任务测试文件。缺陷是未知阶段计入 busy，但 provider
拒绝 refresh，两个视图也没有可用重查入口，导致无法通过确认终态解除关闭保护。

本批修改三个手写 Dart 实现、audit_export_provider_test.dart、task_view_test.dart、
REQUIREMENTS.md 和本记录。统一非终态判断供 busy/refresh/视图使用；未知阶段允许人工读取原
taskId，保留所有者姓名/角色、audit.export 权限、身份加载/失败、请求单飞及页面活动检查。
取消与自动轮询仍仅限 running；排队取消遇未知阶段时，人工重查清除旧意图且只查状态。
canCloseTaskView 对未知阶段明确拒绝关闭且不隐式查询/取消，人工重查入口在页面保留；
查询失败保持句柄、所有者与 busy，确认 completed/cancelled/failed 后才允许释放。

新增 provider 回归源码 8 项、widget 回归源码 12 项（任务视图/审计面板各 6 项）：
未知到 completed、失败保留保护并再次只读查询、单飞、不自动轮询未知阶段、
不重复 start/cancel、排队取消遇未知阶段、非所有者/角色变化/撤权/身份加载/失败时拒绝查询、
旧按钮回调拒绝越权、关闭在未知/查询中/查询失败时保留页面及终态后放行。
复用已有本地化文案，无新增依赖，未修改 FRB/l10n 生成区、Rust、锁文件或平台壳。

| 本批实际命令 | 退出码 | 结果 |
|---|---|---|
| `python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 0 | 30 项通过，1.273 秒；Python fixture/stub 回归，不覆盖 Dart 运行行为 |
| `python3 -B scripts/check_sources.py --allow-pending-generation` | 0 | PARTIAL；原有 17 项 PENDING：9 项直接依赖未入锁、8 项生成文件缺失 |
| `command -v` 探测 python3/flutter/dart/cargo/flutter_rust_bridge_codegen | 0（循环容忍未找到工具） | 仅找到 Python；其余不在 PATH |

本机无 Flutter/Dart/Cargo/codegen，未执行 Dart 格式化、Flutter analyze/test、
FRB/l10n 生成、cargo fmt/clippy/test 或 Windows/Linux 桌面验证。
新增 20 项 Dart 回归仅为源码，不能据 Python 通过宣称 widget/provider 测试通过。

## 本批集成与独立源码复核：任务列表、历史日志（2026-11-02）

先读根AGENTS及实际实现。本副本不是Git仓库（git rev-parse退出128），按指定文件全文与调用链复核，
无法取得历史diff；工具无delegate_subagent，审查降级为单agent分模块复核，不声称完成独立多agent重扫。

本轮实际修改11文件（相对本轮开始，不含前置agent已写文件）：
- lib/l10n/app_en.arb、lib/l10n/app_zh.arb：六个约定键和独立diagHistoryEmpty；旧taskViewScope同步当前契约。
  新键无占位符；补中文21项既有placeholder元数据，类型/格式按英文模板对齐。
- lib/features/audit/state/audit_export_provider.dart：迟到start/select响应对所有非终态（含未知阶段）保留句柄，
  修复身份变化/页面隐藏后未知阶段被丢弃而解除关闭保护；不改变仅running轮询/取消协议。
- lib/features/diagnostics/view/diagnostic_history_dialog.dart、diagnostics_view.dart：历史入口/提交/返回/错误均拒绝身份加载或失败，
  加载时移除旧结果与错误；旧回调重新检查就绪身份；空结果使用日志文案，不再称最近事件。
- test/features/audit_export_provider_test.dart：新增迟到start和select未知阶段的2项回归源码。
- test/features/diagnostics_history_test.dart：新增身份refresh保留旧值时隐藏结果、禁用提交及拒绝旧回调的1项回归源码，更新空态断言。
- AGENTS.md、docs/REQUIREMENTS.md、docs/IMPLEMENTATION_STATUS.md及本记录：区分进程内列表、持久历史、跨重启恢复和历史日志文件检索。

核对保留的行为：Rust Registry最多6项，按完整姓名/角色过滤，创建时间降序、任务ID打破平局；
全部终态满300秒隐藏，查询不续期，prune不删除原导出文件；running不受终态TTL影响。
按ID选回重新查询所有者/TTL，启动/请求/复制/非终态期间拒绝替换；忙状态继续纳入关闭/退出保护。
app.dart已登记taskWorkspacePage，保留audit与tasks共用关闭守卫及孤立导出全局退出保护，本轮无需改动。
bridge.dart只有一份诊断import和各一份新增列表/历史适配接口，手写Rust入口一致；生成API缺失，不能据此判定类型或编译通过。

历史日志固定data_dir/logs和合法每日命名；拒绝链接祖先/符号链接/重解析点/非普通文件，
Linux nofollow/nonblock、Windows句柄file ID复核；快照长度与Take限制实际读取，
256目录项/14文件/4MiB/200行，输入128标量、输入行8192字节、输出2048标量。
完整行二次脱敏后字面匹配；超长/损坏/不完整行跳过，返回truncated；spawn_blocking结束后重新授权并比较完整身份。
单飞许可由阻塞任务持有；关窗丢弃迟到结果，底层有界扫描不取消。
有限目录枚举不保证覆盖全部最新文件；目录恶意并发替换TOCTOU、脱敏规则遗漏仍是已知边界。
以上是源码核对，未实跑Rust文件测试或平台安全测试。

| 本批实际命令/检查 | 退出码 | 结果 |
|---|---|---|
| python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v | 0 | 全部30项通过，1.378秒；fixture/stub，不是Rust/Flutter或真实扫描 |
| python3 -B scripts/check_sources.py --allow-pending-generation | 0 | PARTIAL，17项PENDING：9项既有直接依赖未入锁、8项生成文件缺失 |
| bash -n scripts/security-check.sh | 0 | Bash语法通过 |
| Python JSON/正则资源契约断言 | 首次1，修复后0 | 首次发现中文pagePosition缺元数据；随后补齐全部21项，双语键集合及所有占位符元数据通过；不是Flutter ICU编译 |
| Python AST解析scripts全部.py | 0 | 语法通过，不生成pyc |
| 手写API/import/任务静态注册断言 | 0 | 适配名字唯一、Rust入口存在、任务页已注册；不是FRB类型检查 |
| command -v python3 cargo rustfmt dart flutter flutter_rust_bridge_codegen | 仅找到Python | PATH无其余工具；前置报告中的Flutter目录不等于可运行SDK |

未执行FRB/l10n生成、Dart格式化、flutter analyze/test、cargo fmt/clippy/test；
新增3项Dart回归仅为源码，不能据Python通过宣称其通过。目标Windows/Linux身份切换、撤权、TTL选回、
取消/完成竞争、另存系统对话框、关闭/退出、文件锁/轮转/链接、键盘与小窗口布局待真实验收。
未增加依赖、未改锁/生成区、未提交或发布。

网格下一步仍受三项阻断：目标版本包源码/API与LICENSE正文/哈希/传递依赖证据；可用生成编译工具链；
Windows/目标Linux完整网格矩阵实测。可先编写用户稳定标识+列表ID列偏好契约及独立编辑fixture，
不能将全局导航偏好视为用户隔离，也不能把候选类名当已验证API。PlutoGrid未引入、未准入。

## 本批最小修复：历史日志目录枚举上限（2026-11-02）

先读 AGENTS.md、需求 §4–§5 与目标源码；仅修改 diagnostic_history.rs 及本记录。
目录枚举改为 `0..MAX_DIRECTORY_ENTRIES` 简单有界循环，每轮一次 `entries.next()`，
最多调用256次；`None` 提前结束，`Some(Err)` 经 `entry?` 返回错误。
第256项成功取得后、文件名过滤前保守标记 truncated，不探测第257项，无新增抽象或生成文件改动。

新增真实目录边界测试源码，覆盖0/255/256/257项，均使用被忽略的文件名，
断言前两者不截断、后两者截断且不扫描日志文件。
具体 ReadDir 的 next 调用次数无法从 scan 返回值直接观测，迭代中错误也无稳定可移植的文件系统注入方式；
这两项仅静态核对循环上界、唯一 next 调用及紧随其后的 `?`，未引入测试专用泛化框架。

实跑 `python3 -B scripts/check_sources.py --allow-pending-generation` 退出0/PARTIAL，
仍报告17项既有 PENDING；该检查不验证 Rust 编译或枚举运行行为。
`command -v` 未找到 cargo/rustc/rustfmt/flutter/dart；未执行 cargo fmt/clippy/test、
Flutter analyze/test，新增 Rust 边界测试仅为源码、未运行。


## 本批集中复核：表单解析与本地化契约（2026-11-03）

静态复核确认 `parseSampleDateTime` 不再 trim 输入，因此尾随换行、前后空白、错误分隔符、全角数字和时区后缀均按严格格式拒绝；现有 Dart 测试已覆盖尾随换行等边界，但当前环境无法执行 Dart/Flutter。表单视图调用的 `formSampleTimeDisplayNotice`、`formSampleUtc`、`formSampleTimeDisplay`、`formSampleInternationalInputRules`、`formSampleInternationalPreview`、`formSampleAmount`、`formSampleSystemLocal`、`formSampleCurrency`、`formSampleAmountError` 已在中英文 ARB 中补齐，预览 9 个 String placeholder 与调用顺序一致。

本轮仅修改手写解析器、Dart 测试契约、双语 ARB 及状态文档；未修改生成区、Rust、锁文件或平台壳。资源 JSON、placeholder 集合和 Python 脚本语法可离线检查；这些检查不能替代 `flutter gen-l10n`、Dart analyzer、widget tests、Rust tests 或桌面验收。

## 2026-11-04 多 agent 推进：执行环境与查询基准

用户已确认 Windows 构建验证完成；本机此次没有重跑 Windows。该基线只覆盖当时版本。当前副本虽保留部分扩展桥接、本地化产物与锁文件，`python3 -B scripts/check_sources.py` 已实测退出 1，报告新增 ARB/FRB 声明和模块/文件缺失。
本节原先的 PASS 与“无 PENDING”属于 2026-11-04 历史快照，现标明为历史结果；历史生成/构建结论不能覆盖当前门禁。

实际执行：

| 命令/场景 | 退出码 | 结果与覆盖边界 |
|---|---:|---|
| `python3 -B scripts/check_sources.py` | 1（当前复跑） | l10n/FRB 生成声明、函数、模块和文件仍缺失；只覆盖源码/资源/引用，不检查 Dart/Rust 编译 |
| `python3 -B -m unittest discover -s scripts/tests -p test_grid_poc.py -v` | 0 | 3 项通过：错误数据拒绝、排序/参数、过滤/缓存模式 |
| `bash -n scripts/security-check.sh` | 0 | Shell 语法通过 |
| `grid_poc.py`：10k/100k/1m，warm，每项 5 次 | 0 | 合成查询返回值、排序、过滤、COUNT、边界分页均通过；原始报告 `build/reports/requirement-grid-poc-20261104.json` |
| 相同规模，new-connection，每项 5 次 | 0 | 每个样本新连接，结果校验通过；报告 `build/reports/requirement-grid-poc-20261104-new-connection.json`；不清空 OS 缓存 |
| `cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo test` | 127 | 本 Linux 会话 PATH 中无 cargo，未运行检查 |
| `flutter analyze`、`flutter test` | 127 | 本 Linux 会话 PATH 中无 flutter，未运行检查 |

查询耗时、机器与命令见 [GRID_POC.md](GRID_POC.md)。数据库仅使用隔离路径
`build/requirement-grid-poc-20261104.sqlite3`，未访问用户产品数据库。
本轮 UI 变更不继承此前的构建通过状态；新增 widget 回归仍须在可用 SDK 环境执行。
`uv` 可用，但未安装 browser-use，且本项目为原生 Flutter 桌面应用，没有可据以替代桌面验收的网页地址；
未安装浏览器验证工具或声称已完成浏览器/原生窗口截图验收。

本批（历史快照）Python 集成回归：`python3 -B -m unittest discover -s scripts/tests -v` 退出 0，
42 项全部通过（1.538 秒），覆盖 RustSec 来源观察、扫描控制流、发布证据字节绑定和篡改拒绝、
真实 workflow Bash 片段 fixture、ZIP 与合成查询。扫描工具及联网获取在测试中使用替身，
不代表真实安全扫描或 Windows/Git Bash/Actions 已运行。OSV 在线 API 未提供全局数据库版本，
仍记录 unknown 并阻断严格发布，未伪造版本或 attestation。

环境副作用记录：审计实现子 agent 报告执行 `codex --help` 寻找补丁工具时，
宿主 ducx 包装器自动将外部 CLI 从 `10.142.5.1` 更新为 `10.166.0.2`。
这不是项目实现所需的升级；主 agent 未重跑该包装器或尝试回退外部安装，
无法从当前无 Git 元数据的副本独立核实该外部变更。仓库内后续接手修改使用会话提供的 apply_patch 工具。
