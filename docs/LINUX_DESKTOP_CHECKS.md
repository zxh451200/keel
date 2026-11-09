# Linux 桌面验收

状态：NOT_EXECUTED。自动构建与 Xvfb 冒烟不关闭视觉、辅助功能、DPI 或打印验收项。

记录本次源码标识、Release 包 SHA-256、发行版、内核、Flutter/Rust 版本、
GTK/Mesa/字体/打印后端版本、桌面环境、显示服务器和显示器缩放。X11 与 Wayland 分开记录；
不支持的组合写 BLOCKED 或 NOT_COVERED，并说明原因。

在安装 README 所列工具链和 Linux 构建依赖的目标机执行：

```powershell
pwsh -NoLogo -NoProfile -File scripts/verify.ps1 -Device linux -BuildRelease -Security
```

首次同步尚未解析的依赖时显式追加 `-ResolveDependencies`，审阅锁文件和自然生成的
FRB/l10n 产物。该命令会保留格式化及生成变更，结果见根目录 `verify-output.txt`。
独立 `poc/grid_columns` 仍需按自己的 README 解析和验证，根应用验证不覆盖该包。

集成执行器每次在 `build/reports/integration-linux-<随机 ID>/` 保留逐入口合并日志
和 `summary.json`。汇总记录设备、CI 提交/运行标识、PowerShell 版本、
开始/结束时间、实际退出码及各入口的 PASS/FAIL/NOT_RUN；
首个失败后不继续运行，后续入口保持 NOT_RUN。Flutter 返回零后仍须通过数据目录
所有权校验和清理，才能将该入口记为 PASS。Linux CI 即使失败也上传已有报告，
若尚未进入集成步骤则不会产生本次集成报告。

执行器自身的独立回归可在没有 Flutter/Rust 的 PowerShell 环境运行：

```powershell
pwsh -NoLogo -NoProfile -File scripts/tests/test_integration_check.ps1
```

该回归使用假 Flutter 检查成功、非零退出、抛异常、环境恢复、独立目录和日志；
不能据此宣布真实 FRB 或桌面验收通过。当前编辑主机缺 PowerShell，尚未执行。

每项结果使用 PASS、FAIL、NOT_EXECUTED、BLOCKED 或 NOT_COVERED；
PASS 必须附实际现象、环境和证据文件，不从脚本退出码推断人工验收结论。

| 场景 | 预期与证据 | 状态 |
| --- | --- | --- |
| Release 启动 | 干净用户目录启动，无开发 SDK；记录包哈希和启动日志 | NOT_EXECUTED |
| 真实桥接 | 逐 entry 隔离集成测试通过；保留终端日志 | NOT_EXECUTED |
| 文件选择 | GTK 选择/取消、重复点击、权限或身份变化；不泄露原始路径 | NOT_EXECUTED |
| 打印 | 按 `PRINTING.md` 验证取消、Unicode、分页、PDF 输出及驱动失败 | NOT_EXECUTED |
| 打印中关闭 | busy 期间退出守卫和窗口移除清理；提交队列与物理完成分别记录 | NOT_EXECUTED |
| 退出与草稿 | 按 `DESKTOP_EXIT_CHECKS.md` 覆盖隐藏草稿、取消退出、重复关闭 | NOT_EXECUTED |
| 退出后释放 | 记录实际 PID，正常退出后进程消失，文件/数据库可重新打开 | NOT_EXECUTED |
| 缩放与跨屏 | 100/125/150/200% 支持组合、字体缩放、跨屏、窗口恢复无裁切 | NOT_EXECUTED |
| 键盘与读屏 | Tab/焦点恢复、工作区命令、高对比度、Orca 标签和状态播报 | NOT_EXECUTED |
| 重启历史 | 中断导出后重启保留 interrupted；不重建旧操作句柄或宣称续传 | NOT_EXECUTED |

如使用 Xvfb，记录其屏幕参数并标注 headless smoke。Wayland 不支持的窗口自动化不能
用 X11/xdotool 结果代替。PDF 输出需记录驱动、页数、字形与文件哈希；
系统对话框返回“提交”不证明物理打印完成。验收失败保留本次日志与截图，再定位原因。
