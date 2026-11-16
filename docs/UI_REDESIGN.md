# Keel 界面视觉与交互改造方案（v1）

面向对象：整个桌面外壳 + 全部业务页。目标不是"加装饰"，而是让这套 Fluent 界面从"脚手架观感"变成
"商业桌面软件观感"：层次清楚、密度合适、每屏只有一个主操作、状态可读。

证据来源：`lib/ui/theme.dart`、`lib/ui/tokens.dart`、`lib/ui/shell.dart`、
`lib/ui/widgets/ui_layout.dart`、`lib/ui/pages/dashboard_page.dart`、`lib/app.dart`。
文中所有尺寸为本方案建议值，不是对现有界面的测量值。

---

## 1. 结论摘要

界面"简陋"的根因不是缺颜色，而是四个结构性缺失：

1. **没有明度层次**——画布 `#F6F6F6`、面板 `#FFFFFF`、侧栏 `#FFFFFF`、标签条 `#FFFFFF`，
   四层都是白，卡片只能靠 1px 描边"画"出来，视觉上等于没有表面。
2. **强调色失效**——全站唯一强调色是 Fluent 默认蓝，同时用于导航选中、模块图标底块、版本 pill、
   用户头像、进度环，等于处处强调 = 没有强调。
3. **排版只有 3 级**——`26 / 22 / 14 / 12`，且中文标题带负字距（`letterSpacing: -0.3/-0.4`），
   数字无等宽处理，金额/行数/页码切换时宽度跳动。
4. **横向构件叠了 4 层**——菜单栏 30 + 命令栏 40 + 标签条 38 + 状态栏 28 ≈ **136px**，
   1280×720 @125%（逻辑 1024×576）下内容区只剩约 440px（与 AGENTS.md 记录一致），
   同时"命令栏"显示的是当前页的命令，归属感模糊。

---

## 2. 现状诊断（按影响排序）

| # | 现象（可见证据） | 影响 | 优先级 |
|---|---|---|---|
| 1 | 四层横向 chrome 叠放：`MenuBar` + `CommandBar` + 38px 标签条 + 28px 状态栏（`shell.dart:385–917`） | 720p 下内容区约 440px，表格只能看 8–10 行；窗口越小越难受 | P0 |
| 2 | 所有面都是白（`tokens.dart:33-36`），面板靠 1px 边框区分（`ui_layout.dart:58-64`） | 观感"平、薄、像 demo"，卡片没有"浮起来" | P0 |
| 3 | 强调色处处使用：导航选中、图标底块、pill、头像、进度环（`shell.dart:953, 1125`；`dashboard_page.dart:50,105`） | 强调色失去语义，页面没有视觉焦点 | P0 |
| 4 | 字阶只有 title 26/22、body 14、caption 12；标题负字距（`tokens.dart:69-78`） | 中文标题发紧；层级对比弱，扫读找不到重点 | P0 |
| 5 | 侧栏三段全展开：10 个模块 + 收藏 + 最近（`shell.dart:754-823`），"最近"与标签栏重复；每行常显 12px 星标 | 侧栏需要滚动；星标热区约 20×20，误触；收藏后该行会从"模块"段跳到"收藏"段，列表跳动 | P1 |
| 6 | 选中态只有 10% 主色底 + 主色字，无位置指示（`shell.dart:952-960`） | 白底上几乎看不出当前在哪 | P1 |
| 7 | 命令栏 9 个按钮平铺、无主次，含"关闭标签""主题"（`shell.dart:614-661`） | 主操作不突出；危险/导航/设置混在一起 | P1 |
| 8 | 首页三个状态 pill 与底部状态栏信息完全重复；模块卡 92px 等高平铺、无计数无说明（`dashboard_page.dart:35-133`） | "仪表盘"没有信息，用户点了才知道里面是什么 | P1 |
| 9 | 状态栏常驻版本号 + "数据库就绪"；用户菜单在状态栏右侧（`shell.dart:1275-1352`） | 状态栏当调试信息用；用户入口位置不符合桌面惯例（VS Code/Linear 在左下角） | P2 |
| 10 | 尺寸无规则：图标 12/14/16/18/26、圆角 4/6/8、字号 12.5、hover 透明度 0.05/0.08/0.10 | 细节不一致，是"廉价感"的直接来源 | P2 |

