# Keel

通用桌面 Admin 开发底座：Rust 负责业务与数据，Flutter 负责 Windows/Linux 桌面 UI。

**技术基线与开发规范见 [AGENTS.md](AGENTS.md)，产品需求与详细规范见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)**（按需读取）。本文件只做入口。

## 技术栈（目标基线）

| 层 | 选型 | 现状 |
|---|---|---|
| 核心 | Rust stable（`rust-toolchain.toml` 已锁 stable + rustfmt/clippy） | 可用 |
| UI | Flutter stable / Dart 3 | 可用（Flutter 3.47.8 实测） |
| 桥接 | flutter_rust_bridge 2.13.0（codegen 与运行时同版本，生成代码不手改） | 已验证：同步字符串 / 同步结构体 / 异步结构体三类调用（2026-11-01） |
| 异步 | tokio（直接依赖，锁 1.54.1，仅 `time` feature；runtime 由 FRB 创建） | 已验证 |
| 数据库 | SQLite + SQLx | 未引入，阶段 2 POC |
| 状态 | flutter_riverpod + StatefulWidget | 未引入，阶段 1 |
| 表格 | PlutoGrid（POC 待验收） | 未引入，阶段 2 |
| 国际化 | flutter_localizations + intl + ARB（zh / en） | 未引入，阶段 1；当前样例页文案为硬编码，属已知待办 |
| 日志 | tracing + 滚动文件 + 诊断中心 | 未引入 |

## 环境要求

- Windows 10/11 x64
- Visual Studio 2022 Build Tools，勾选「使用 C++ 的桌面开发」
- Flutter stable（`flutter doctor -v` 全绿）
- Rust stable（MSVC toolchain）
- flutter_rust_bridge_codegen 2.13.0（`cargo install flutter_rust_bridge_codegen --locked`）
- 依赖治理工具（`scripts/security-check.sh` 会检查并给出安装命令）：
  `cargo install cargo-license cargo-deny cargo-audit --locked`

## 常用命令

```bash
flutter pub get
flutter_rust_bridge_codegen generate                        # 改 rust/src/api 后必须执行
cd rust && cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test
flutter analyze && flutter test
bash scripts/security-check.sh                              # 许可证/来源/重复依赖/公告，报告进 build/reports/
flutter test integration_test -d windows                    # 真加载 Rust 动态库的桥接端到端
cd rust && sqlx migrate add -s <描述>                       # 新建迁移（引入 SQLx 后），必须带 -s 走顺序编号
flutter gen-l10n                                            # 改 ARB 后
flutter run -d windows
flutter build windows --release
```

`scripts/security-check.sh` 退出码：`0` 全部通过；`1` 存在违规或缺工具；`3` 无违规但 RustSec 公告库取不到
（本机网络受限），此时发布门禁不放行，须在能联网的 CI 重跑。

## 数据位置（目标设计，尚未实现）

- 数据库、日志、备份、诊断包放系统应用数据目录：Windows `%APPDATA%\Keel\`，Linux `~/.local/share/keel`
- 程序安装目录只放只读资源，升级不覆盖用户数据。

## 当前状态

2026-11-01：阶段 0 主体完成。Flutter Windows 工程 + Rust crate + FRB 2.13.0 骨架可构建可运行，
同步字符串 / 同步结构体 / 异步结构体三类桥接在 `flutter test integration_test -d windows` 真实构建下通过；
`rust-toolchain.toml`、`Cargo.lock`、`pubspec.lock`、`THIRD_PARTY_NOTICES`、`rust/deny.toml`、
`scripts/security-check.sh`、`.gitattributes` 均已入库。

未完项：CI 与 secret scanning / SBOM / OSV-Scanner（远端为 GitHub，CI 形态待确认）；
数据网格与 SQLite+SQLx 选型验证（需求文档 §6、阶段 2）；界面文案进 ARB 与主题（阶段 1）。

## 许可

MIT，见 [LICENSE](LICENSE)。第三方依赖许可与随包文件见 [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) §7。
