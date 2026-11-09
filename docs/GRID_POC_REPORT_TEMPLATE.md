# 网格 POC 报告模板

复制本模板到实际报告目录，逐项记录 PASS / FAIL / NOT RUN；未执行保持 NOT RUN。模板存在不构成验收证据。

| 环境字段 | 实际记录 |
|---|---|
| requirement ID / 版本 / commit / run ID | NOT RUN |
| 执行人 / 日期 / 机器 CPU、RAM、磁盘 | NOT RUN |
| OS / 架构 / 分辨率 / DPI / 字体 | NOT RUN |
| Flutter / Dart / Rust / FRB / SQLite 版本 | NOT RUN |
| 网格组件 / 锁定版本 / LICENSE 正文及哈希 | NOT RUN |
| 构建模式 / 数据来源 / 数据集哈希 | NOT RUN |
| 行数 / 列数 / 行高 / 页大小 / 字段长度 | NOT RUN |
| 筛选 / 排序 / 查询计划 / 重复次数 | NOT RUN |
| 新连接 / 同连接预热 / OS 缓存控制方法 | NOT RUN |

新连接不等于 OS 冷缓存。Python 合成 SQLite 查询与 Rust/FRB/Flutter 端到端结果分开记录。

| 需求 ID | 步骤与预期 | 状态 | 实际结果 / 原始样本 / 证据路径及 SHA-256 |
|---|---|---|---|
| F02/T01 只读列表 | 空/加载/失败/无权限；分页排序；查询变化清除选择 | NOT RUN | NOT RUN |
| T01 固定列 | 横滚前后首列坐标不变，其余列移动 | NOT RUN | NOT RUN |
| T01 列配置 | 稳定列 ID；宽度上下界；未知/重复 ID；至少保留一列；恢复默认；按用户与列表隔离重启恢复；保存失败不报成功 | NOT RUN | NOT RUN |
| T01 多选 | 当前页 Ctrl 切换、Shift 锚点范围、Esc 清空；查询变化清空；复制按可见顺序 | NOT RUN | NOT RUN |
| T01 剪贴板 | 单元格/行/范围；隐藏列策略、列序、TSV 引号/换行、公式防护；行列/字节上限与越界/类型错误定位 | NOT RUN | NOT RUN |
| T01 独立编辑 fixture | 文本/整数/日期时间/枚举；Enter 提交、Esc 取消、Tab 移动；UI/Rust 双校验；失败保留草稿与脏关闭保护；审计仍只读且拒绝粘贴 | NOT RUN | NOT RUN |
| T01 查询性能 | 10k/100k/1m 分别记录 count 正确性、首屏/翻页/筛选/排序延迟、原始样本及汇总 | NOT RUN | NOT RUN |
| T01 虚拟化 | 记录实际加载行数、CPU、峰值内存；不得全库送入 Dart | NOT RUN | NOT RUN |
| P02 生命周期 | 开/筛选/切换/隐藏/关/重开；内存、任务/计时器/订阅数及释放 | NOT RUN | NOT RUN |
| U03/U04 平台 | Windows 与目标 Linux；剪贴板互通、键盘焦点、窄窗口、字体/DPI | NOT RUN | NOT RUN |
| G01/G03 准入 | 依赖锁定、许可正文、两平台构建/冒烟 | NOT RUN | NOT RUN |

组件准入 / 收缩范围 / 换组件结论：NOT RUN。
阻断项、责任人、复测条件：NOT RUN。不得仅凭 SQLite 基准放行组件；正式结论附实际证据。
