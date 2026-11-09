# 数据网格 POC 执行说明

本 POC 用来决定是否引入 PlutoGrid，或者收缩 v1 网格范围并更换候选组件。当前 Fluent 审计页使用 `Row` 与 `ListView` 组合的分页只读表格（早期为 `DataTable`），不视为最终网格；SQLite 查询速度也不代表 Flutter 渲染性能。

## 已准备的查询基准

2026-11-06：`poc/grid_columns` 新增只读合成数据页面及中英文 ARB，支持列草稿、应用/取消、会话内保存/恢复。包内新增 SDK `flutter_localizations` 与 `intl 0.20.3`（复用根应用既有依赖；许可与传递版本仍须随 POC 锁定核对）。2026-11-08 已在本机解析独立 `pubspec.lock` 并实际执行 `flutter gen-l10n`、`flutter analyze`、`flutter test`、`dart format`，扩展后的编辑/粘贴/分页结果见下文「2026-11-08 网格 POC 扩展」。这不代表生产准入、跨会话持久化或平台矩阵通过。

`scripts/grid_poc.py` 会重建一个仅用于 POC 的 SQLite 数据库，默认测量 10,000、100,000 和 1,000,000 行。每个规模执行：

- 200 行分页查询，定位在数据集约中部；
- 按操作者和结果过滤后分页；
- 过滤计数查询；
- 固定排序：`at DESC, actor ASC, id DESC`。

运行：

```bash
python3 scripts/grid_poc.py \
  --output build/reports/grid-poc-sqlite.json
```

自定义规模：

```bash
python3 scripts/grid_poc.py --counts 10000,100000,1000000
```

输出中的 `query_scope` 明确表示它只覆盖 SQLite 数据和查询工作负载。脚本没有测量 Flutter widget、虚拟化、键盘、剪贴板、进程内存或窗口生命周期。

## 桌面验收矩阵

在锁定 Flutter、Dart、FRB 和网格包版本后，使用同一份数据库数据执行以下矩阵，并把机器、系统、构建模式、分辨率、行数、列数、页大小、过滤条件和结果保存在 `build/reports/`。没有实际结果的项目保持未通过。

| 类别 | 场景 | 记录内容 |
|---|---|---|
| 只读 | 空、加载、失败、无权限、分页、排序、稳定选择 | 可操作性、错误提示、选择是否跨查询泄漏 |
| 布局 | 固定列、列宽、列序、列显隐、保存后恢复 | 设置是否按用户隔离，窄窗口是否仍可访问 |
| 键盘 | 上下、Home/End、Tab、Enter、Esc、Ctrl+C | 焦点位置、重复输入、防止隐藏页抢焦点 |
| 剪贴板 | 单元格、行、范围复制与粘贴校验 | 文本格式、换行/引号、非法数据拒绝 |
| 编辑 | 文本、数字、日期时间、枚举基础编辑 | UI 校验、Rust 校验、错误聚焦、取消和脏草稿 |
| 数据量 | 10k、100k、1m 行，冷热缓存 | 首屏、翻页、过滤、排序耗时，是否加载全量数据 |
| 资源 | 开页、筛选、切换、隐藏、关闭、重开循环 | 进程内存、任务/订阅数量、关闭后是否释放 |
| 平台 | Windows 首发，目标 Linux 环境冒烟 | 构建模式、系统版本、字体、剪贴板、快捷键 |

## 放行条件

必须同时满足：

1. 列表查询保持服务端式分页，不能因网格接入在 Dart 侧复制全量数据库；
2. 10k/100k/1m 的查询和渲染结果分别记录，不能用小数据推断大数据；
3. 键盘、剪贴板、列设置和生命周期矩阵有实际结果；
4. 直接依赖的版本和许可证进入锁文件及依赖审查；
5. Windows 验证通过，Linux 至少完成目标环境构建和冒烟；
6. 若候选组件无法满足矩阵，按需求文档 §6.3 收缩 v1 能力或更换组件，不自研完整网格引擎。

