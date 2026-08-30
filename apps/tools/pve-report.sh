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
sec_corosync()    { cat /etc/pve/corosync.conf 2>/dev/null || echo "(standalone — no corosync.conf)"; }

sec_host() {
    hostnamectl 2>/dev/null || echo "(hostnamectl unavailable)"
    echo ""
    echo "---- Uptime / load ----"
    uptime
    echo ""
    echo "---- Kernel cmdline ----"
    cat /proc/cmdline
    echo ""
    echo "---- Boot mode ----"
    [[ -d /sys/firmware/efi ]] && echo "UEFI" || echo "Legacy BIOS"
    echo ""
    echo "---- IOMMU ----"
    if [[ -d /sys/kernel/iommu_groups ]] && [[ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
        echo "IOMMU enabled ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
    else
        echo "IOMMU not enabled"
    fi
}

sec_guest_configs() {
    echo "---- VIRTUAL MACHINES ----"
    local ids
    ids=$(qm list 2>/dev/null | awk 'NR>1{print $1}')
    if [[ -z "$ids" ]]; then
        echo "(no VMs)"
    else
        for i in $ids; do
            echo ""
            echo "=== VM $i ==="
            qm config "$i" 2>&1 || echo "(config unavailable)"
        done
    fi

    echo ""
    echo "---- LXC CONTAINERS ----"
    ids=$(pct list 2>/dev/null | awk 'NR>1{print $1}')
    if [[ -z "$ids" ]]; then
        echo "(no containers)"
    else
        for i in $ids; do
            echo ""
            echo "=== CT $i ==="
            pct config "$i" 2>&1 || echo "(config unavailable)"
        done
    fi
}

sec_disks() {
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT,MODEL,SERIAL
    echo ""
    echo "---- SMART summary ----"
    if command -v smartctl &>/dev/null; then
        for d in /dev/sd? /dev/nvme?n1; do
            [[ -e "$d" ]] || continue
            echo "== $d =="
            smartctl -H -i "$d" 2>/dev/null | grep -Ei 'Model|Serial|Capacity|SMART overall|Health|Percentage Used|Power_On_Hours' || echo "(no data)"
        done
    else
        echo "(smartctl not installed — apt install smartmontools)"
    fi
    echo ""
    echo "---- ZFS ----"
    zpool list  2>/dev/null || echo "(no zpools)"
    echo ""
    zpool status 2>/dev/null || true
    echo ""
    zfs list    2>/dev/null || echo "(no zfs datasets)"
}

sec_lvm() {
    echo "---- Physical volumes ----"
    pvs 2>/dev/null || echo "(none)"
    echo ""
    echo "---- Volume groups ----"
    vgs 2>/dev/null || echo "(none)"
    echo ""
    echo "---- Logical volumes ----"
    lvs -a 2>/dev/null || echo "(none)"
}

sec_network() {
    ip -br a
    echo ""
    echo "---- Full addresses ----"
    ip a
    echo ""
    echo "---- Routes ----"
    ip r
    echo ""
    echo "---- /etc/network/interfaces ----"
    cat /etc/network/interfaces 2>/dev/null || echo "(missing)"
    echo ""
    echo "---- interfaces.d ----"
    cat /etc/network/interfaces.d/* 2>/dev/null || echo "(none)"
    echo ""
    echo "---- DNS ----"
    cat /etc/resolv.conf 2>/dev/null || echo "(missing)"
    echo ""
    echo "---- Firewall ----"
    cat /etc/pve/firewall/cluster.fw 2>/dev/null || echo "(no cluster firewall config)"
}

sec_backup() {
    echo "---- Backup jobs (/etc/pve/jobs.cfg) ----"
    cat /etc/pve/jobs.cfg 2>/dev/null || echo "(no jobs.cfg)"
    echo ""
    echo "---- vzdump defaults ----"
    cat /etc/vzdump.conf 2>/dev/null || echo "(missing)"
    echo ""
    echo "---- Replication ----"
    pvesr status 2>/dev/null || echo "(no replication configured)"
}

sec_repos() {
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        echo "---- $f ----"
        grep -v '^\s*#' "$f" | grep -v '^\s*$'
        echo ""
    done
    echo "---- Subscription ----"
    pvesubscription get 2>/dev/null | grep -Ei 'status|level' || echo "(unavailable)"
    echo ""
    echo "---- Pending upgrades ----"
    apt list --upgradable 2>/dev/null | tail -n +2 || echo "(unavailable)"
}

sec_services() {
    echo "---- Failed units ----"
    systemctl --failed --no-pager || true
    echo ""
    echo "---- Key PVE services ----"
    for s in pve-cluster pvedaemon pveproxy pvestatd pve-firewall corosync zfs-zed smartd; do
        printf '%-16s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo n/a)"
    done
}

sec_logs() {
    echo "---- Errors since boot (last 60) ----"
    journalctl -p 3 -b --no-pager 2>/dev/null | tail -60 || echo "(unavailable)"
    echo ""
    echo "---- Task log (last 25) ----"
    grep -v ':OK:' /var/log/pve/tasks/index 2>/dev/null | tail -25 || echo "(no failed tasks)"
}

sec_users() {
    cat /etc/pve/user.cfg 2>/dev/null | grep -Ev '^\s*$' || echo "(unavailable)"
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
collect "HOST / BOOT / IOMMU"  sec_host
collect "NODE STATUS"          sec_node_status
collect "CLUSTER STATUS"       sec_cluster
collect "COROSYNC CONFIG"      sec_corosync
collect "VIRTUAL MACHINES"     qm list
collect "LXC CONTAINERS"       pct list
collect "GUEST CONFIGS"        sec_guest_configs
collect "STORAGE STATUS"       pvesm status
collect "STORAGE CONFIG"       sec_storage_cfg
collect "FILESYSTEM USAGE"     df -hT
collect "LVM"                  sec_lvm
collect "DISKS"                sec_disks
collect "CPU"                  lscpu
collect "MEMORY"               free -h
collect "NETWORK"              sec_network
collect "PCI DEVICES"          lspci -nnk
collect "BACKUP & REPLICATION" sec_backup
collect "APT REPOS"            sec_repos
collect "SERVICES"             sec_services
collect "USERS & ROLES"        sec_users
collect "LOGS"                 sec_logs
collect "PERFORMANCE"          pveperf

{ echo ""; echo "==================== END OF REPORT ===================="; } >>"$OUT"

ok "Report complete: $OUT"
info "Contains hostnames, IPs, MACs and serials — review before sharing."
