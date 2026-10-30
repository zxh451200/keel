# Keel

通用桌面 Admin 开发底座：Rust 负责业务与数据，Flutter 负责 Windows/Linux 桌面 UI。

**技术基线与开发规范见 [AGENTS.md](AGENTS.md)，产品需求与详细规范见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)**（按需读取）。本文件只做入口。

## 技术栈（目标基线）

| 层 | 选型 |
|---|---|
| 核心 | Rust stable（`rust-toolchain.toml` 待补） |
| UI | Flutter stable / Dart 3 |
| 桥接 | flutter_rust_bridge 2.x（POC 起点 2.13.0，最终版本 POC 后锁定；生成代码，不手改） |
| 数据库 | SQLite + SQLx |
| 状态 | flutter_riverpod + StatefulWidget |
| 表格 | PlutoGrid（POC 待验收） |
| 国际化 | flutter_localizations + intl + ARB（zh / en） |
| 日志 | tracing + 滚动文件 + 诊断中心 |

## 环境要求

- Windows 10/11 x64
- Visual Studio 2022 Build Tools，勾选「使用 C++ 的桌面开发」
- Flutter stable（`flutter doctor -v` 全绿）
- Rust stable（MSVC toolchain）

## 常用命令

```bash
flutter pub get
flutter_rust_bridge_codegen generate                        # 改 rust/src/api 后必须执行
cd rust && cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test
flutter analyze && flutter test
flutter run -d windows
flutter build windows --release
```

## 数据位置（目标设计，阶段 0 重建后实现）

- 数据库、日志、备份、诊断包放系统应用数据目录：Windows `%APPDATA%\Keel\`，Linux `~/.local/share/keel`
- 程序安装目录只放只读资源，升级不覆盖用户数据。

## 当前状态

2026-10-31：工程代码已全部清空，仓库只保留文档。重建步骤见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) §10 阶段 0（Flutter 项目 + Rust crate + FRB 最小样例 + 工具链与锁文件）。

## 许可

MIT，见 [LICENSE](LICENSE)。第三方依赖许可与随包文件见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) §7。
