#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/disk-setup.sh?$(date +%s))"
# Purpose: VM disk capacity — check usage + expand end-to-end (host & VM aware)
# =============================================================================
# Auto-detects whether it runs on a Proxmox host or inside the Ubuntu VM, and
# exposes the half that makes sense for that side. The goal is that a
# non-technical user can answer two questions with one command: "am I running
# out of disk?" and "grow it for me".
#
#   On the Proxmox HOST (this is the only side that can grow the virtual disk):
#     disk-setup            Interactive menu
#     disk-setup status     VM disk size + live guest df / + VG free (via agent)
#     disk-setup expand     End-to-end grow: resize disk -> grow partition ->
#                           PV -> LV -> filesystem, all via the guest agent.
#                           No SSH, no downtime.
#
#   Inside the Ubuntu VM:
#     disk-setup            Interactive menu
#     disk-setup status     Disk-usage diagnostic (df, docker, VG free, advice)
#     disk-setup expand     Claim free space already on the disk: grow partition
#                           -> PV -> LV -> filesystem (idempotent; exit 0 no-op).
#
# The VM side cannot enlarge the virtual disk itself (only the host can). When
# the VG is already full, the diagnostic tells you to run 'disk-setup expand'
# on the host.
#
# Config (override via env): VMID, DISK (host disk name, e.g. scsi0 — auto-
#   detected from the boot order if unset), ADD_GB (host unattended: GB to add).
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

