#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/pve-report.sh?$(date +%s))"
# Purpose: Dump a full Proxmox VE configuration/health report to a text file (PVE host)
# =============================================================================
# Usage:
#   pve-report.sh [output-file]      # default: ./pve-report.txt
#
# Re-running is safe: the report file is regenerated fresh each time.
# Progress is shown on the terminal; the full report is written to the file.
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

is_proxmox_host() { [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null; }

# Write a section banner into the report, then run a command/function and append
# its output. Tolerant: a failing or missing command is noted, not fatal — so
# the rest of the report is still produced.
section() { { echo ""; echo "========== $* =========="; } >>"$OUT"; }
collect() {
    local label="$1"; shift
    section "$label"
    if "$@" >>"$OUT" 2>&1; then
        ok "$label"
    else
        echo "(unavailable or command failed)" >>"$OUT"
        warn "$label — unavailable, skipped"
    fi
}

# --- Compound sections -------------------------------------------------------
sec_node_status() { pvesh get "/nodes/$(hostname)/status"; }
sec_cluster()     { pvecm status 2>/dev/null || echo "Standalone (no cluster)"; }
sec_storage_cfg() { cat /etc/pve/storage.cfg 2>/dev/null || echo "(no /etc/pve/storage.cfg)"; }

sec_disks() {
    lsblk
    echo ""
    echo "---- ZFS ----"
    zpool status 2>/dev/null || echo "(no zpools)"
    zfs list   2>/dev/null || echo "(no zfs datasets)"
}

sec_network() {
    ip a
    echo ""
    echo "---- Routes ----"
    ip r
    echo ""
    echo "---- /etc/network/interfaces ----"
    cat /etc/network/interfaces 2>/dev/null || echo "(missing)"
}

# --- Pre-flight --------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."
is_proxmox_host || fail "This must be run on a Proxmox VE host (pveversion not found)."

OUT="${1:-pve-report.txt}"

# --- Generate report ---------------------------------------------------------
info "Writing Proxmox report to: $OUT"
{
    echo "==================== PVE REPORT: $(date) ===================="
    echo "Hostname: $(hostname)"
} >"$OUT"

collect "PVE / KERNEL VERSION" pveversion -v
collect "NODE STATUS"          sec_node_status
collect "CLUSTER STATUS"       sec_cluster
collect "VIRTUAL MACHINES"     qm list
collect "LXC CONTAINERS"       pct list
collect "STORAGE STATUS"       pvesm status
collect "STORAGE CONFIG"       sec_storage_cfg
collect "CPU"                  lscpu
collect "MEMORY"               free -h
collect "DISKS"                sec_disks
collect "NETWORK"              sec_network
collect "PCI DEVICES"          lspci
collect "PERFORMANCE"          pveperf

{ echo ""; echo "==================== END OF REPORT ===================="; } >>"$OUT"

ok "Report complete: $OUT"
