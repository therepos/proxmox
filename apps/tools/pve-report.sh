#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/pve-report.sh?$(date +%s))"
# Purpose: Dump a full Proxmox VE configuration/health report to a text file (PVE host)
# =============================================================================
# Usage:
#   pve-report.sh [output-file]      # default: ./pve-report.txt
#
# Re-running is safe: the report file is regenerated fresh each time.
# Progress is shown on the terminal; the full report is written to the file.
#
# The report aims for signal over volume: package lists, PCI bridges, CPU flag
# strings, device-mapper duplicates and repeated log lines are filtered out.
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
sec_cluster()     { pvecm status 2>/dev/null || echo "Standalone (no cluster)"; }
sec_storage_cfg() { cat /etc/pve/storage.cfg 2>/dev/null || echo "(no /etc/pve/storage.cfg)"; }
sec_corosync()    { cat /etc/pve/corosync.conf 2>/dev/null || echo "(standalone — no corosync.conf)"; }

# pveversion -v lists ~60 packages; only the ones that shape guest/storage
# behaviour are worth reporting.
sec_versions() {
    pveversion -v | grep -E '^(proxmox-ve|pve-manager|proxmox-kernel-[0-9][^:]*|pve-qemu-kvm|qemu-server|pve-container|lxc-pve|zfsutils-linux|ceph-fuse|corosync|ifupdown2|libpve-storage-perl|proxmox-backup-client|proxmox-firewall|smartmontools):'
}

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
    # Device-mapper nodes are dropped: a thin pool prints its whole child list
    # twice (once under _tmeta, once under _tdata), and the LVM section already
    # reports every LV with its real usage.
    lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT,MODEL,SERIAL | grep -vE '[[:space:]]lvm[[:space:]]'
    echo ""
    echo "---- SMART summary ----"
    if command -v smartctl &>/dev/null; then
        for d in /dev/sd? /dev/nvme?n1; do
            [[ -e "$d" ]] || continue
            echo "== $d =="
            smartctl -i "$d" 2>/dev/null |
                grep -Ei '^(Model Number|Device Model|Serial Number|User Capacity|Total NVM Capacity|Rotation Rate)' || true
            smartctl -H "$d" 2>/dev/null | grep -Ei 'overall-health|SMART Health Status' || echo "(health unavailable)"
            smartctl -A "$d" 2>/dev/null |
                grep -Ei 'Percentage Used|Power On Hours|Power_On_Hours|Media and Data Integrity Errors|Available Spare|Reallocated_Sector|Wear_Leveling|^Temperature:' || true
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

