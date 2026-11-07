#!/usr/bin/env bash
# Sync the admonition block (ok/info/warn/fail) into every script's marked region.
# =============================================================================
# The installer scripts are standalone (the admonition block lives physically inside
# each), but we still want a single place to edit the style. This is that place:
#
#   1. Edit the BLOCK below
#   2. Run this script
#
# It replaces whatever sits between these markers in each apps/installers/*.sh and apps/tools/*.sh:
#       # >>> admonition ... >>>
#       ...managed content...
#       # <<< admonition <<<
# Files without the markers are left untouched. Run with --check to verify
# everything is in sync (non-zero exit if not) — handy for CI/pre-commit.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Canonical block ---------------------------------------------------------
BLOCK_TEXT=$(cat <<'BLOCK'
if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }
BLOCK
)
BLOCK=$(mktemp)
trap 'rm -f "$BLOCK"' EXIT
printf '%s\n' "$BLOCK_TEXT" > "$BLOCK"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

drift=0
changed=0
for f in "$ROOT"/apps/installers/*.sh "$ROOT"/apps/tools/*.sh; do
    [[ -f "$f" ]] || continue
    grep -q '# >>> admonition' "$f" || continue
    awk -v blockfile="$BLOCK" '
        BEGIN { n=0; while ((getline l < blockfile) > 0) blk[n++]=l; close(blockfile) }
        /# >>> admonition/ { print; for (i=0;i<n;i++) print blk[i]; skip=1; next }
        /# <<< admonition/ { skip=0; print; next }
        !skip { print }
    ' "$f" > "$f.tmp"

    if cmp -s "$f" "$f.tmp"; then
        rm -f "$f.tmp"
    elif [[ $CHECK -eq 1 ]]; then
        rm -f "$f.tmp"
        echo "DRIFT: $(basename "$f")"
        drift=1
    else
        mv "$f.tmp" "$f"
        echo "updated: $(basename "$f")"
        changed=1
    fi
done

if [[ $CHECK -eq 1 ]]; then
    [[ $drift -eq 0 ]] && { echo "All in sync."; exit 0; } || { echo "Out of sync — run scripts/sync-admonition.sh"; exit 1; }
fi
[[ $changed -eq 0 ]] && echo "All in sync."
exit 0