---

## 3. 设计方向

- **风格**：中性灰阶 + 单色强调的"工具型"桌面软件（参考 Linear / VS Code / Azure Portal 的克制感），
  继续用 fluent_ui 组件库，不引入 Material。
- **层次规则**：明度差 > 描边。三层表面（canvas / surface / sunken）× 一档阴影，永远不靠粗边框分块。
- **强调规则**：主色只出现在三处——选中态、主按钮、键盘焦点环。其余状态用语义色（成功/警告/危险）。
- **密度**：控件 32px、表格行 36px、侧栏行 32px、标签 34px。宁可紧凑，不要空旷。
- **层级**：每屏一个主操作（页面头右侧），其余进"更多"。

---

## 4. Design Tokens

### 4.1 颜色（浅色）

| Token | 值 | 用途 | 对比度 |
|---|---|---|---|
| `canvas` | `#F4F6F9` | 页面底 | — |
| `surface` | `#FFFFFF` | 卡片、面板、表格 | — |
| `sunken` | `#FAFBFC` | 表头、工具栏、脚注、只读区 | — |
| `chrome` | `#FBFCFE` | 侧栏、标签条、状态栏 | — |
| `border` | `#E4E7EC` | 默认分割线/描边 1px | — |
| `borderStrong` | `#CDD3DD` | 输入框、需要强调的边界 | — |
| `textPrimary` | `#131720` | 正文/标题 | 17.9:1 on surface |
| `textSecondary` | `#596273` | 次要说明、表头 | 6.1:1 on surface / 5.7:1 on canvas |
| `textTertiary` | `#6B7484` | 占位、辅助（**仅白底**） | 4.7:1 on surface |
| `accent` | `#2C5BE0` | 选中、主按钮、焦点环 | 5.7:1 双向 |
| `accentHover` | `#2549C4` | 主按钮 hover | — |
| `accentSubtle` | `#EDF1FD` | 选中底、图标底块 | 主色字 5.1:1 |
| `success` | `#127E43` / subtle `#E8F5EE` | 就绪、成功 | 5.1:1 |
| `warning` | `#9A6300` / subtle `#FFF4E3` | 降级、待处理 | 5.1:1 |
| `danger` | `#C22B1F` / subtle `#FDECEA` | 错误、破坏性操作 | 5.7:1 |

规则：`textTertiary` 只用于 `surface` 上；画布上用 `textSecondary`（4.35:1 不达标，已验证）。

### 4.2 颜色（深色）

| Token | 值 |
|---|---|
| `canvas` | `#14161B` |
| `surface` | `#1C1F26` |
| `sunken` | `#23272F` |
| `chrome` | `#1A1D23` |
| `border` | `#2E333D` |
| `borderStrong` | `#3C434F` |
| `textPrimary` | `#E8EBF1`（13.8:1） |
| `textSecondary` | `#A2ABBA`（7.1:1） |
| `textTertiary` | `#848DA0`（4.95:1） |
| `accent` | `#7B95FF`（文字/图标，5.96:1） |
| `accentFill` | `#3D62E8`（实心按钮底，白字 5.1:1） |
| `accentSubtle` | `#1E2740` |
| `success` | `#4ECB8B`（8.0:1） |
| `warning` | `#E0A94A`（7.8:1） |
| `danger` | `#FF8A80` |

深色下强调色必须分两个：`accent` 用于文字/图标（要够亮），`accentFill` 用于实心按钮底（要够深，
配白字）。只用一个值必然某一侧对比度不达标。

### 4.3 字阶（中文优先，全站等宽数字）

