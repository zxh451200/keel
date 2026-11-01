#!/usr/bin/env bash
# 依赖许可证、来源与安全公告检查（docs/REQUIREMENTS.md §7.3、§7.4）。
# 报告写入 build/reports/（已 gitignore）；任一必查项失败即以非零码退出。
#
# 需要的工具（缺失时打印安装命令并判定失败）：
#   cargo install cargo-license --locked
#   cargo install cargo-deny  --locked
#   cargo install cargo-audit --locked
# 可选工具（存在则执行，缺失只提示 SKIP；CI 里固定版本 + SHA-256 校验后安装）：
#   OSV-Scanner  https://google.github.io/osv-scanner/installation/   （扫两个 lock 文件）
#   gitleaks     https://github.com/gitleaks/gitleaks                  （扫 git 历史的密钥）
#
# 公告类检查需要访问 https://github.com/RustSec/advisory-db。本机取不到时：
#   cargo-audit 降级为 --no-fetch（用本地缓存公告库），结果标 PARTIAL；
#   cargo-deny 的公告检查没有离线开关，标 UNSURE（不当作通过）。
# 退出码：0 全部通过 / 1 存在违规或缺工具 / 3 无违规但公告类检查未能完成判定（发布不放行）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT/rust"
REPORT_DIR="$ROOT/build/reports"
FAILED=0
DEGRADED=0

mkdir -p "$REPORT_DIR"

# run <工作目录> <标签> <报告文件> <命令...>
run() {
  local dir="$1" label="$2" report="$3"
  shift 3
  if (cd "$dir" && "$@" >"$REPORT_DIR/$report" 2>&1); then
    echo "PASS  $label  -> build/reports/$report"
  else
    echo "FAIL  $label  -> build/reports/$report"
    FAILED=1
  fi
}

# require <命令> <安装提示>
require() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  echo "FAIL  缺少 $1；安装：$2"
  FAILED=1
  return 1
}

# 本地公告库的最近更新日期（cargo-audit 缓存目录按 url 哈希命名）
advisory_db_date() {
  local db
  for db in "$HOME"/.cargo/advisory-db/*/; do
    [ -d "$db/.git" ] || continue
    git -C "$db" log -1 --date=short --pretty=%cd 2>/dev/null && return 0
  done
  echo unknown
}

# 只认「公告库本身不可用」的特征串。不能用宽泛的 fetch 关键字：
# cargo-audit 正常工作时也会打印 "Fetching advisory database"，
# 那样会把真实的漏洞判定误当成网络问题（2026-11-01 CI 首跑就是被这里误导的）。
audit_db_issue() {
  grep -Eqi "couldn't fetch advisory database|failed to prepare (clone|fetch)|Refusing to initialize the non-empty directory|Failed to connect|unable to access|error sending request|error loading advisory database" "$1"
}

if require cargo-license "cargo install cargo-license --locked"; then
  run "$RUST_DIR" "Rust 依赖与许可证清单" rust-licenses.txt cargo license
fi

if require cargo-deny "cargo install cargo-deny --locked"; then
  run "$RUST_DIR" "cargo-deny licenses" cargo-deny-licenses.txt cargo deny check licenses
  run "$RUST_DIR" "cargo-deny bans+sources" cargo-deny-bans-sources.txt cargo deny check bans sources
  if (cd "$RUST_DIR" && cargo deny check advisories >"$REPORT_DIR/cargo-deny-advisories.txt" 2>&1); then
    echo "PASS  cargo-deny advisories  -> build/reports/cargo-deny-advisories.txt"
  elif grep -qiE "failed to fetch|unable to access|Failed to connect" "$REPORT_DIR/cargo-deny-advisories.txt"; then
    # cargo-deny 没有离线开关：公告库取不到时无法判定，不能当作通过。
    echo "UNSURE  cargo-deny advisories 无法更新公告库（本机网络受限），本项未完成判定"
    DEGRADED=1
  else
    echo "FAIL  cargo-deny advisories -> build/reports/cargo-deny-advisories.txt"
    FAILED=1
  fi
fi

if require cargo-audit "cargo install cargo-audit --locked"; then
  if (cd "$RUST_DIR" && cargo audit >"$REPORT_DIR/cargo-audit.txt" 2>&1); then
    echo "PASS  cargo-audit (RustSec，在线公告库)  -> build/reports/cargo-audit.txt"
  elif audit_db_issue "$REPORT_DIR/cargo-audit.txt"; then
    # 公告库取不到/目录不可用：降级到本地缓存，但这不是「通过」。
    db_date="$(advisory_db_date)"
    echo "WARN  cargo-audit 无法取得可用公告库（截至本地 $db_date），尝试离线判定"
    if (cd "$RUST_DIR" && cargo audit --no-fetch >"$REPORT_DIR/cargo-audit-offline.txt" 2>&1); then
      echo "PARTIAL  cargo-audit 按离线公告库通过（截至 $db_date）-> build/reports/cargo-audit-offline.txt"
      DEGRADED=1
    else
      echo "UNSURE  cargo-audit 离线也无法判定（没有本地公告库）；本项未完成 -> build/reports/cargo-audit-offline.txt"
      DEGRADED=1
    fi
  else
    echo "FAIL  cargo-audit (RustSec) -> build/reports/cargo-audit.txt"
    sed -n '1,12p' "$REPORT_DIR/cargo-audit.txt"
    FAILED=1
  fi
fi

run "$ROOT" "Dart 依赖清单" dart-deps.txt flutter pub deps --style=list

# OSV-Scanner：Cargo.lock 与 pubspec.lock 的第二数据源（2.7.0 实测两种 lock 都能解析）。
# CI 里用固定版本 + SHA-256 校验后的二进制，放在 PATH 上由本脚本调用。
if command -v osv-scanner >/dev/null 2>&1; then
  run "$ROOT" "osv-scanner" osv-scan.txt \
    osv-scanner --lockfile=rust/Cargo.lock --lockfile=pubspec.lock \
    --output=build/reports/osv-scan.json
else
  echo "SKIP  osv-scanner 未安装（可选；发布前在 CI 中固定版本运行）"
fi

# secret scanning：扫描 git 历史，报告中不打印明文。
if command -v gitleaks >/dev/null 2>&1; then
  run "$ROOT" "gitleaks（密钥扫描）" gitleaks.txt gitleaks detect --source . --redact
else
  echo "SKIP  gitleaks 未安装（可选；CI 中固定版本运行）"
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "结果：存在失败项，逐项查看 build/reports/"
  exit 1
fi
if [ "$DEGRADED" -ne 0 ]; then
  echo "结果：无违规，但有检查项因网络受限未能完成判定（UNSURE / PARTIAL）。"
  echo "      发布门禁不放行，须在能访问 RustSec 公告库的 CI 重跑本脚本。"
  exit 3
fi
echo "结果：全部通过"
