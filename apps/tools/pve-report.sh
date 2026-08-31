#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/pve-report.sh?$(date +%s))"
# Purpose: Dump a full Proxmox VE configuration/health report to a text file (PVE host)
# =============================================================================
# Usage:
#   pve-report.sh [output-file]      # default: ./pve-report.txt
#
# Environment:
#   SECTION_TIMEOUT=90   seconds any single section may run before it is
#                        abandoned (an unreachable NFS/CIFS storage otherwise
#                        hangs pvesm/df indefinitely)
#
# Re-running is safe: the report file is regenerated fresh each time.
# Progress is shown on the terminal; the full report is written to the file.
#
# The report aims for signal over volume: package lists, PCI bridges, CPU flag
# strings, device-mapper duplicates and repeated log lines are filtered out.
# =============================================================================

set -euo pipefail

# Parsing below greps for English keywords ("overall-health", "active",
# "Not affected"), so pin the locale rather than trusting the caller's.
export LC_ALL=C

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

SECTION_TIMEOUT="${SECTION_TIMEOUT:-90}"

# Wait for a pid, giving up after N seconds. Returns the child's exit status,
# or 124 (the timeout(1) convention) if it had to be killed.
_await() {
    local pid="$1" limit="$2" ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( ticks >= limit * 5 )); then
            kill -TERM "$pid" 2>/dev/null || true
            pkill -TERM -P "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.2
        ticks=$(( ticks + 1 ))
    done
    wait "$pid"
}

# Write a section banner into the report, then run a command/function and append
# its output. Tolerant by construction: the work runs in a background subshell
# with errexit off, so a failing or missing command is noted, not fatal, and a
# section that wedges on dead storage is abandoned rather than hanging the run.
# Output is staged in a temp file so a killed section cannot interleave itself
# into a later one.
section() { { echo ""; echo "========== $* =========="; } >>"$OUT"; }
collect() {
    local label="$1"; shift
    local tmp rc=0 pid
    section "$label"
    tmp=$(mktemp "$_WORKDIR/section.XXXXXX")
    { set +e; "$@" >"$tmp" 2>&1; } &
    pid=$!
    _await "$pid" "$SECTION_TIMEOUT" || rc=$?
    cat "$tmp" >>"$OUT"
    case "$rc" in
        0)   ok "$label" ;;
        124) echo "(timed out after ${SECTION_TIMEOUT}s — output above may be partial)" >>"$OUT"
             warn "$label — timed out after ${SECTION_TIMEOUT}s" ;;
        *)   echo "(unavailable or command failed)" >>"$OUT"
             warn "$label — unavailable, skipped" ;;
    esac
}

# Real disks only, from the kernel's own view: globbing /dev/sd? and
# /dev/nvme?n1 misses sdaa+, second namespaces, virtio and mmc devices.
list_disks() {
    lsblk -dno NAME,TYPE 2>/dev/null |
        awk '$2 == "disk" && $1 !~ /^(zram|loop|ram|sr|fd|dm-)/ { print "/dev/" $1 }'
}

# Days until a certificate expires, or nothing if it cannot be determined.
cert_days() {
    local pem="$1" end
    [[ -r "$pem" ]] || return 1
    command -v openssl >/dev/null || return 1
    end=$(openssl x509 -enddate -noout -in "$pem" 2>/dev/null | cut -d= -f2-) || return 1
    [[ -n "$end" ]] || return 1
    local until_ts now_ts
    until_ts=$(date -d "$end" +%s 2>/dev/null) || return 1
    now_ts=$(date +%s)
    echo $(( (until_ts - now_ts) / 86400 ))
}

# Newest installed kernel vs the running one.
pending_reboot() {
    local running newest
    running=$(uname -r)
    newest=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
    [[ -n "$newest" && "$newest" != "$running" ]] || return 1
    echo "running $running, newest installed $newest"
}

