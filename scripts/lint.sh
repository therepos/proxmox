#!/usr/bin/env bash
# Purpose: Check scripts against AGENTS.md and fix what is safe to fix
# =============================================================================
# Usage:
#   scripts/lint.sh                    check all scripts, change nothing
#   scripts/lint.sh --fix              also fix bootstrap, admonition, menu
#   scripts/lint.sh --changed <base>   only scripts changed since <base>
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FIX=0
BASE=""
while (( $# )); do
    case "$1" in
        --fix)     FIX=1 ;;
        --changed) BASE="${2:?--changed needs a base, e.g. origin/main}"; shift ;;
        *)         echo "Unknown option '$1'"; exit 2 ;;
    esac
    shift
done

# Files that change the rules for every script: when one changes, check everything.
FULL_CHECK_TRIGGERS=(scripts/sync-blocks.sh scripts/lint.sh .github/workflows/ci-lint.yml)

ALL_APPS=(apps/*.sh)
ALL_HELPERS=(scripts/*.sh)
ALL_PY=(scripts/*.py)

if [[ -n "$BASE" ]]; then
    mapfile -t CHANGED < <({ git diff --name-only --diff-filter=ACMR "$BASE"...HEAD
                             git diff --name-only --diff-filter=ACMR HEAD
                             git ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
    full=0
    for t in "${FULL_CHECK_TRIGGERS[@]}"; do
        printf '%s\n' "${CHANGED[@]}" | grep -qx "$t" && { full=1; echo "[INFO] $t changed: checking every script"; }
    done
    if (( ! full )); then
        APPS=(); HELPERS=(); PY=()
        for f in "${CHANGED[@]}"; do
            [[ -f "$f" ]] || continue
            case "$f" in
                apps/*.sh)                            APPS+=("$f") ;;
                scripts/*.sh)                         HELPERS+=("$f") ;;
                scripts/*.py)                         PY+=("$f") ;;
            esac
        done
        echo "[INFO] Checking $(( ${#APPS[@]} + ${#HELPERS[@]} + ${#PY[@]} )) changed script(s) since $BASE"
    fi
fi
if [[ -z "$BASE" ]] || (( full )); then
    APPS=("${ALL_APPS[@]}"); HELPERS=("${ALL_HELPERS[@]}"); PY=("${ALL_PY[@]}")
fi

REPO_RAW="https://github.com/therepos/proxmox/raw/main"
oneliner() { printf '# bash -c "$(wget -qLO- %s/%s?$(date +%%s))"' "$REPO_RAW" "$1"; }

errors=0
bad() { printf '[FAIL] %s: %s\n' "$1" "$2"; errors=$((errors + 1)); }

# --- Safe fixes --------------------------------------------------------------
if (( FIX )); then
    for f in "${APPS[@]}"; do
        [[ -f "$f" ]] || continue
        l2="$(sed -n 2p "$f")"
        want="$(oneliner "$f")"
        # installers always carry the bootstrap; tools only if they already had one
        if [[ "$l2" != "$want" ]] && { [[ "$f" == apps/setup-* ]] || [[ "$l2" == '# bash -c "$(wget'* ]]; }; then
            if [[ "$l2" == '# bash -c "$(wget'* ]]; then
                awk -v w="$want" 'NR==2{print w; next} {print}' "$f" > "$f.tmp"
            else
                awk -v w="$want" 'NR==2{print w} {print}' "$f" > "$f.tmp"
            fi
            cat "$f.tmp" > "$f" && rm -f "$f.tmp"
            echo "[FIX ] $f: bootstrap"
        fi
    done
    for f in "${APPS[@]}"; do
        [[ "$f" == apps/setup-* ]] || continue
        if grep -qE '^\s*echo "\s*q\) Quit' "$f"; then
            sed -i -E 's/^(\s*echo "\s*)q\) Quit/\10) Exit/; s/^(\s*)q\|Q\)/\10|q|Q)/' "$f"
            echo "[FIX ] $f: q) Quit -> 0) Exit"
        fi
    done
    for f in "${APPS[@]}"; do
        if grep -qE '^\s*menu "' "$f" && ! grep -qx '# >>> menu' "$f"; then
            awk '{print} /^# <<< admonition$/{print "# >>> menu"; print "# <<< menu"}' "$f" > "$f.tmp"
            cat "$f.tmp" > "$f" && rm -f "$f.tmp"
            echo "[FIX ] $f: added menu block"
        fi
    done
    scripts/sync-blocks.sh | sed -n 's/^updated: /[FIX ] shared blocks: /p'
fi

command -v shellcheck >/dev/null || { echo "[FAIL] shellcheck not installed (apt install shellcheck)"; exit 1; }

# --- Every bash file ---------------------------------------------------------
for f in "${APPS[@]}" "${HELPERS[@]}"; do
    [[ -f "$f" ]] || continue
    bash -n "$f" 2>/dev/null       || bad "$f" "bash syntax error (bash -n)"
    shellcheck -S warning "$f" >/dev/null || bad "$f" "shellcheck warnings (shellcheck -S warning $f)"
done

# --- Layout: scripts live in apps/ -------------------------------------------
shopt -s nullglob
for f in *.sh *.py *.ps1; do bad "$f" "scripts belong in apps/ (or scripts/ for repo helpers), not the root"; done
shopt -u nullglob

# --- Installers and tools ----------------------------------------------------
for f in "${APPS[@]}"; do
    [[ -f "$f" ]] || continue
    [[ "$f" =~ ^apps/(setup|report|backup|create)-[a-z0-9]+\.sh$ ]] || bad "$f" "name must be <action>-<subject>.sh (setup, report, backup, create)"
    grep -q 'set -euo pipefail' "$f"   || bad "$f" "missing 'set -euo pipefail'"
    grep -qx '# >>> admonition' "$f" || bad "$f" "missing admonition block"
    [[ "$(sed -n 3p "$f")" == "# Purpose: "* ]] || bad "$f" "line 3 must be '# Purpose: ...'"
    awk '/^[[:space:]]*echo "=================+"$/ { if (NR - last <= 2) { found=1 } last=NR } END { exit !found }' "$f" \
        && bad "$f" "title between two ==== lines: use banner \"Title\""
    if grep -qx '# >>> shortcut' "$f"; then
        grep -qx "SCRIPT_URL=\"https://github.com/therepos/proxmox/raw/main/$f\"" "$f" \
            || bad "$f" "shortcut block needs SCRIPT_URL=\"https://github.com/therepos/proxmox/raw/main/$f\""
    fi
    l2="$(sed -n 2p "$f")"
    if [[ "$l2" == '# bash -c "$(wget'* && "$l2" != "$(oneliner "$f")" ]]; then
        bad "$f" "bootstrap (line 2) is wrong (scripts/lint.sh --fix)"
    fi
done

# --- Installers only ---------------------------------------------------------
for f in "${APPS[@]}"; do
    [[ "$f" == apps/setup-* ]] || continue
    [[ "$(sed -n 2p "$f")" == '# bash -c "$(wget'* ]] || bad "$f" "line 2 must be the bootstrap (scripts/lint.sh --fix)"
    grep -q 'EUID' "$f"                     || bad "$f" "missing root check"
    grep -qE '^\s*echo "\s*q\) Quit' "$f"   && bad "$f" "menu uses 'q) Quit'; use '0) Exit' (scripts/lint.sh --fix)"
    grep -nE '^\s*echo "\s*0\) ' "$f" | grep -vE '0\) Exit' | while IFS= read -r m; do
        echo "$f:${m%%:*}"; done | grep -q . && bad "$f" "'0)' must be Exit; use the next number for Back"
done

# --- Shared-block copies match the source (all scripts; fast) ----------------
scripts/sync-blocks.sh --check >/dev/null || bad "scripts/sync-blocks.sh" "shared blocks out of sync (scripts/lint.sh --fix)"

# --- Menu helper: every option has a case branch ------------------------------
for f in "${APPS[@]}"; do
    grep -qE '^\s*menu "' "$f" || continue
    grep -qx '# >>> menu' "$f" || bad "$f" "calls menu but has no menu block (scripts/lint.sh --fix)"
    while IFS= read -r msg; do bad "$f" "$msg"; done < <(python3 - "$f" <<'PY'
import re, shlex, sys
src = open(sys.argv[1]).read().replace("\\\n", " ")
lines = src.split("\n")
for i, line in enumerate(lines):
    if not re.match(r'\s*menu "', line):
        continue
    names = [o.split("|")[0] for o in shlex.split(line.strip())[1:]]
    body = []
    for l in lines[i + 1:]:
        body.append(l)
        if re.match(r"\s*esac\b", l):
            break
    text = "\n".join(body)
    if 'case "$CHOICE" in' not in text:
        print(f"line {i+1}: menu is not followed by case \"$CHOICE\" in")
        continue
    for n in names:
        pat = r'(^|[\s|(])("' + re.escape(n) + r'"|' + re.escape(n) + r')\s*[|)]'
        if not re.search(pat, text, re.M):
            print(f"line {i+1}: menu option '{n}' has no case branch")
PY
)
done

# --- Headers (AGENTS.md "Documentation") -------------------------------------
FENCE='# ============================================================================='
# header_ok <file> <first-fence-line>: fence on that line; any comment block right
# after it must end with a closing fence
header_ok() {
    local f="$1" n="$2" last=""
    [[ "$(sed -n "${n}p" "$f")" == "$FENCE" ]] || { bad "$f" "line $n must be the header fence"; return; }
    last="$(awk -v s=$((n + 1)) 'NR>=s { if ($0 ~ /^#/) l=$0; else exit } END { print l }' "$f")"
    [[ -z "$last" || "$last" == "$FENCE" ]] || bad "$f" "header comment block must end with a fence"
}
for f in "${APPS[@]}"; do
    [[ -f "$f" ]] && header_ok "$f" 4
done
for f in "${HELPERS[@]}" "${PY[@]}"; do
    [[ -f "$f" ]] || continue
    [[ "$(sed -n 2p "$f")" == "# Purpose: "* ]] || bad "$f" "line 2 must be '# Purpose: ...'"
    header_ok "$f" 3
    [[ "$(sed -n 4p "$f")" == "# Usage:" ]] || bad "$f" "line 4 must be '# Usage:'"
    # Usage entries are one line each: a continuation line (deep indent, no command) means wrapping
    awk 'NR>4 && /^# =/ {exit} NR>4 && /^#           *[^ ]/ {found=1} END {exit !found}' "$f" \
        && bad "$f" "Usage entries must be one line each (no wrapping)"
done

# --- Python ------------------------------------------------------------------
for f in "${PY[@]}"; do
    [[ -f "$f" ]] || continue
    python3 -m py_compile "$f" 2>/dev/null || bad "$f" "python syntax error"
done
find . -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null

if (( errors )); then
    echo "$errors problem(s)."
    exit 1
fi
echo "[ OK ] All scripts pass."
