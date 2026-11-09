# ADR-010：依赖许可治理

- 日期：2026-11-02
- 状态：沿用已选许可与供应链政策；检查配置已有，当前新增依赖及完整发行物复核未完成。

## 背景与依据

依据 `AGENTS.md` §2、§10，以及 `docs/REQUIREMENTS.md` §4.4、§7、§9。Keel 自身以 MIT 发布，第三方仍按各自许可履约；包元数据、扫描绿灯和项目不开源发布到包仓库均不能代替许可证义务。

核对实现：`rust/deny.toml`、`scripts/security-check.sh`、`.github/workflows/{ci,release}.yml`、`.github/dependabot.yml`、`THIRD_PARTY_NOTICES`、`scripts/release_evidence.py`。

## 已选设计与当前实现

1. 优先 MIT、Apache-2.0、BSD-2/3-Clause，不引入需商业授权的 UI 控件。GPL/AGPL、商业双许可、附加限制或授权不明的代码/素材不自动通过，须书面审查；版本与许可变化时重审。
2. 审查覆盖直接/传递依赖、原生库、字体图标素材、vendored 代码及开发构建工具。查锁定版本内 LICENSE 正文、版权与 NOTICE，同时核对来源、维护状态、漏洞及构建期执行能力。publish_to: none 不豁免审查，开发工具不随包也不豁免扫描。
3. 正式依赖以 Cargo.lock、pubspec.lock 和工具链记录为依据；新增依赖说明必要性并按既有流程更新需求依赖清单，升级单独提交和测试。默认来源 crates.io、pub.dev 或官方发布渠道；Git/path/二进制覆盖需说明、审查与适当锁定，不能默用开发机覆盖。
4. cargo-deny 配置检查 Windows/Linux x86_64 目标及 all-features，拒绝未知 registry/Git 和通配依赖；重复版本当前是 warn，不是 deny。许可证 allow 为显式清单，其中包括 MPL-2.0；MPL-2.0 有文件级 copyleft 义务，不能因进入清单便称其无条件宽松或忽略分发义务。本 ADR 不改变现有 allow，具体使用仍按正文与分发方式复核。
5. security-check.sh 汇总 cargo-license、cargo-deny、cargo-audit、Dart 依赖及 lock 来源卫生检查。退出码 0 表示脚本适用检查通过，1 为失败/缺必需工具，3 为公告判定不完整；离线缓存的 PARTIAL/UNSURE 不得发布放行。
6. OSV 扫描两份 lock，gitleaks 脱敏扫描 Git 历史；本地脚本缺少这两项仅 SKIP，所以本地退出 0 不等于完整发布门禁通过。CI 配置安装两者并校验固定版本下载物 SHA-256；Action 固定完整 commit SHA，Dependabot 每周检查 cargo、pub 和 github-actions，更新仍须复核与 CI。
7. 报告写入忽略目录 build/reports，CI artifact 保留 30 天。发行物必须携带 LICENSE、THIRD_PARTY_NOTICES、Flutter NOTICES，并保留依赖/许可证报告及适用例外记录。公告例外记录编号、影响分析、负责人和复查日期，不长期无说明忽略。

## 替代方案与后果

| 方案 | 取舍与后果 |
|---|---|
| 只审直接依赖或 package license 字段 | 漏掉传递、原生和资源条款；采用锁定版本正文审查加自动检查。 |
| 只靠人工或只靠扫描 | 前者易漏更新，后者不能解释复杂授权；两者并行，高风险/未知许可人工复核。 |
| 因离线公告不可用而放行 | 无法判断当前风险；保留不完整状态并在可联网受控 CI 重跑。 |
| 为构建成功放宽来源或全局忽略告警 | 降低可追溯性；沿用显式来源限制和带负责人/期限的例外。 |

该设计增加依赖升级和发行整理成本，也使许可证、来源和公告问题可追溯；MIT 发布并不意味着所有第三方都可按 MIT 再许可，自动清单不能构成法律结论。

## 未验证、缺口与待外部决策

- THIRD_PARTY_NOTICES 的 2026-11-01 结论主要对应既有锁定组合；当前新增直接依赖尚待解析锁定，不能据旧清单宣称当前完整依赖图已获许可或安全放行。
- SPDX 生成器使用 Cargo 元数据中的 license，Dart 条目保留 NOASSERTION；这是候选依赖/文件证据，不能替代正文核验、完整许可证分析或经验证的 SBOM 合规结论。
- 当前 Cargo 扫描工具安装使用 --locked，但未逐个指定工具版本；Rust stable 也非精确版本锁定。构建工具可复现程度仍需后续复核，不能把 Action SHA 固定推广到全部工具。
- Dart/Flutter、原生库、品牌资源授权记录与完整 NOTICE 覆盖待复核；不明/高风险许可及 MPL 具体分发义务由维护者和必要的法律审查明确，本 ADR 不授予新例外。
- 本次未执行扫描或下载依赖；本机缺少 Cargo/Flutter，且本副本没有 Git 元数据可供完整历史密钥扫描。真实 CI 及发行归档保留安排需在发布前落实。
