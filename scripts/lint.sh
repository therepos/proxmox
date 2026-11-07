#!/usr/bin/env bash
# Lint every script against the rules in AGENTS.md.
#   scripts/lint.sh         report problems, change nothing
#   scripts/lint.sh --fix   first fix what can be fixed safely (line 2 one-liner,
#                           admonition block, q) Quit menus), then report what is left
# CI runs --fix on every PR and push to main and commits the fixes.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

REPO_RAW="https://github.com/therepos/proxmox/raw/main"
oneliner() { printf '# bash -c "$(wget -qLO- %s/%s?$(date +%%s))"' "$REPO_RAW" "$1"; }

errors=0
bad() { printf '[FAIL] %s: %s\n' "$1" "$2"; errors=$((errors + 1)); }

# --- Safe fixes --------------------------------------------------------------
if (( FIX )); then
    for f in apps/installers/*.sh apps/tools/*.sh; do
        [[ -f "$f" ]] || continue
        l2="$(sed -n 2p "$f")"
        want="$(oneliner "$f")"
        # installers always carry the one-liner; tools only if they already had one
        if [[ "$l2" != "$want" ]] && { [[ "$f" == apps/installers/* ]] || [[ "$l2" == '# bash -c "$(wget'* ]]; }; then
            if [[ "$l2" == '# bash -c "$(wget'* ]]; then
                awk -v w="$want" 'NR==2{print w; next} {print}' "$f" > "$f.tmp"
            else
                awk -v w="$want" 'NR==2{print w} {print}' "$f" > "$f.tmp"
            fi
            cat "$f.tmp" > "$f" && rm -f "$f.tmp"
            echo "[FIX ] $f: line 2 one-liner"
        fi
    done
    for f in apps/installers/*.sh; do
        if grep -qE '^\s*echo "\s*q\) Quit' "$f"; then
            sed -i -E 's/^(\s*echo "\s*)q\) Quit/\10) Exit/; s/^(\s*)q\|Q\)/\10|q|Q)/' "$f"
            echo "[FIX ] $f: q) Quit -> 0) Exit"
        fi
    done
    scripts/sync-admonition.sh | sed -n 's/^updated: /[FIX ] admonition block: /p'
fi

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
    l2="$(sed -n 2p "$f")"
    if [[ "$l2" == '# bash -c "$(wget'* && "$l2" != "$(oneliner "$f")" ]]; then
        bad "$f" "line 2 one-liner is wrong (scripts/lint.sh --fix)"
    fi
done

# --- Installers only ---------------------------------------------------------
for f in apps/installers/*.sh; do
    [[ "$(sed -n 2p "$f")" == '# bash -c "$(wget'* ]] || bad "$f" "line 2 must be the wget one-liner (scripts/lint.sh --fix)"
    grep -q 'EUID' "$f"                     || bad "$f" "missing root check"
    grep -qE '^\s*echo "\s*q\) Quit' "$f"   && bad "$f" "menu uses 'q) Quit'; use '0) Exit' (scripts/lint.sh --fix)"
    grep -nE '^\s*echo "\s*0\) ' "$f" | grep -vE '0\) Exit' | while IFS= read -r m; do
        echo "$f:${m%%:*}"; done | grep -q . && bad "$f" "'0)' must be Exit; use the next number for Back"
done

# --- Admonition copies match the source --------------------------------------
scripts/sync-admonition.sh --check >/dev/null || bad "scripts/sync-admonition.sh" "admonition block out of sync (scripts/lint.sh --fix)"

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
