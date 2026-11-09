#!/usr/bin/env bash
# Local: optional OSV/gitleaks may SKIP. --strict: every required check must PASS.
# Reports and machine-readable summary are retained per run, including failures.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Windows 开发机常只有 python，且 PATH 里的 python3 可能是商店占位 stub
# （command -v 能找到但它只会打印提示并退出），因此实际运行一次验证可用性。
if command -v python3 >/dev/null 2>&1 && python3 -c "" 2>/dev/null; then
  exec python3 -B "$ROOT/scripts/security_check.py" "$@"
fi
exec python -B "$ROOT/scripts/security_check.py" "$@"