# Interactive numeric prompt that works under: bash -c "$(wget ...)"
asknum() { # asknum "prompt" min max default
    local p="$1" min="$2" max="$3" def="$4" in
    while true; do
        if [[ -r /dev/tty ]]; then
            read -rp "$p [$min-$max] (default: $def): " in </dev/tty || in="$def"
        else
            read -rp "$p [$min-$max] (default: $def): " in || in="$def"
        fi
        in="${in:-$def}"
        [[ "$in" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
        (( in>=min && in<=max )) && { echo "$in"; return; }
    done
}

section() { # a readable divider for the status report
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $*"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

is_proxmox_host() {
    [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null
}

# --- Config ------------------------------------------------------------------
VMID="${VMID:-200}"            # VM to operate on (host side)

# The exact in-guest growth recipe. Detects root LV -> VG -> PV -> disk/part on
# its own, so it works on any standard Ubuntu LVM layout (not just sda3). It is
# safe to re-run: growpart NOCHANGE and an already-full LV are tolerated.
# Prints the resulting 'df -h /' line as its last output.
read -r -d '' GUEST_GROW <<'GROWEOF' || true
set -e
root=$(findmnt -no SOURCE /)
case "$root" in
  /dev/mapper/*|/dev/*vg*/*) : ;;   # looks like an LVM LV
  *) echo "NOT_LVM $root"; df -h / | tail -1; exit 0 ;;
esac
vg=$(lvs --noheadings -o vg_name "$root" 2>/dev/null | tr -d ' ')
pv=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v v="$vg" '$2==v{print $1; exit}')
disk=$(lsblk -no PKNAME "$pv" 2>/dev/null | head -1)
pnum=$(echo "$pv" | grep -oE '[0-9]+$')
command -v growpart >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y cloud-guest-utils >/dev/null 2>&1 || true; }
for r in /sys/class/scsi_disk/*/device/rescan; do echo 1 > "$r" 2>/dev/null || true; done
[ -n "$disk" ] && [ -n "$pnum" ] && growpart "/dev/$disk" "$pnum" 2>/dev/null || true
pvresize "$pv" >/dev/null 2>&1 || true
lvextend -r -l +100%FREE "$root" >/dev/null 2>&1 || true
df -h / | tail -1
GROWEOF

# ============================================================================
# HOST SIDE — only the host can resize the virtual disk.
# ============================================================================

# Pull the clean stdout text out of a guest-agent JSON reply.
gx_out() { grep -oE '"out-data" *: *"[^"]*"' | sed 's/.*"out-data" *: *"//; s/"$//; s/\\n/\n/g'; }
# Pull the guest command's own exit code out of a guest-agent JSON reply.
gx_rc()  { grep -oE '"exitcode" *: *[0-9]+' | grep -oE '[0-9]+' | head -1; }

# Run a command inside the guest; echo its stdout, return its exit code.
guest_run() { # guest_run <timeout> <command>
    local out rc
    out="$(qm guest exec "$VMID" --timeout "$1" -- /bin/bash -c "$2" 2>/dev/null)" || true
    rc="$(printf '%s' "$out" | gx_rc)"; rc="${rc:-1}"
    printf '%s' "$out" | gx_out
    return "$rc"
}

host_require_agent() {
    command -v qm >/dev/null || fail "'qm' not found — is this really a Proxmox host?"
    qm status "$VMID" &>/dev/null || fail "VM ${VMID} does not exist on this host."
    qm guest cmd "$VMID" ping >/dev/null 2>&1 \
        || fail "Guest agent not responding on VM ${VMID}. Is the VM running with agent enabled?"
}

# Resolve the disk name in the VM config (honour DISK, else use boot order).
host_detect_disk() {
    [[ -n "${DISK:-}" ]] && { echo "$DISK"; return; }
    local cfg order d
    cfg="$(qm config "$VMID" 2>/dev/null)"
    order="$(grep -oE '^boot:.*order=[^,[:space:]]*' <<<"$cfg" | sed 's/.*order=//')"
    IFS=';' read -ra _bo <<<"$order"
    for d in "${_bo[@]}"; do
        grep -qE "^${d}:.*size=" <<<"$cfg" && { echo "$d"; return; }
    done
    # Fallback: first disk-like entry that carries a size=.
    for d in $(grep -oE '^(scsi|virtio|sata|ide)[0-9]+:' <<<"$cfg" | tr -d ':'); do
        grep -qE "^${d}:.*size=" <<<"$cfg" && { echo "$d"; return; }
    done
}

host_disk_size_gb() { # host_disk_size_gb <disk>
    qm config "$VMID" 2>/dev/null | grep "^${1}:" | grep -oE 'size=[0-9]+G' | grep -oE '[0-9]+'
}

host_status() {
    host_require_agent
    local disk size
    disk="$(host_detect_disk)"
    [[ -n "$disk" ]] || fail "Could not find a disk on VM ${VMID}. Set DISK=scsi0 (or similar)."
    size="$(host_disk_size_gb "$disk")"

    section "VM ${VMID} — Disk Status (host view)"
    echo "  Disk in config:   ${disk}, ${size:-?}G"
    echo ""
    echo "  Guest root usage (df -h /):"
    guest_run 30 "df -h / | tail -1" | sed 's/^/      /' || true
    echo ""
    echo "  Free space in the volume group (room to grow without resizing):"
    guest_run 30 "vgs 2>/dev/null || echo '      (no LVM volume group found)'" | sed 's/^/      /' || true
    echo ""
    info "To enlarge the virtual disk and grow everything in one go: disk-setup expand"
    echo ""
}

host_expand() {
    host_require_agent
    local disk cur add
    disk="$(host_detect_disk)"
    [[ -n "$disk" ]] || fail "Could not find a disk on VM ${VMID}. Set DISK=scsi0 (or similar)."
    cur="$(host_disk_size_gb "$disk")"
    [[ -n "$cur" ]] || fail "Could not read size of ${disk} on VM ${VMID}."

    section "VM ${VMID} — Expand Disk End-to-End"
    echo "  Current disk: ${disk}, ${cur}G"
    echo ""

    if [[ -n "${ADD_GB:-}" ]]; then
        [[ "$ADD_GB" =~ ^[0-9]+$ ]] && (( ADD_GB >= 1 )) || fail "ADD_GB='${ADD_GB}' is not a valid number of GB."
        add="$ADD_GB"
    else
        add="$(asknum 'How many GB to add' 1 65536 128)"
    fi

    # [1/4] resize the virtual disk on the host
    info "[1/4] Resizing ${disk} by +${add}G..."
    qm disk resize "$VMID" "$disk" "+${add}G" >/dev/null 2>&1 \
        || fail "Resize failed — check free space on the storage pool (pvesm status)."
    ok "Disk resized (now $((cur + add))G)."

    # [2-3/4] grow partition -> PV -> LV -> filesystem inside the guest
    info "[2/4] Growing partition, PV, LV and filesystem inside the guest..."
    local result rc=0
    result="$(guest_run 240 "$GUEST_GROW")" || rc=$?
    if (( rc != 0 )); then
        fail "In-guest growth failed (exit ${rc}). The disk was resized; you can retry: disk-setup expand"
    fi
    ok "[3/4] Guest storage extended."

    # [4/4] report
    echo ""
    info "[4/4] Result (df -h / inside the VM):"
    echo "$result" | tail -1 | sed 's/^/      /'
    echo ""
    ok "Disk expanded end-to-end with no downtime."
    echo ""
}

host_menu() {
    section "Proxmox Host — Disk for VM ${VMID}"
    echo "  1) Status   (disk size + guest usage + free space)"
    echo "  2) Expand   (resize disk + grow everything in the guest)"
    echo "  0) Exit"
    local choice; choice="$(asknum 'Choose' 0 2 1)"
    case "$choice" in
        0) ok "Bye." ;;
        1) host_status ;;
        2) host_expand ;;
    esac
}

# ============================================================================
# VM SIDE — diagnose usage; claim space already present on the disk.
# ============================================================================
vm_status() {
    section "1. ROOT DISK USAGE"
    df -h /

    section "2. TOP-LEVEL SPACE HOGS"
    du -h / --max-depth=1 2>/dev/null | sort -rh | head -10

    if command -v docker >/dev/null 2>&1; then
        section "3. DOCKER STORAGE SPLIT"
        docker system df 2>/dev/null || warn "Could not query docker."

        section "4. DOCKER vs CONTAINERD ON DISK"
        du -sh /var/lib/docker /var/lib/containerd 2>/dev/null || true

        section "5. CONTAINER WRITABLE LAYERS (data NOT on a mount)"
        docker ps -s --format '{{.Names}}\t{{.Size}}' 2>/dev/null | sort -t$'\t' -k2 -rh | head -10

        section "6. ORPHANED IMAGES CHECK"
        local imgs active
        imgs=$(( $(ctr -n moby images ls 2>/dev/null | wc -l) - 1 ))
        active=$(docker ps -q 2>/dev/null | wc -l)
        (( imgs < 0 )) && imgs=0
        echo "Stored images: $imgs  |  Active containers: $active"
        if (( imgs <= active )); then
            ok "Stored matches active: nothing to prune."
        else
            warn "$((imgs - active)) extra image(s): run 'docker image prune -a' to reclaim."
        fi
    else
        section "3. DOCKER"
        info "Docker is not installed — skipping container storage checks."
    fi

    section "7. VG FREE SPACE (room to grow inside the VM)"
    local vfree
    vgs 2>/dev/null || info "No LVM volume group found."
    vfree=$(vgs --noheadings -o vg_free --units g 2>/dev/null | tr -d ' g<' | cut -d. -f1)
    vfree=${vfree:-0}

    section "CONCLUSION"
    if (( vfree >= 5 )); then
        warn "${vfree}G is free in the volume group."
        info "Run 'disk-setup expand' (in this VM) to claim it for the filesystem."
    else
        ok "No significant free space inside the VM — storage layout is healthy."
        info "If the disk is full, enlarge it from the Proxmox HOST: disk-setup expand"
    fi
    echo ""
}

# Grow partition -> PV -> LV -> filesystem to claim any free space already on
# the disk. Idempotent: a no-op when there is nothing to claim (exit 0).
vm_expand() {
    section "VM — Claim Free Disk Space"

    local root vg pv disk pnum
    root="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [[ -z "$root" ]]; then
        warn "Could not detect the root device. Nothing to do."
        return 0
    fi
    if ! lvdisplay "$root" &>/dev/null; then
        info "Root filesystem is not on LVM (${root}). Nothing to do."
        return 0
    fi

    vg="$(lvs --noheadings -o vg_name "$root" 2>/dev/null | tr -d ' ')"
    pv="$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v v="$vg" '$2==v{print $1; exit}')"
    disk="$(lsblk -no PKNAME "$pv" 2>/dev/null | head -1)"
    pnum="$(echo "$pv" | grep -oE '[0-9]+$')"

    # If the host enlarged the disk, the partition/PV may need to catch up first.
    for r in /sys/class/scsi_disk/*/device/rescan; do echo 1 > "$r" 2>/dev/null || true; done
    if [[ -n "$disk" && -n "$pnum" ]]; then
        if command -v growpart >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; apt-get install -y cloud-guest-utils >/dev/null 2>&1; }; then
            growpart "/dev/$disk" "$pnum" >/dev/null 2>&1 && info "Partition grown to fill the disk." || true
        fi
    fi
    pvresize "$pv" >/dev/null 2>&1 || true

    # How much is now free in the VG?
    local free_b free_gib
    free_b="$(vgs --noheadings --units b -o vg_free "$vg" 2>/dev/null | tr -d ' B<' || echo 0)"
    free_gib=$(( ${free_b:-0} / 1073741824 ))

    if (( free_gib < 1 )); then
        ok "No significant free space in VG '${vg}'. Nothing to do."
        echo ""
        return 0
    fi

    info "Extending root LV to claim ${free_gib} GiB free in VG '${vg}'..."
    if lvextend -r -l +100%FREE "$root" >/dev/null 2>&1; then
        ok "Filesystem extended. Root is now $(df -h / | awk 'NR==2{print $2}')."
    else
        warn "lvextend reported nothing to do (may already be at max)."
    fi
    echo ""
}

vm_menu() {
    section "VM — Disk Capacity"
    echo "  1) Status   (usage diagnostic + advice)"
    echo "  2) Expand   (claim free space already on the disk)"
    echo "  0) Exit"
    local choice; choice="$(asknum 'Choose' 0 2 1)"
    case "$choice" in
        0) ok "Bye." ;;
        1) vm_status ;;
        2) vm_expand ;;
    esac
}

# ============================================================================
# DISPATCH
# ============================================================================
if is_proxmox_host; then
    cmd="${1:-menu}"
    case "$cmd" in
        menu)   host_menu ;;
        status) host_status ;;
        expand) host_expand ;;
        *) fail "Unknown host command '${cmd}' (use: status | expand)" ;;
    esac
else
    cmd="${1:-menu}"
    case "$cmd" in
        menu)   vm_menu ;;
        status) vm_status ;;
        expand) vm_expand ;;
        *) fail "Unknown VM command '${cmd}' (use: status | expand)" ;;
    esac
fi