Windows Release 的既有构建验证已由用户确认，但不覆盖完整网格 POC。2026-11-04 已执行下述合成 SQLite 查询基准；Flutter 渲染、完整网格交互和平台矩阵仍无本轮运行结果，因此 T01 仍保持开放。

报告从 [结果模板](GRID_POC_REPORT_TEMPLATE.md) 复制，默认 NOT RUN。隔离 POC 已有固定列、列配置、
会话内保存/恢复、对照 Rust fixture 的编辑/粘贴校验、分页与虚拟化源码，并已在本机执行（见下文
「2026-11-08 网格 POC 扩展」）；跨会话持久化、真实按键焦点、进程内存与平台矩阵仍待执行或集成。
审计数据保持只读。

当前 `grid_poc_row` 使用复合索引、精确 actor/result 过滤，与真实 `audit_log` 的索引、LIKE 及排序不同，属于合成工作负载，不能代表产品查询或 Rust/FRB/Flutter 性能。`--repetitions` 指定重复次数，`--cache-mode new-connection|warm` 区分每个样本新连接与同连接先执行一次不计时预热；两者均不清 OS 缓存。输出保留每次耗时、COUNT 实值、汇总、机器/Python/SQLite 版本，并校验预期结果、过滤、分页及稳定排序。默认大规模命令只在隔离 POC 目录执行。

## 2026-11-04 候选来源核对

