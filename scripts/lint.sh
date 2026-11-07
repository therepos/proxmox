#!/usr/bin/env bash
# Lint every script against the rules in AGENTS.md. Reports only; changes nothing.
# Run before pushing: scripts/lint.sh   (CI runs the same on every PR and push to main)
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

errors=0
bad() { printf '[FAIL] %s: %s\n' "$1" "$2"; errors=$((errors + 1)); }

command -v shellcheck >/dev/null || { echo "[FAIL] shellcheck not installed (apt install shellcheck)"; exit 1; }

# --- Every bash file ---------------------------------------------------------
for f in apps/installers/*.sh apps/tools/*.sh scripts/*.sh; do
    [[ -f "$f" ]] || continue
    bash -n "$f" 2>/dev/null       || bad "$f" "bash syntax error (bash -n)"
    shellcheck -S warning "$f" >/dev/null || bad "$f" "shellcheck warnings (shellcheck -S warning $f)"
done

# --- Installers and tools ----------------------------------------------------
for f in apps/installers/*.sh apps/tools/*.sh; do
    [[ -f "$f" ]] || continue
    grep -q 'set -euo pipefail' "$f"   || bad "$f" "missing 'set -euo pipefail'"
    grep -q '^# >>> admonition' "$f"   || bad "$f" "missing admonition block"
    [[ "$(sed -n 3p "$f")" == "# Purpose: "* ]] || bad "$f" "line 3 must be '# Purpose: ...'"
    if [[ "$(sed -n 2p "$f")" == '# bash -c "$(wget'* ]]; then
        grep -q "/raw/main/${f}?" <(sed -n 2p "$f") || bad "$f" "line 2 one-liner points at a different file"
    fi
done

# --- Installers only ---------------------------------------------------------
for f in apps/installers/*.sh; do
    [[ "$(sed -n 2p "$f")" == '# bash -c "$(wget'* ]] || bad "$f" "line 2 must be the wget one-liner"
    grep -q 'EUID' "$f"                     || bad "$f" "missing root check"
    grep -qE '^\s*echo "\s*q\) Quit' "$f"   && bad "$f" "menu uses 'q) Quit'; use '0) Exit'"
done

# --- Admonition copies match the source --------------------------------------
scripts/sync-admonition.sh --check >/dev/null || bad "scripts/sync-admonition.sh" "admonition block out of sync (run it without --check)"

# --- Python ------------------------------------------------------------------
for f in scripts/*.py; do
    [[ -f "$f" ]] || continue
    python3 -m py_compile "$f" 2>/dev/null || bad "$f" "python syntax error"
done
find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null

if (( errors )); then
    echo "$errors problem(s)."
    exit 1
fi
echo "[ OK ] All scripts pass."