# --- Health summary ----------------------------------------------------------
# Cheap best-effort probes so the top of the report answers "is anything wrong?"
# without reading the other 200 lines. A missing tool skips its check silently —
# it never turns into a false clean bill of health.
sec_summary() {
    local issues=() line d h z days info_line pvever up vms cts

    # Query the guest lists once each: on a busy node `qm list` is not free.
    pvever=$(pveversion 2>/dev/null | head -1 || true)
    up=$(uptime -p 2>/dev/null || uptime || true)
    vms=$(qm list 2>/dev/null | awk 'NR>1' || true)
    cts=$(pct list 2>/dev/null | awk 'NR>1' || true)

    echo "---- At a glance ----"
    printf '%-24s %s\n' "PVE version:" "${pvever:-(unknown)}"
    printf '%-24s %s\n' "Kernel:"      "$(uname -r)"
    printf '%-24s %s\n' "Uptime:"      "${up:-(unknown)}"
    printf '%-24s %s/%s\n' "VMs running/total:" \
        "$(awk '$3=="running"{n++} END{print n+0}' <<<"$vms")" \
        "$(awk 'NF{n++} END{print n+0}' <<<"$vms")"
    printf '%-24s %s/%s\n' "CTs running/total:" \
        "$(awk '$2=="running"{n++} END{print n+0}' <<<"$cts")" \
        "$(awk 'NF{n++} END{print n+0}' <<<"$cts")"

    # Failed systemd units
    line=$(systemctl list-units --failed --no-legend --no-pager 2>/dev/null | wc -l)
    (( ${line:-0} > 0 )) && issues+=("$line failed systemd unit(s) — see SERVICES")

    # Filesystems at 85% or above
    while read -r line; do
        [[ -n "$line" ]] && issues+=("Filesystem $line — see FILESYSTEM USAGE")
    done < <(df -P -x tmpfs -x devtmpfs -x efivarfs -x overlay 2>/dev/null |
             awk 'NR>1 && $5+0 >= 85 { print $6 " at " $5 }' || true)

    # LVM thin pools at 85% or above (data or metadata)
    while read -r line; do
        [[ -n "$line" ]] && issues+=("Thin pool $line — see LVM")
    done < <(lvs --noheadings -o lv_name,lv_attr,data_percent,metadata_percent 2>/dev/null |
             awk '$2 ~ /^t/ && ($3+0 >= 85 || $4+0 >= 85) { print $1 " at " $3 "% data / " $4 "% metadata" }' || true)

    # SMART overall health
    for d in $(list_disks); do
        command -v smartctl >/dev/null || break
        h=$(smartctl -H "$d" 2>/dev/null | grep -Ei 'overall-health|SMART Health Status' || true)
        [[ -n "$h" && "$h" != *PASSED* && "$h" != *OK* ]] && issues+=("SMART on $d: ${h#*: }")
    done

    # ZFS pool health
    if command -v zpool >/dev/null; then
        z=$(zpool status -x 2>/dev/null || true)
        [[ -n "$z" && "$z" != *"all pools are healthy"* && "$z" != *"no pools available"* ]] &&
            issues+=("ZFS pool(s) not healthy — see DISKS")
    fi

    # Kernel newer than the running one
    info_line=$(pending_reboot) && issues+=("Reboot pending: $info_line")

    # No backup job defined
    grep -qs '^vzdump:' /etc/pve/jobs.cfg || issues+=("No vzdump backup job configured — see BACKUP & REPLICATION")

    # Certificate about to expire
    days=$(cert_days /etc/pve/local/pveproxy-ssl.pem || cert_days /etc/pve/local/pve-ssl.pem || true)
    if [[ -n "$days" ]]; then
        (( days < 0 ))  && issues+=("API/web certificate EXPIRED $(( -days )) day(s) ago")
        (( days >= 0 && days < 30 )) && issues+=("API/web certificate expires in $days day(s)")
    fi

    echo ""
    echo "---- Checks ----"
    if (( ${#issues[@]} == 0 )); then
        echo "No issues detected by the automated checks."
    else
        printf '!! %s\n' "${issues[@]}"
    fi
}

# --- Compound sections -------------------------------------------------------
sec_cluster()     { pvecm status 2>/dev/null || echo "Standalone (no cluster)"; }
sec_storage_cfg() { cat /etc/pve/storage.cfg 2>/dev/null || echo "(no /etc/pve/storage.cfg)"; }
sec_corosync()    { cat /etc/pve/corosync.conf 2>/dev/null || echo "(standalone — no corosync.conf)"; }

# pveversion -v lists ~60 packages; only the ones that shape guest, storage and
# network behaviour are worth reporting.
sec_versions() {
    pveversion -v 2>/dev/null | grep -E '^(proxmox-ve|pve-manager|proxmox-kernel-[0-9][^:]*|pve-qemu-kvm|qemu-server|pve-container|lxc-pve|zfsutils-linux|ceph-fuse|corosync|ifupdown2|libpve-storage-perl|proxmox-backup-client|proxmox-firewall|smartmontools):' ||
        echo "(pveversion unavailable)"
}

sec_host() {
    # Machine/Boot ID and Product UUID identify the host without explaining
    # anything about it; drop them from a file meant to be shared.
    hostnamectl 2>/dev/null | grep -vE 'Icon name|Machine ID|Boot ID|Product UUID' ||
        echo "(hostnamectl unavailable)"
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
    echo "---- Reboot status ----"
    local pend
    if pend=$(pending_reboot); then
        echo "Reboot pending ($pend)"
    else
        echo "Running the newest installed kernel"
    fi
    echo ""
    echo "---- IOMMU ----"
    if [[ -d /sys/kernel/iommu_groups ]] && [[ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]]; then
        echo "IOMMU enabled ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
    else
        echo "IOMMU not enabled"
    fi
    echo ""
    echo "---- Module configuration (blacklists, vfio options) ----"
    local body
    body=$(grep -Ehv '^[[:space:]]*(#|$)' \
              /etc/modules /etc/modules-load.d/*.conf /etc/modprobe.d/*.conf 2>/dev/null || true)
    echo "${body:-(no custom module configuration)}"
    echo ""
    echo "---- Loaded passthrough modules ----"
    body=$(lsmod 2>/dev/null | awk '$1 ~ /^(vfio|kvm|nvidia|i915|xe)/ { print $1 }' | sort | paste -sd' ' - || true)
    echo "${body:-(none)}"
}

sec_guest_configs() {
    local ids i
    echo "---- VIRTUAL MACHINES ----"
    if ! ids=$(qm list 2>/dev/null | awk 'NR>1{print $1}'); then
        echo "(qm unavailable)"
    elif [[ -z "$ids" ]]; then
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
    if ! ids=$(pct list 2>/dev/null | awk 'NR>1{print $1}'); then
        echo "(pct unavailable)"
    elif [[ -z "$ids" ]]; then
        echo "(no containers)"
    else
        for i in $ids; do
            echo ""
            echo "=== CT $i ==="
            pct config "$i" 2>&1 || echo "(config unavailable)"
        done
    fi
}

sec_filesystems() {
    df -hT -x tmpfs -x devtmpfs -x efivarfs
    echo ""
    echo "---- /etc/fstab (non-default mounts) ----"
    local body
    body=$(grep -Ev '^[[:space:]]*(#|$)' /etc/fstab 2>/dev/null || true)
    echo "${body:-(empty)}"
}

sec_disks() {
    # Flat listing with TYPE first: the tree form repeats a thin pool's entire
    # child list twice (under _tmeta and again under _tdata), and TYPE is the
    # only column guaranteed non-empty, so it is the only safe one to filter on.
    # Logical volumes are reported with their real usage in the LVM section.
    lsblk -l -o TYPE,NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL,SERIAL | awk 'NR == 1 || $1 != "lvm"'
    echo ""
    echo "---- SMART summary ----"
    if command -v smartctl &>/dev/null; then
        local d
        for d in $(list_disks); do
            echo "== $d =="
            smartctl -i "$d" 2>/dev/null |
                grep -Ei '^(Model Number|Device Model|Serial Number|User Capacity|Total NVM Capacity|Rotation Rate)' || true
            smartctl -H "$d" 2>/dev/null |
                grep -Ei 'overall-health|SMART Health Status' || echo "(health unavailable)"
            smartctl -A "$d" 2>/dev/null |
                grep -Ei 'Percentage Used|Power On Hours|Power_On_Hours|Media and Data Integrity Errors|Available Spare|Reallocated_Sector|Wear_Leveling|^Temperature:' || true
        done
    else
        echo "(smartctl not installed — apt install smartmontools)"
    fi
    echo ""
    echo "---- ZFS ----"
    if command -v zpool &>/dev/null; then
        zpool list 2>/dev/null || echo "(no zpools)"
        echo ""
        zpool status 2>/dev/null || true
        echo ""
        zfs list 2>/dev/null || echo "(no zfs datasets)"
    else
        echo "(zfs tools not installed)"
    fi
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
    local body
    echo "---- Host interfaces ----"
    ip -br a 2>/dev/null | grep -vE "$GUEST_IF_RE" || echo "(ip unavailable)"
    echo ""
    echo "---- MAC addresses ----"
    ip -br link 2>/dev/null | grep -vE "$GUEST_IF_RE" | awk '{ printf "%-20s %s\n", $1, $3 }' || true
    echo ""
    echo "---- Guest interfaces ----"
    body=$(ip -br link 2>/dev/null | grep -E "$GUEST_IF_RE" | awk '{ printf "%-20s %s\n", $1, $2 }' || true)
    echo "${body:-(none)}"
    echo ""
    echo "---- Routes ----"
    ip r 2>/dev/null || echo "(ip unavailable)"
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
    echo "---- Scaling governor ----"
    local gov
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
    echo "${gov:-(not exposed by this platform)}"
    echo ""
    echo "---- Active mitigations ----"
    lscpu | grep '^Vulnerability' | grep -v 'Not affected' || echo "(none applied)"
}

# lspci -nnk is ~140 lines, most of it PCI bridges and per-device module lists.
# Keep real devices plus the driver actually bound, which is what matters for
# passthrough: vfio-pci means the host released the device, anything else means
# the host is still holding it.
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
    local body
    echo "---- Backup jobs (/etc/pve/jobs.cfg) ----"
    cat /etc/pve/jobs.cfg 2>/dev/null || echo "(no jobs.cfg — no scheduled backups)"
    echo ""
    echo "---- Recent vzdump tasks ----"
    body=$(grep -E ':vzdump:' /var/log/pve/tasks/index 2>/dev/null | tail -5 || true)
    echo "${body:-(no vzdump runs in the recent task index)}"
    echo ""
    echo "---- vzdump overrides ----"
    body=$(grep -Ev '^[[:space:]]*(#|$)' /etc/vzdump.conf 2>/dev/null || true)
    echo "${body:-(none — all vzdump settings at default)}"
    echo ""
    # notifications.cfg holds targets and matchers; the credentials live in
    # notifications.priv, which is deliberately not read.
    echo "---- Notification targets ----"
    body=$(grep -Ev '^[[:space:]]*(#|$)' /etc/pve/notifications.cfg 2>/dev/null || true)
    echo "${body:-(default target only — root@pam mail)}"
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
    local s st c
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
    echo ""
    echo "---- Certificate expiry ----"
    for c in /etc/pve/local/pve-ssl.pem /etc/pve/local/pveproxy-ssl.pem; do
        [[ -r "$c" ]] || continue
        printf '%-22s %s\n' "$(basename "$c")" \
            "$(openssl x509 -enddate -noout -in "$c" 2>/dev/null | cut -d= -f2- || echo '(unreadable)')"
    done
}

# A boot's worth of errors is usually one or two messages repeated dozens of
# times. Collapse them by message, then show the raw tail for recency.
sec_logs() {
    local dedup recent
    # Only 0x-prefixed and free-standing numbers are normalised: \b keeps the
    # trailing digit of a device name, so nvme0 and nvme1 stay distinct and the
    # counts still say which disk is complaining.
    # journalctl writes its own decoration ("-- No entries --", "-- Boot ... --")
    # to stdout, so strip it or a quiet host reports a phantom error line.
    dedup=$(journalctl -p 3 -b --no-pager -o short-iso 2>/dev/null |
        grep -v '^-- ' |
        cut -d' ' -f3- |
        sed -E 's/\[[0-9]+\]:/:/; s/0x[0-9a-f]+/0xN/g; s/\b[0-9]+\b/N/g' |
        sort | uniq -c | sort -rn | head -20 || true)
    echo "---- Errors since boot (count × message, numbers normalised) ----"
    echo "${dedup:-(no errors logged this boot)}"
    echo ""
    echo "---- Most recent errors (last 10, verbatim) ----"
    recent=$(journalctl -p 3 -b --no-pager 2>/dev/null | grep -v '^-- ' | tail -10 || true)
    echo "${recent:-(none)}"
    echo ""
    echo "---- Recent non-OK tasks (may include still-running) ----"
    recent=$(grep -v ':OK:' /var/log/pve/tasks/index 2>/dev/null | tail -25 || true)
    echo "${recent:-(none)}"
}

sec_users() {
    grep -Ev '^[[:space:]]*$' /etc/pve/user.cfg 2>/dev/null || echo "(unavailable)"
}

# --- Pre-flight --------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."
is_proxmox_host || fail "This must be run on a Proxmox VE host (pveversion not found)."

OUT="${1:-pve-report.txt}"
_OUTDIR=$(dirname -- "$OUT")
[[ -d "$_OUTDIR" ]] || fail "Output directory does not exist: $_OUTDIR"
[[ -w "$_OUTDIR" ]] || fail "Output directory is not writable: $_OUTDIR"
[[ ! -e "$OUT" || -w "$OUT" ]] || fail "Output file is not writable: $OUT"

_WORKDIR=$(mktemp -d)
trap 'rm -rf "$_WORKDIR"' EXIT

# --- Generate report ---------------------------------------------------------
info "Writing Proxmox report to: $OUT"
{
    echo "==================== PVE REPORT: $(date) ===================="
    echo "Hostname: $(hostname)"
} >"$OUT"

collect "HEALTH SUMMARY"       sec_summary
collect "PVE / KERNEL VERSION" sec_versions
collect "HOST / BOOT / IOMMU"  sec_host
collect "CLUSTER STATUS"       sec_cluster
collect "COROSYNC CONFIG"      sec_corosync
collect "VIRTUAL MACHINES"     qm list
collect "LXC CONTAINERS"       pct list
collect "GUEST CONFIGS"        sec_guest_configs
collect "STORAGE STATUS"       pvesm status
collect "STORAGE CONFIG"       sec_storage_cfg
collect "FILESYSTEM USAGE"     sec_filesystems
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