只读查询了 [pub.dev 8.1.0 元数据](https://pub.dev/api/packages/pluto_grid/versions/8.1.0)、
[上游同名标签 LICENSE](https://raw.githubusercontent.com/bosskmk/pluto_grid/8.1.0/LICENSE)
和 [PlutoGrid 源码](https://raw.githubusercontent.com/bosskmk/pluto_grid/8.1.0/lib/src/pluto_grid.dart)。
本轮没有引入包、修改锁文件或声明组件准入通过。

| 项目 | 已核对内容 |
|---|---|
| 候选版本 | `pluto_grid 8.1.0`；pub.dev 记录发布时间为 2025-12-12 |
| 官方包地址 | `https://pub.dev/api/archives/pluto_grid-8.1.0.tar.gz` |
| 官方元数据提供的 SHA-256 | `3c547952cb73d78eea0cd5e66ef9177e065761783431e3b18d715fb8010f6f3d`；本轮未下载归档作独立比对 |
| SDK 约束 | Dart `>=2.17.0 <4.0.0`，Flutter `>=2.5.0`；声明约束兼容不等于当前工具链编译通过 |
| 运行依赖声明 | Flutter SDK、`intl ^0.20.2`、`rxdart ^0.28.0`、`collection ^1.19.1` |
| 上游标签许可证 | MIT；版权行 `Copyright (c) [2020] [PlutoGrid]`，要求分发时保留版权及许可声明 |
| 源码能确认的接口 | `PlutoGrid` 接收 `columns`/`rows`、`onLoaded`/`onChanged`/`onSelected`/`onSorted`、`createHeader`/`createFooter` 等；`PlutoGridMode.readOnly` 注释说明单元格不可编辑 |

下一步须下载并校验官方归档，核对归档内 LICENSE 与实际源码 API，再在可用 Flutter
工具链解析锁定版本、审查完整传递依赖，并验证 Fluent 宿主中的焦点、弹层、主题及分页。
上述接口摘录不证明服务端分页、粘贴授权、列偏好用户隔离或完整键盘能力；
不得据此编造额外 API 或把候选直接替换进产品。

### 2026-11-08 生态备注：trina_grid

2026-11-08 只读核对（pub.dev 页面）：`pluto_grid` 上游仍在维护（8.1.0，2025-12），
但其社区重心已迁移到后继包 `trina_grid`——`pluto_grid_plus` fork 已停止维护并明确指向它。
POC 时须把 `trina_grid` 与 `pluto_grid` 一并纳入对比（各自按本文件与需求文档 §6 的
准入门槛与依赖治理流程核对），再锁定其一；本文其余内容仍针对 pluto_grid，不预先下结论。
实际对比结果见下一节。

## 2026-11-08 网格 POC 扩展与候选对比（实际执行）

### 本次扩展（`poc/grid_columns`，仍是隔离包，不接生产依赖）

- 默认仍是只读 12 行合成数据，既有 21 项回归全部保留并通过。
- 新增可编辑模式、数据集规模选择（12 / 1k / 10k / 100k / 1m）与 `PlutoLazyPagination`
  分页；每页 200 行，与产品分页上限一致。
- 新增 `lib/fixture_contract.dart`（对照 `rust/src/services/grid_fixture.rs::validate`
  的 Dart 镜像）与 `lib/fixture_source.dart`（只物化请求页的合成数据源）。
- 编辑与粘贴共用同一合同校验：非法单元格还原为旧值并在状态行显示本地化原因；
  五个可编辑列全部使用 `PlutoColumnType.text()`，不使用会静默纠正的数字/日期类型。
- `Ctrl+V` 替换为 `SafePasteAction`：空剪贴板不崩溃，超过 1 MiB 的载荷整段拒绝。
- 多页数据集关闭客户端排序（`enableSorting: false`），避免“只排序当前页”的假象。

### 实际执行（2026-11-08，本机 `poc/grid_columns`）

命令：`flutter gen-l10n`、`flutter analyze`、`flutter test`、
`dart format --output=none --set-exit-if-changed lib test`。

结果：analyze 0 项；`flutter test` **48 通过 + 1 有理由 skip**（skip 项是 PlutoGrid
缺陷的手工复现，原因见下）；format 无差异；`pubspec.lock` 解析出 `pluto_grid 8.1.0`
与传递依赖 `rxdart 0.28.0`（Apache-2.0，已读包内 LICENSE 正文）。

| 矩阵类别 | 本轮已执行场景 | 结果 |
|---|---|---|
| 数据量 / 虚拟化 | 1,000,000 行数据集 | 通过：仅 200 行进入 `refRows`，实际渲染的 `PlutoBaseRow` 少于 200 |
| 分页 | 翻到第 2 页 | 通过：`row-201`…`row-400` 替换当前页 |
| 编辑 | 合法值规范化、非法数量/日期/枚举还原 | 通过（含中文提示） |
| 剪贴板 | 范围复制 TSV；粘贴合法/非法混合；空剪贴板；1 MiB 上限 | 通过 |
| 只读 | 默认只读、只读时粘贴不改值 | 通过 |
| 资源 / 生命周期 | 取页在途时销毁页面 | **失败**：PlutoGrid 自身断言，见缺陷 5 |
| 键盘焦点 | 真实 Ctrl+C/Ctrl+V 按键与焦点顺序 | NOT RUN（测试直接调用动作与状态管理器） |
| 进程内存 / 平台 / DPI / 读屏 | Windows、Linux 实机 | NOT RUN |

### PlutoGrid 8.1.0 实测缺陷（均已被 POC 测试固定）

1. **`rows` 必须可变**：`PlutoLazyPagination` 取页后调用 `refRows.clearFromOriginal()`，
   会对传入列表执行 `length = 0`；`const []` 或不可变列表在下一次取页抛
   `UnsupportedError: Cannot change the length of an unmodifiable list`。
2. **数字/日期列会静默纠正非法输入**：`castValueByColumnType` 只对数字格式做
   `applyFormat`，非法数字变成 0。故编辑列必须用文本列 + 自有校验，否则粘贴损坏不可见。
3. **Dart 与 Rust 的数字解析不一致**：Dart `int.tryParse('0x10')` 返回 16，
   Rust `i32::from_str` 拒绝。镜像校验先匹配 `^[+-]?[0-9]+$` 才能与 Rust 对齐。
4. **内置粘贴不安全**：`PlutoGridActionPasteValues` 断言 `value!.text!`（空剪贴板抛异常），
   且不限制载荷大小；POC 用 `SafePasteAction` 替换。
5. **惰性分页无销毁守卫**：`PlutoLazyPagination.setPage` 的完成路径调用
   `stateManager.scroll.bodyRowsVertical!.jumpTo(0)`，取页在途时销毁网格会在页面消失后
   触发 `ScrollController not attached to any scroll views`。生产接线必须保证取页期间不销毁
   网格，或改由自己实现页脚。复现断言无法在同一 `testWidgets` 体内捕获（框架直接上报），
   因此保留为 `skip: true` 的手工复现，另有通过项固定“销毁后控制器无 clients 且 `jumpTo` 断言”。

### trina_grid 对比（只读核对，未加入 POC 锁文件）

| 项目 | `pluto_grid 8.1.0` | `trina_grid 2.4.0` |
|---|---|---|
| 最新发布 | 2025-12-12 | 2026-10-31（共 27 个版本） |
| 归档 SHA-256 | `3c547952…6f3d` | `cda88c3a…a83` |
| SDK 约束 | Dart `>=2.17 <4`、Flutter `>=2.5` | Dart `^3.9.2` |
| 运行依赖 | `intl ^0.20.2`、`rxdart ^0.28.0`、`collection ^1.19.1` | 同上 + `path ^1.9.1`、**`pdf ^3.11.3`**、**`shadcn_ui >=0.55 <0.58`** |
| 许可 | MIT（tag 8.1.0 LICENSE 正文） | MIT（`main` 分支 LICENSE 正文，声明版本 2.4.0；`2.4.0`/`v2.4.0` 标签路径 404） |
| 上游 | `bosskmk/pluto_grid` | `doonfrs/trina_grid` |

本次不把 `trina_grid` 加进 POC 锁文件：它会额外引入 `pdf`（Apache-2.0）与 `shadcn_ui`
（MIT，但需要核对主题与 SDK 约束），在其本身完成同一矩阵之前，没有证据表明它更合适。
当时的结论保持开放：v1 暂以 `pluto_grid` 为候选，`trina_grid` 矩阵状态 NOT RUN；
不得仅凭发布节奏或用“社区重心迁移”作为唯一理由更换。
**2026-11-09 更新**：同一 POC 用例对比已实际执行两轮（含 Fluent 宿主同仪用例），见下节；
候选锁定仍开放（真实 OS 焦点/窗口、进程内存与平台矩阵对两者都未跑）。

## 2026-11-09 trina_grid 同用例对比（实际执行）

隔离包 `poc/grid_columns_trina`：`poc/grid_columns` 的页面、fixture 契约、列适配层与
全部用例 1:1 移植（Pluto→Trina 改名），另加 5 项缺陷探针与 1 项真实按键分发用例。
第二轮两包各加同一份 7 项 Fluent 宿主用例（FluentApp + fluent_ui 4.17.0，仅 dev 依赖）。
不接生产依赖，根锁文件未动。报告：`build/reports/grid-poc-trina-20261109.md`。

门禁实跑（本机 Flutter 3.47.8 / Dart 3.13.7）：`flutter pub get`（trina 85→91 项、pluto 28→35 项，
锁文件 url 全为 pub.dev；本机 `/c/tools/bin/flutter` 包装脚本硬编码清华镜像，须绕过包装直接调
flutter_tools 并钉 `PUB_HOSTED_URL=https://pub.dev`）、`flutter gen-l10n`、
`dart format --output=none --set-exit-if-changed .` 0 差异、两包 `flutter analyze` 0 项、
`flutter test` **trina 62 通过 / 0 skip；pluto 54 通过 + 2 skip**（pluto 的缺陷 5 复现与
本轮缺陷 8 探针均带理由 skip），含第二轮 7 项 Fluent 宿主用例（trina 7/7，pluto 6/7 + 1 skip）。
变异负控制：撤掉快捷键覆盖修复后 3 项转红（含真实分发用例），还原后全量复绿。

供应链：官方归档独立下载计算 SHA-256
`cda88c3ad69748f54cf2bedb7c8e9af4a6a2e128dd994dbfb8e604d92f463a83`，与 pub.dev 元数据一致；
包内 LICENSE 正文 MIT（Copyright (c) [2020] [TrinaGrid]）。相对 pluto 锁**新增 58 个传递包**
（pdf 3.13.1、shadcn_ui 0.57.4 及其树：flutter_svg、flutter_animate、slang、boxy、
extended_image、universal_image、jni/objective_c、lucide_icons_flutter、serial_csv、
two_dimensional_scrollables 等），逐包读 LICENSE，全部 MIT / BSD-3-Clause / Apache-2.0；
完整 NOTICE 与 security-check 留到正式引入生产依赖时。

五缺陷对照（探针 + 包内源码双证）：

| # | pluto_grid 8.1.0 | trina_grid 2.4.0 |
|---|---|---|
| 1 rows 必须可变 | 有 | **仍在**（clearFromOriginal 仍 length=0；Response 构造器对含 frozen 行的列表原地改） |
| 2 数字列静默纠正 | 有 | **仍在**（先 applyFormat 纠正再 validate，校验器只能看到纠正后的值）；新增 column.validator/onValidationFailed 钩子对文本列可用 |
| 3 Dart/Rust 解析差异 | 有 | 同（语言层面） |
| 4 内置粘贴不安全 | 空剪贴板断言、无上限 | **部分修**：null 数据提前返回；`value.text!` 仍强解包、仍无上限，SafePaste 仍必需 |
| 5 惰性分页销毁守卫 | 无（断言崩溃） | **已修**（mounted + fetch version 双守卫，复现用例去 skip 通过） |

trina 新发现（均已有测试固定）：

6. **快捷键覆盖陷阱**：默认表用 SingleActivator（仅身份相等），handle() 按插入序取首个
   匹配；pluto 式 LogicalKeySet 覆盖和同形键替换都被内置粘贴静默压住。生产接线必须
   按动作类型剔除内置粘贴项再注册 SafePaste（control 与 meta 两变体）。
7. **取页失败静默**：setPage 的 catchError 只 debugPrint 并关 loading，无错误事件/重试面；
   生产接线必须自行处理 fetch 失败，不能依赖组件报错。
8. **宿主差异（pluto 侧缺陷）**：Fluent 页内没有 Material 祖先时，pluto_grid 8.1.0 的单元格
   进入编辑抛 `No Material widget found`；trina 2.4.0 在网格外层按需补透明 Material（其
   #423 修复），同一用例通过。选 pluto 则每个网格页必须自包 Material。两候选共同前提：
   FluentApp 默认只提供独立包 `material_ui` 的本地化代理，宿主必须另注入
   `flutter_localizations` 的 GlobalMaterialLocalizations（生产应用已如此）。

Fluent 宿主同仪结果（第二轮，widget 级）：渲染/懒取页、深浅主题、真实 ArrowDown、
真实 Ctrl+C、真实 Ctrl+V 超限拒绝、Fluent ContentDialog 覆盖后按键路由——两候选全 PASS；
第 8 项 pluto FAIL / trina PASS。日志：`build/reports/{trina,pluto}_fluent_host.log`
与 `*_fluent_suite.log`。

**当前结论**：对比门禁（同一用例跑两者）已完成。证据倾向 trina_grid——缺陷 5 已修、
原生校验钩子可用、Fluent 宿主无需 Material 壳；缺陷 1/2/4 两候选都需要同样的绕行代码，
trina 的缺陷 6/7 已有固定解法。代价是 +58 传递依赖（宿主测试另加 6 包，许可均宽松）。
**锁定仍开放**：真实 OS 焦点与窗口、进程内存、DPI/读屏、Win/Linux 平台矩阵对任一候选
都是同一套未跑项，按需求文档 §6 放行条件补齐后方可锁定；本轮不改变生产依赖。

## 第二批独立编辑与导入 fixture 契约

这是为 §1.3/§5/§6/§9.2 验证选择的合成 POC 契约，不是订单、库存或用户业务模型，
也不把它扩展为通用业务导入规则。fixture 使用独立 SQLite 连接/数据库，绝不写 `audit_log` 或正式配置。

字段为 `id`（1–64 个 ASCII 字母/数字/下划线/短横线）、`text`（trim 后非空，
原始输入不超过 80 个 Unicode 标量，拒绝控制字符）、`quantity`（int32）、
`date`（严格 `YYYY-MM-DD`、1900–2100 年真实 Gregorian 日期）、`kind`（`standard`/`priority`）。
单行编辑在事务中校验并保存；取消不写。Rust 是最终校验边界，UI 提示不能替代它。

首批导入格式为 UTF-8 JSON Lines，每行一个完整对象，拒绝未知字段、无效 UTF-8 和中间空行，
允许末尾换行；无压缩或归档。总输入最多 1 MiB、最多 10,000 条，单行最多 4 KiB。
ID 与已有记录或同批次重复均拒绝，不覆盖旧数据。整批使用同一事务，
任何解析/校验/写入失败或提交前取消均回滚；提交成功后取消不撤销，结果为完成。
取消为协作请求，在读取、逐行处理及提交前检查；进度需限频，且不得把进度当提交证明。

内部实现和测试可以先推进；新增 FRB API、界面编辑/导入、列配置及平台网格仍须另行集成与正常生成，
不能以 Rust fixture 核心存在宣布网格或批量业务导入已交付。

## 2026-11-04 查询层执行记录

在本 Linux 编写机运行，Python 3.8.16、SQLite 3.29.0、x86_64；每页 200 行，每项重复 5 次。
隔离数据库为 `build/requirement-grid-poc-20261104.sqlite3`，不访问产品数据库。
命令中的 `--database` 会重建该 POC 表，重跑时仅使用隔离路径。

```bash
python3 -B scripts/grid_poc.py --database build/requirement-grid-poc-20261104.sqlite3 --counts 10000,100000,1000000 --repetitions 5 --cache-mode warm --output build/reports/requirement-grid-poc-20261104.json
```

该次执行退出码为 0，所有查询返回值、过滤结果、边界分页和顺序校验均通过。
中位耗时如下（毫秒；warm 为同连接预热，不代表清空 OS 缓存后的结果）：

| 行数 | 中部分页 | 过滤分页 | 过滤 COUNT | 末行分页 | 越界分页 |
|---|---:|---:|---:|---:|---:|
| 10,000 | 0.536 | 0.954 | 0.847 | 0.298 | 0.298 |
| 100,000 | 4.309 | 17.648 | 9.599 | 4.298 | 4.261 |
| 1,000,000 | 22.330 | 22.958 | 94.437 | 43.875 | 43.997 |

原始 JSON 保留机器信息和全部样本，输出在被忽略的 `build/reports/` 中。
这些结果只关闭“合成查询基准已实际执行”这一项，不关闭 T01、产品审计查询性能、
Rust/FRB 开销、Flutter 虚拟化、CPU/内存、剪贴板或桌面生命周期验收。

另执行相同规模和重复次数的 `--cache-mode new-connection`，输出为
`build/reports/requirement-grid-poc-20261104-new-connection.json`，结果校验通过。
各项中位耗时如下（毫秒）；每个样本重新连接 SQLite，**不清空 OS 缓存，不标作冷缓存**：

| 行数 | 中部分页 | 过滤分页 | 过滤 COUNT | 末行分页 | 越界分页 |
|---|---:|---:|---:|---:|---:|
| 10,000 | 1.234 | 2.211 | 2.427 | 0.853 | 0.817 |
| 100,000 | 2.890 | 11.366 | 9.936 | 4.664 | 4.416 |
| 1,000,000 | 23.992 | 27.675 | 96.227 | 45.230 | 45.065 |