| 名称 | 字号/行高 | 字重 | 用途 |
|---|---|---|---|
| `display` | 32 / 40 | 600 | 首页 KPI 数值（tabular） |
| `title` | 20 / 28 | 600 | 页面标题（替代现有 22） |
| `subtitle` | 15 / 22 | 600 | 卡片/区块标题 |
| `bodyStrong` | 14 / 22 | 600 | 强调正文、行标题 |
| `body` | 14 / 22 | 400 | 正文、表格单元 |
| `small` | 13 / 20 | 400 | 次要正文、表头、标签条 |
| `caption` | 12 / 16 | 400 | 辅助说明、状态栏 |
| `badge` | 11 / 14 | 500 | 角标、计数 |

- 中文一律 `letterSpacing: 0`；英文标题可用 `-0.2`。
- 所有数字（金额、计数、版本、页码、日期）加 `fontFeatures: [FontFeature.tabularFigures()]`。
- 字体保留 `Microsoft YaHei UI`；如需更统一，可评估 `Noto Sans SC` 内置子集（体积成本待称重）。

### 4.4 间距 / 圆角 / 尺寸 / 阴影

- 间距阶：`2 4 8 12 16 20 24 32 40`（取消现有的 6/10/22/28 这类非阶值；页面顶/底 24，左右 32，
  区块间距 24，卡片内 16，行内 8）。
- 圆角：控件 6、卡片 10、浮层/对话框 12、pill 999。
- 控件高度：compact 28 / default 32 / primary 36；表格行 36；侧栏行 32；标签 34；标题栏 40；状态栏 22。
- 图标：行内 16、导航 20、工具栏 16、chevron 12、空态 40（现在 26，太小）。
- 阴影：卡片 `0 1px 2px rgba(16,24,40,.05), 0 1px 3px rgba(16,24,40,.04)`；
  浮层 `0 8px 24px rgba(16,24,40,.14)`；对话框 `0 16px 40px rgba(16,24,40,.18)`。

---

## 5. 布局结构

### 5.1 外壳（总 chrome 136px → 96px）

```
┌──────────────────────────────────────────────────────────────┐ 40
│ ◆ Keel  工作区            [⌕ 搜索或跳转  Ctrl+K]      — □ ×  │  标题栏（菜单并入）
├───────────────┬──────────────────────────────────────────────┤ 34
│ 数据          │ 仪表盘 × │ 往来单位 × │ 审计 ×                │  标签条（与内容同底色）
│  · 仪表盘     ├──────────────────────────────────────────────┤
│  · 往来单位   │ 往来单位                       [新建] [⋯]      │ 页面头 56
│  · 审计       │ 共 1,284 条 · 已筛选                        │
│ 系统          │ ┌──────────────────────────────────────────┐ │
│  · 备份       │ │ 表格（行高 36，表头 sunken）             │ │
│  · 诊断       │ └──────────────────────────────────────────┘ │
│  · 设置       │                                              │
│ ───────────── │                                              │
│ (头像) 张三    │                                              │
└───────────────┴──────────────────────────────────────────────┘ 22
  状态栏：● 已连接 · 2 个任务进行中 ·                  （仅此三项）
```

- **菜单栏并入标题栏**：文件/视图/工具/窗口/帮助 收进左上角应用名右侧的"⋯ 菜单"按钮，
  保留全部键盘可达性（Alt 打开）。省 30px 且更像现代应用。
- **命令栏改造（已落地版本）**：原 40px 全局命令栏塞了 9 个按钮（首页 / 当前页命令 / 关闭标签 /
  主题 / 搜索），既无主次又与侧栏、页签、菜单重复。改为**32px 页面工具条**只保留当前页命令
  （26px 高、12 号字、hover 才出底色），左侧一行 12px 页面名做定位提示，右端留一个搜索图标；
  首页交给侧栏、关闭标签交给页签上的 ×、主题留在「视图」菜单（快捷键不变）。
  命令区最大 560px，窗口更窄时按 `可用宽度 - 140` 收缩并横向滚动，任何尺寸都不溢出。
  （原方案曾想把命令直接放进页面头右侧，但页面的 `UiPageHeader` 在页面内部、拿不到外壳注册的
  命令，且窄窗口下会与标题抢宽度，故改为工具条。）
