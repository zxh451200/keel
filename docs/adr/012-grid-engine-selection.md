# ADR-012：数据网格基础选用 trina_grid 2.4.0

- 状态：已接受（依赖锁定与首个生产页面接线）；平台验收仍开放
- 日期：2026-11-09
- 替代：AGENTS.md ADR-005 中“PlutoGrid 优先候选、未验收”的选择部分（POC 结论见 `docs/GRID_POC.md`）

## 背景

Keel 需要一个可二次开发、MIT/BSD 许可、能虚拟滚动、列设置与键盘/剪贴板可控的数据网格。
v1 基线曾以 `pluto_grid 8.1.0` 为首选候选；2026-11-09 用同一套隔离用例（`poc/grid_columns`
与 `poc/grid_columns_trina`，页面、fixture 契约、列适配层与测试 1:1 移植）完成两轮对比，
并在 FluentApp 宿主下同仪验证 7 个用例。

## 决策

生产依赖锁定 `trina_grid: 2.4.0`（MIT，包内 LICENSE 正文 Copyright (c) [2020] [TrinaGrid]；
官方归档 SHA-256 `cda88c3ad69748f54cf2bedb7c8e9af4a6a2e128dd994dbfb8e604d92f463a83`）。
首个生产接线为往来单位示例页：行选择、虚拟滚动、键盘与复制由网格承担；`code/name/phone/email` 已接单元格内联编辑与 Ctrl+V 区域粘贴（`update_customers` 一次事务），kind/status/备注仍走对话框。

## 依据

- **同用例结果**：trina `flutter test` 62 通过 / 0 skip；pluto 54 通过 + 2 有理由 skip。
  pluto 的惰性分页无销毁守卫（缺陷 5）在 trina 已用 `mounted` + fetch version 修复，
  同一复现用例去 skip 通过。
- **缺陷对照**：两者都需绕开 rows 必须可变、数字/日期列静默纠正、内置粘贴仍强解包且无上限；
  trina 另有两个已固定绕法的缺陷——默认快捷键用 `SingleActivator`（仅身份相等）且
  `handle()` 按插入序取首个匹配，覆盖须按动作类型/键过滤默认表；惰性取页失败只 `debugPrint`，
  生产接线必须自行处理错误。
- **宿主差异**：Fluent 页内无 Material 祖先时，pluto 的单元格编辑抛 `No Material widget found`；
  trina 2.4 在网格外层按需补透明 Material（其 issue #423），同用例通过。
- **许可与供应链**：根锁新增 52 个传递包（pdf、shadcn_ui、flutter_svg 等树），逐包读正文为
  MIT / BSD-3-Clause / Apache-2.0，无 copyleft 或未知许可。传递依赖把 `jni` 注册为
  Windows/Linux 的 FFI 插件（`generated_plugins.cmake` 新增条目）；接入后的 Windows Debug
  构建与 7 项桌面集成入口实跑通过，但该原生依赖的体积/构建时间与 Linux 侧仍需持续观察。

## 后果

- 根 `pubspec.lock` 由 42 项增至 110 项（102 hosted + 7 SDK + 1 本地 path），发行物 NOTICE
  需覆盖新增包；`security-check.sh` 与 CI 联网公告库扫描仍按发布门禁独立执行。
- 引入 shadcn_ui/pdf 等非网格必需传递包，主题与体积需在后续批次观察；如需收缩，可评估
  trina 的依赖裁剪能力，但不得手改生成物或锁文件。
- 任何页面接入都必须复制三套绕法：可变 rows、文本列 + 自有校验、粘贴上限与空剪贴板防护；
  快捷键覆盖只能按默认表过滤后插入。
- **未关闭**：真实 OS 键盘焦点/窗口行为、进程内存与 CPU、DPI/读屏、Windows 与 Linux 平台矩阵、
  1 万/10 万/100 万端到端；这些按 `docs/IMPLEMENTATION_STATUS.md` 的 U03/P02/T01 行继续取证，
  不因本 ADR 记为通过。2026-11-09 已补语义树断言（区域标签 + 数据暴露/隐藏列不泄漏/本地化），
  但 trina 不暴露行选中语义，读屏朗读与焦点顺序需要目标机人工验收（X06）。
