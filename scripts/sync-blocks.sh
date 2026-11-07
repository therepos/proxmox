#!/usr/bin/env bash
# Purpose: Copy the shared blocks (admonition, menu) into every installer and tool
# =============================================================================
# Usage:
#   scripts/sync-blocks.sh           update every script's copy of each block
#   scripts/sync-blocks.sh --check   report scripts that differ, change nothing
#
#   Edit a block below, then run this (or scripts/lint.sh --fix).
#   A script receives a block only between its markers:
#     # >>> <name> (managed by scripts/sync-blocks.sh — do not edit here) >>>
#     # <<< <name> <<<
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Blocks ------------------------------------------------------------------
BLOCK_NAMES=(admonition menu)

# admonition: ok/info/warn/fail output (every script)
# shellcheck disable=SC2034  # read via ${!var} below
BLOCK_admonition=$(cat <<'BLOCK'
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

# menu: numbered menu (scripts with a menu; needs the admonition block above it)
#   menu "Install" "Status|shows what is running" "Back"
#   case "$CHOICE" in Install) ... ;; Status) ... ;; Back) ... ;; esac
# Numbers, "0) Exit" and the prompt range are generated. 0 or no terminal exits.
# shellcheck disable=SC2034  # read via ${!var} below
BLOCK_menu=$(cat <<'BLOCK'
menu() {
  local o name desc i=1 w=0 pick
  { true </dev/tty; } 2>/dev/null || { warn "No terminal for the menu."; exit 0; }
  for o in "$@"; do name="${o%%|*}"; (( ${#name} > w )) && w=${#name}; done
  echo ""
  for o in "$@"; do
    name="${o%%|*}"; desc=""; [[ "$o" == *"|"* ]] && desc="${o#*|}"
    if [[ -n "$desc" ]]; then printf '  %d) %-*s  %s\n' "$i" "$w" "$name" "$desc"
    else printf '  %d) %s\n' "$i" "$name"; fi
    i=$((i + 1))
  done
  echo "  0) Exit"
  echo ""
  while true; do
    read -rp "  Choose [0-$#]: " pick </dev/tty || exit 0
    [[ "$pick" == "0" ]] && exit 0
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= $# )); then
      CHOICE="${!pick}"; CHOICE="${CHOICE%%|*}"; return 0
    fi
    warn "Choose a number from 0 to $#."
  done
}
BLOCK
)

# --- Sync --------------------------------------------------------------------
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

TMP_BLOCK=$(mktemp)
trap 'rm -f "$TMP_BLOCK"' EXIT

drift=0
changed=0
for f in "$ROOT"/apps/installers/*.sh "$ROOT"/apps/tools/*.sh; do
    [[ -f "$f" ]] || continue
    cp "$f" "$f.new"
    for b in "${BLOCK_NAMES[@]}"; do
        grep -q "^# >>> $b " "$f.new" || continue
        var="BLOCK_$b"
        printf '%s\n' "${!var}" > "$TMP_BLOCK"
        awk -v blockfile="$TMP_BLOCK" -v b="$b" '
            BEGIN { n=0; while ((getline l < blockfile) > 0) blk[n++]=l; close(blockfile) }
            $0 ~ "^# >>> " b " " { print; for (i=0;i<n;i++) print blk[i]; skip=1; next }
            $0 ~ "^# <<< " b " "  { skip=0; print; next }
            !skip { print }
        ' "$f.new" > "$f.tmp" && mv "$f.tmp" "$f.new"
    done

    if cmp -s "$f" "$f.new"; then
        rm -f "$f.new"
    elif [[ $CHECK -eq 1 ]]; then
        rm -f "$f.new"
        echo "DRIFT: $(basename "$f")"
        drift=1
    else
        cat "$f.new" > "$f" && rm -f "$f.new"
        echo "updated: $(basename "$f")"
        changed=1
    fi
done

if [[ $CHECK -eq 1 ]]; then
    [[ $drift -eq 0 ]] && { echo "All in sync."; exit 0; } || { echo "Out of sync — run scripts/sync-blocks.sh"; exit 1; }
fi
[[ $changed -eq 0 ]] && echo "All in sync."
exit 0