- **标签条**：34px、与内容同底色、选中标签白底 + 上方 2px 主色；关闭按钮 hover 才显形；
  支持中键关闭（桌面惯例）；空白处双击 → 打开搜索。
- **状态栏**：22px、只保留 连接状态（可点开诊断）/ 进行中任务（可点开队列）/ 最后同步时间。
  版本号移入"关于"。

### 5.2 侧栏

- 宽度 240（折叠 48）。分组：`数据`（往来单位/审计）、`系统`（备份/诊断/设置）、`示例`（样例页）。
- 分组标签 11px / 500 / `textTertiary` / 大写字距 0.8（中文不改大小写，仅用字重+色区分）。
- 收藏置顶为可折叠组，**去掉"最近"段**（标签条已经是"最近"）。
- 行规格：高 32、圆角 6、左内边距 8、图标 20 与文字间距 10、选中时左缘 3px 主色圆角指示条 +
  `accentSubtle` 底 + 文字 600；hover 为 `rgba(19,23,32,.04)`。
- 星标改为 hover/focus 时显形，占位宽度固定 24，热区 24×24，避免行内跳动。
- 底部固定当前用户（头像 24 + 名字），点击弹菜单（切换用户/锁定/新建用户），
  取代状态栏右侧的用户入口。

### 5.3 页面模板

统一 `UiPageHeader`：标题 20/600 + 一行副标题（数据量/筛选态/更新时间，13px `textSecondary`）
+ 右侧主操作。内容区一律 `canvas` 底 + 卡片 `surface`（圆角 10 + 阴影 + 1px border）。

---

## 6. 组件规格（改前 → 改后）

| 组件 | 现在 | 改为 |
|---|---|---|
| 导航行 | 30px、radius 4、10% 主色底、无指示条 | 32px、radius 6、`accentSubtle` 底 + 左 3px 指示条 + 600 字重 |
| 标签 | 38px、12.5px 字、顶部 2px 主色 | 34px、13px 字、白底选中 + 顶部 2px、hover 才出关闭 |
| 按钮 | 全部同权重 | 三级：primary（实心主色 36px）/ secondary（描边 32px）/ ghost（无边框 32px，用于图标） |
| 面板 | 白底 + 1px 边框 + 表头 4% 主色 | 白底 + 1px `border` + 阴影 sm；表头改 `sunken` 灰（去掉蓝调）、标题 14/600 |
| 表头 | — | `sunken` 底、12px/600 `textSecondary`、行高 36、粘顶、列间 1px `border` |
| 空态 | 26px 图标 + 一行灰字 | 40px 图标（`textTertiary`）+ 一句说明 + 一个主操作按钮 + 一行提示 |
| 加载 | 空白 / `ProgressRing` | 表格骨架 3 行（`sunken` 底 12px 高圆角条）+ 顶部 2px 不确定进度条 |
| 错误 | `InfoBar` 贴顶 | 卡片内 `error` 区：图标 + 原因 + 重试按钮，不遮内容 |
| 状态 pill | 每项都带主色图标 | 中性底 + 语义色小圆点；只有"异常"用彩色 |
| 对话框 | `ContentDialog` 默认 | 宽 480、标题 17/600、内容 14/22、主操作右对齐、危险操作用 danger 实心 |
| 焦点 | Fluent 默认 | 统一 2px 主色焦点环 + 2px offset（自绘 Button 必须显式实现） |

---

## 7. 交互与无障碍

