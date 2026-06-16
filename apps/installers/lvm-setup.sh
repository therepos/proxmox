#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/lvm-setup.sh?$(date +%s))"
# Purpose: Grow the root logical volume to fill its volume group (compat shim)
# =============================================================================
# DEPRECATED: the LVM-expand logic now lives in disk-setup.sh, which also adds a
# usage diagnostic and host-side end-to-end disk resize. This shim stays so the
# old one-liner URL keeps working — it just delegates to 'disk-setup expand'.
# =============================================================================

set -euo pipefail

# --- Helpers -----------------------------------------------------------------
# >>> ui-block (managed by scripts/sync-ui.sh — do not edit here) >>>
if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }
# <<< ui-block <<<

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

GITHUB_BASE="https://github.com/therepos/proxmox/raw/main/apps/installers"

info "lvm-setup is now part of disk-setup — delegating to 'disk-setup expand'."
body="$(wget -qLO- "${GITHUB_BASE}/disk-setup.sh?$(date +%s)")" \
    || fail "Failed to download disk-setup.sh from ${GITHUB_BASE}."
[[ -n "$body" ]] || fail "Downloaded disk-setup.sh but it was empty."
bash -c "$body" disk-setup.sh expand