# The full `ip a` dump repeats `ip -br a` line for line; only the MAC addresses
# it adds are worth keeping, and guest-side veth/tap/fw* interfaces are listed
# separately so they do not bury the host's own NICs.
GUEST_IF_RE='^(tap|veth|fwbr|fwpr|fwln)'
sec_network() {
    echo "---- Host interfaces ----"
    ip -br a | grep -vE "$GUEST_IF_RE"
    echo ""
    echo "---- MAC addresses ----"
    ip -br link | grep -vE "$GUEST_IF_RE" | awk '{printf "%-20s %s\n", $1, $3}'
    echo ""
    echo "---- Guest interfaces ----"
    ip -br link | grep -E "$GUEST_IF_RE" | awk '{printf "%-20s %s\n", $1, $2}' || echo "(none)"
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

# The CPU flag string is ~900 characters and the vulnerability list is mostly
# "Not affected"; report the topology in full but only the live mitigations.
sec_cpu() {
    lscpu | grep -vE '^(Flags|Vulnerability)'
    echo ""
    echo "---- Active mitigations ----"
    lscpu | grep '^Vulnerability' | grep -v 'Not affected' || echo "(none — no mitigations applied)"
}

# lspci -nnk is ~140 lines, most of it PCI bridges and per-device module lists.
# Keep real devices plus the driver actually bound (which is what matters for
# passthrough: vfio-pci vs the host driver).
sec_pci() {
    lspci -nnk | awk '
        /^[0-9a-f]+:[0-9a-f]+\.[0-9a-f]+ / {
            skip = ($0 ~ /PCI bridge|ISA bridge|SMBus|RAM memory|Signal processing controller|Serial controller|System peripheral/)
            if (!skip) print
            next
        }
        skip { next }
        /(Subsystem|DeviceName|Kernel modules):/ { next }
        { print }
    '
}

sec_backup() {
    echo "---- Backup jobs (/etc/pve/jobs.cfg) ----"
    cat /etc/pve/jobs.cfg 2>/dev/null || echo "(no jobs.cfg)"
    echo ""
    echo "---- vzdump overrides ----"
    local body
    body=$(grep -Ev '^[[:space:]]*(#|$)' /etc/vzdump.conf 2>/dev/null || true)
    echo "${body:-(none — all vzdump settings at default)}"
    echo ""
    echo "---- Replication ----"
    pvesr status 2>/dev/null || echo "(no replication configured)"
}

sec_repos() {
    local f body
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        body=$(grep -Ev '^[[:space:]]*(#|$)' "$f" || true)
        echo "---- $f ----"
        echo "${body:-(empty / fully commented out)}"
        echo ""
    done
    echo "---- Subscription ----"
    pvesubscription get 2>/dev/null | grep -Ei 'status|level' || echo "(unavailable)"
    echo ""
    echo "---- Pending upgrades ----"
    body=$(apt list --upgradable 2>/dev/null | tail -n +2 || true)
    echo "${body:-(none — system up to date)}"
}

sec_services() {
    local s st
    echo "---- Failed units ----"
    systemctl --failed --no-pager || true
    echo ""
    echo "---- Key PVE services ----"
    for s in pve-cluster pvedaemon pveproxy pvestatd pve-firewall corosync zfs-zed smartd; do
        # is-active exits non-zero for anything not running, so keep the word it
        # prints rather than appending a second line via `|| echo`.
        st=$(systemctl is-active "$s" 2>/dev/null || true)
        printf '%-16s %s\n' "$s" "${st:-n/a}"
    done
}

# A boot's worth of errors is usually one or two messages repeated dozens of
# times. Collapse them by normalising the varying numbers, then show the raw
# tail for recency.
sec_logs() {
    local dedup recent
    dedup=$(journalctl -p 3 -b --no-pager -o short-iso 2>/dev/null |
        awk '{$1=""; $2=""; sub(/^[[:space:]]+/,""); print}' |
        sed -E 's/\[[0-9]+\]:/:/; s/0x[0-9a-f]+/0xN/g; s/[0-9]+/N/g' |
        sort | uniq -c | sort -rn | head -20 || true)
    echo "---- Errors since boot (count × message, numbers normalised) ----"
    echo "${dedup:-(no errors logged this boot)}"
    echo ""
    echo "---- Most recent errors (last 10, verbatim) ----"
    recent=$(journalctl -p 3 -b --no-pager 2>/dev/null | tail -10 || true)
    echo "${recent:-(none)}"
    echo ""
    echo "---- Failed tasks (last 25) ----"
    recent=$(grep -v ':OK:' /var/log/pve/tasks/index 2>/dev/null | tail -25 || true)
    echo "${recent:-(no failed tasks)}"
}

sec_users() {
    grep -Ev '^[[:space:]]*$' /etc/pve/user.cfg 2>/dev/null || echo "(unavailable)"
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

collect "PVE / KERNEL VERSION" sec_versions
collect "HOST / BOOT / IOMMU"  sec_host
collect "CLUSTER STATUS"       sec_cluster
collect "COROSYNC CONFIG"      sec_corosync
collect "VIRTUAL MACHINES"     qm list
collect "LXC CONTAINERS"       pct list
collect "GUEST CONFIGS"        sec_guest_configs
collect "STORAGE STATUS"       pvesm status
collect "STORAGE CONFIG"       sec_storage_cfg
collect "FILESYSTEM USAGE"     df -hT -x tmpfs -x devtmpfs -x efivarfs
collect "LVM"                  sec_lvm
collect "DISKS"                sec_disks
collect "CPU"                  sec_cpu
collect "MEMORY"               free -h
collect "NETWORK"              sec_network
collect "PCI DEVICES"          sec_pci
collect "BACKUP & REPLICATION" sec_backup
collect "APT REPOS"            sec_repos
collect "SERVICES"             sec_services
collect "USERS & ROLES"        sec_users
collect "LOGS"                 sec_logs
collect "PERFORMANCE"          pveperf

{ echo ""; echo "==================== END OF REPORT ===================="; } >>"$OUT"

ok "Report complete: $OUT"
info "Contains hostnames, IPs, MACs and serials — review before sharing."