1. **点击热区**：所有图标按钮最小 24×24（现星标/关闭约 20，不达标）。
2. **对比度**：正文 17.9:1、次要 6.1:1、辅助 4.7:1（均 ≥ 4.5）；主按钮白字 5.7:1。
3. **非颜色表达**：状态除颜色外必须有文字或图标（现有状态点已有文案，保持）。
4. **键盘**：`Ctrl+K` 搜索（已有）、`Ctrl+Tab` 切标签（已有）、新增 `Ctrl+W` 中键等价、
   `F6` 在 侧栏/标签/内容 之间跳区、`Esc` 回内容区；焦点顺序 = 侧栏 → 标签 → 页面头 → 主体。
5. **文字缩放**：200% 下侧栏 240 需允许 240→280 自适应；页面头副标题最多 2 行（已有 `maxLines`）。
6. **长文案**：`en` 下侧栏标签平均长 1.6 倍，需 `maxLines:1 + ellipsis`（已有）+ tooltip 补全。
7. **危险操作**：实心 danger 按钮 + 二次确认（已有 `closeGuards` 机制，视觉上补齐）。
8. **状态栏 live region**：任务数变化已有 `liveRegion`，保留。

---

## 8. 实施阶段

| 阶段 | 内容 | 改动文件 | 视觉收益 | 风险 |
|---|---|---|---|---|
| **P0**（半天） | token 层：新色板、字阶、间距/圆角/阴影、控件高度；`theme.dart` 接入 `typography`、`accentColor`、`visualDensity` | `tokens.dart`、`theme.dart` | 全站立即受益（约 70% 观感提升） | 低（保留旧 API 名称做别名，测试不受影响） |
| **P1**（1 天） | 外壳：标题栏合并菜单、命令栏下沉到页面头、标签条 34、侧栏分组 + 选中态 + 星标 hover、状态栏瘦身 | `shell.dart`、`ui_page.dart`（`commands` 渲染位置）、`ui_layout.dart` | 信息架构与密度 | 中（`command_bar_small_window_test` 等需同步改） |
| **P2**（1 天） | 首页重做（KPI + 快捷操作 + 模块卡带说明/计数）、`UiPageHeader`/`UiPanel`/`UiEmpty` 统一 | `dashboard_page.dart`、`ui_layout.dart` | 首页从"目录"变"概览" | 低 |
| **P3**（1–2 天/页） | 逐页精修：审计（冻结列 + 表头）、往来单位（网格密度/斑马纹/编辑态）、备份/诊断（状态与进度） | 各 `*_page.dart` | 一致性 | 中 |

**已落地进度**：P0 全部、P1 命令栏改造、P2 首页、P3 的往来单位 / 审计 / 备份 / 诊断四页，
以及长任务进度条（`UiBusyStrip`：2px 不确定进度 + 一行可读说明，`liveRegion` 播报）。
未做的只有：任务队列暴露百分比后的确定进度、登录保护页之外的表单页精修、以及全站深色与
125% 的真机目视复核与 Narrator/Orca 朗读验收。

建议顺序 P0 → P2 → P1 → P3：先把 token 和首页做出来给用户看到变化，再动外壳结构（结构改动牵动测试最多）。

---

## 9. 对现有测试的影响（必须同步）

- `test/ui/command_bar_small_window_test.dart`：断言命令栏不超宽；P1 取消命令栏后此测试要改为断言
  页面头操作区不超宽。
- `test/ui/page_scroll_test.dart`：依赖 `UiScrollablePage` 阈值与页脚可见性；P1/P3 改高度后需复核。
- `test/ui/customers_grid_semantics_test.dart`：语义区域标签 `t.navCustomers` 必须保留，
  改侧栏/页面头不得移除 `Semantics(container: true)`。
- 每次改动跑：`flutter analyze`（0 项）、`flutter test`（现 200 项）、`python scripts/check_sources.py`、
  `dart format`（无差异）。涉及 Rust 时另跑 `cargo fmt/clippy/test`。
- 标签条高度 38→34、状态栏 28→22 会改变 `integration_test` 的窗口尺寸假设，需要跑一次
  `integration-check.ps1 -Device windows` 复核 7 个入口。

---

## 10. 附录：token 骨架（可直接落地，不依赖 fluent_ui API）

```dart
// lib/ui/design/keel_colors.dart
class KeelColors {
  const KeelColors(this.brightness);
  final Brightness brightness;
  bool get _l => brightness == Brightness.light;

  Color get canvas  => _l ? const Color(0xFFF4F6F9) : const Color(0xFF14161B);
  Color get surface => _l ? const Color(0xFFFFFFFF) : const Color(0xFF1C1F26);
  Color get sunken  => _l ? const Color(0xFFFAFBFC) : const Color(0xFF23272F);
  Color get chrome  => _l ? const Color(0xFFFBFCFE) : const Color(0xFF1A1D23);
  Color get border  => _l ? const Color(0xFFE4E7EC) : const Color(0xFF2E333D);
  Color get textPrimary   => _l ? const Color(0xFF131720) : const Color(0xFFE8EBF1);
  Color get textSecondary => _l ? const Color(0xFF596273) : const Color(0xFFA2ABBA);
  Color get textTertiary  => _l ? const Color(0xFF6B7484) : const Color(0xFF848DA0);
  Color get accent      => _l ? const Color(0xFF2C5BE0) : const Color(0xFF7B95FF);
  Color get accentFill  => _l ? const Color(0xFF2C5BE0) : const Color(0xFF3D62E8);
  Color get accentSubtle=> _l ? const Color(0xFFEDF1FD) : const Color(0xFF1E2740);
  Color get hover       => _l ? const Color(0x0A131720) : const Color(0x14FFFFFF);
}
```

`theme.dart` 接入点（fluent_ui 4.17.0 已确认字段存在）：

```dart
FluentThemeData keelFluentTheme(Brightness brightness) {
  final c = KeelColors(brightness);
  final light = brightness == Brightness.light;
  final base = Typography.fromBrightness(brightness: brightness);
  return FluentThemeData(
    brightness: brightness,
    // AccentColor.swatch 必须含 'normal'，其余键缺省时按 alpha 回退
    accentColor: AccentColor.swatch(
      light
          ? {
              'normal': c.accentFill,          // #2C5BE0
              'light': const Color(0xFF3A66E8),   // hover
              'dark': const Color(0xFF2549C4),    // pressed
              'darker': const Color(0xFF1D3AA0),
              'darkest': const Color(0xFF162C7C),
            }
          : {
              'normal': c.accentFill,          // #3D62E8
              'light': const Color(0xFF5578F0),
              'dark': const Color(0xFF2F51D0),
              'darker': const Color(0xFF25409F),
              'darkest': const Color(0xFF1B2F76),
            },
    ),
    scaffoldBackgroundColor: c.canvas,
    cardColor: c.surface,
    menuColor: c.chrome,
    acrylicBackgroundColor: c.chrome,
    acrylicFallbackColor: c.chrome,
    micaBackgroundColor: c.canvas,
    inactiveBackgroundColor: c.sunken,
    shadowColor: const Color(0x14101828),
    typography: Typography.raw(
      title: base.title?.copyWith(fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600, letterSpacing: 0),
      subtitle: base.subtitle?.copyWith(fontSize: 15, height: 22 / 15, fontWeight: FontWeight.w600),
      bodyStrong: base.bodyStrong?.copyWith(fontSize: 14, height: 22 / 14),
      body: base.body?.copyWith(fontSize: 14, height: 22 / 14, letterSpacing: 0),
      caption: base.caption?.copyWith(fontSize: 12, height: 16 / 12),
      // display / titleLarge / bodyLarge 沿用 base
    ),
  );
}
```

注意：以上签名已对照 fluent_ui 4.17.0 源码确认——`Typography.raw` 的字段为
display/titleLarge/title/subtitle/bodyLarge/bodyStrong/body/caption；
`Typography.fromBrightness({brightness, color})` 提供 Win11 类型阶基础值；
`AccentColor.swatch(Map<String, Color>)` 要求含 `'normal'` 键。
`FluentThemeData` 存在 `typography / accentColor / visualDensity / buttonTheme / shadowColor` 字段。
