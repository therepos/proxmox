#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/vm-create.sh?$(date +%s))"
# Purpose: Create an Ubuntu VM on the Proxmox host (q35/OVMF + GPU passthrough)
# =============================================================================
# Usage (host only):
#   vm-create create    Interactive create (default when called with no args)
#   vm-create status    Show qm config highlights + whether prereqs pass
#   vm-create remove    Stop + destroy the VM (explicit confirmation)
#
# Note: Creates the VM shell only; install Ubuntu manually via the Proxmox
#   console, then run vm-setup.sh inside the VM. GPU passthrough attaches BOTH
#   PCI functions (.0 video + .1 audio) from one selection.
# Config (env): VMID, VM_NAME, VM_CORES, VM_MEMORY, VM_BALLOON, VM_DISK,
#   VM_BRIDGE, VM_STORAGE, ISO_STORAGE, GPU_PCI, VM_ISO.
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

# Interactive text prompt (same /dev/tty handling as asknum). Enter accepts def.
askstr() { # askstr "prompt" default
    local p="$1" def="$2" in
    if [[ -r /dev/tty ]]; then
        read -rp "$p (default: $def): " in </dev/tty || in="$def"
    else
        read -rp "$p (default: $def): " in || in="$def"
    fi
    echo "${in:-$def}"
}

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

is_proxmox_host() {
    [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null
}

is_proxmox_host || fail "vm-create.sh must run on the Proxmox HOST, not inside a VM."
command -v qm    >/dev/null || fail "'qm' not found — is this really a Proxmox host?"
command -v pvesm >/dev/null || fail "'pvesm' not found — is this really a Proxmox host?"

# --- Config (all overridable by env) -----------------------------------------
VMID="${VMID:-200}"
VM_NAME="${VM_NAME:-ubuntu}"
VM_CORES="${VM_CORES:-16}"
VM_MEMORY="${VM_MEMORY:-32768}"        # max
VM_BALLOON="${VM_BALLOON:-16384}"      # guaranteed floor
VM_DISK="${VM_DISK:-256}"              # GiB
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_STORAGE="${VM_STORAGE:-local-lvm}"
ISO_STORAGE="${ISO_STORAGE:-local}"
GPU_PCI="${GPU_PCI:-}"                 # e.g. "01:00"; empty = autodetect/prompt
VM_ISO="${VM_ISO:-}"                   # empty = prompt from available ISOs

# ============================================================================
# GPU DETECTION
# ============================================================================
# Populates GPU_PCI with a bus:slot like "01:00" (functions are appended later),
# or leaves it empty when the user chooses "none". Skips the emulated QEMU stub.
select_gpu() {
    # Pre-seeded via env: honour it and skip the menu.
    if [[ -n "$GPU_PCI" ]]; then
        info "Using GPU from env: GPU_PCI=${GPU_PCI}"
        return 0
    fi

    local -a slots=() labels=()
    local line slot
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Skip the emulated/integrated QEMU display stub.
        [[ "$line" == *"1234:1111"* ]] && continue
        slot="${line%% *}"                       # e.g. 01:00.0
        slot="${slot%.*}"                         # -> 01:00
        # De-dupe (a GPU exposes .0 and .1; we want the bus:slot once).
        local seen=0 s
        for s in "${slots[@]}"; do [[ "$s" == "$slot" ]] && seen=1; done
        (( seen )) && continue
        slots+=("$slot")
        labels+=("$line")
    done < <(lspci -nn | grep -i 'vga\|3d\|display' || true)

    echo ""
    echo "  Detected GPUs:"
    local i
    for i in "${!slots[@]}"; do
        printf "    %d) %s\n" $((i+1)) "${labels[$i]}"
    done
    printf "    %d) none (skip GPU passthrough)\n" $(( ${#slots[@]} + 1 ))
    echo ""

    local choice; choice="$(asknum 'Select GPU' 1 $(( ${#slots[@]} + 1 )) $(( ${#slots[@]} + 1 )))"
    if (( choice == ${#slots[@]} + 1 )); then
        GPU_PCI=""
        info "No GPU selected — creating a plain VM (no passthrough)."
    else
        GPU_PCI="${slots[$((choice-1))]}"
        ok "Selected GPU at ${GPU_PCI}"
    fi
}

# ============================================================================
# ISO SELECTION
# ============================================================================
select_iso() {
    if [[ -n "$VM_ISO" ]]; then
        info "Using ISO from env: VM_ISO=${VM_ISO}"
        return 0
    fi

    local -a isos=()
    local volid name
    while IFS= read -r volid; do
        [[ -z "$volid" ]] && continue
        name="${volid##*/}"                      # storage:iso/foo.iso -> foo.iso
        isos+=("$name")
    done < <(pvesm list "$ISO_STORAGE" --content iso 2>/dev/null | awk 'NR>1 {print $1}')

    [[ ${#isos[@]} -gt 0 ]] || fail "No ISOs found on storage '${ISO_STORAGE}'. Upload an Ubuntu ISO first (or set VM_ISO / ISO_STORAGE)."

    echo ""
    echo "  Available ISOs on '${ISO_STORAGE}':"
    local i
    for i in "${!isos[@]}"; do
        printf "    %d) %s\n" $((i+1)) "${isos[$i]}"
    done
    echo ""

    local choice; choice="$(asknum 'Select ISO' 1 ${#isos[@]} 1)"
    VM_ISO="${isos[$((choice-1))]}"
    ok "Selected ISO ${VM_ISO}"
}

# ============================================================================
# PREREQUISITE CHECKS (GPU passthrough only — abort on failure)
# ============================================================================
check_iommu() {
    if grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline; then
        ok "IOMMU enabled on the kernel command line."
    else
        warn "IOMMU is NOT enabled. Add to /etc/default/grub:"
        warn '  GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"'
        warn "Then: update-grub && reboot"
        fail "IOMMU not enabled — cannot pass through the GPU."
    fi
}

check_blacklist() {
    local vendor="$1"                            # nvidia | (empty = generic)
    local -a mods=(nouveau)
    [[ "$vendor" == "nvidia" ]] && mods+=(nvidia)

    local m missing=0
    for m in "${mods[@]}"; do
        if grep -rqsE "blacklist[[:space:]]+${m}\b" /etc/modprobe.d/ 2>/dev/null; then
            ok "Host driver '${m}' is blacklisted."
        else
            warn "Host driver '${m}' is NOT blacklisted. Add to /etc/modprobe.d/blacklist-gpu.conf:"
            warn "  blacklist ${m}"
            missing=1
        fi
        if lsmod | awk '{print $1}' | grep -qx "$m"; then
            warn "Host driver '${m}' is currently LOADED (lsmod). It must not bind the GPU."
            missing=1
        fi
    done
    if (( missing )); then
        warn "After editing the blacklist: update-initramfs -u && reboot"
        fail "Host GPU driver not fully blacklisted/unloaded — passthrough would fail."
    fi
}

check_iommu_group() {
    local slot="$1"                              # bus:slot e.g. 01:00
    local dev="0000:${slot}"                     # match .0 and .1 under it
    local grp="" d
    for d in /sys/kernel/iommu_groups/*/devices/${dev}.*; do
        [[ -e "$d" ]] || continue
        grp="$(basename "$(dirname "$(dirname "$d")")")"
        break
    done
    [[ -n "$grp" ]] || fail "Could not resolve IOMMU group for ${dev} — is the GPU present and IOMMU active?"

    local -a others=()
    for d in /sys/kernel/iommu_groups/${grp}/devices/*; do
        local pcidev; pcidev="$(basename "$d")"
        [[ "$pcidev" == "${dev}."* ]] && continue    # the GPU's own functions
        others+=("$pcidev")
    done
    if (( ${#others[@]} > 0 )); then
        warn "IOMMU group ${grp} is shared with other devices:"
        for d in /sys/kernel/iommu_groups/${grp}/devices/*; do
            warn "  $(basename "$d")  $(lspci -nns "$(basename "$d" | sed 's/^0000://')" 2>/dev/null | cut -d' ' -f2-)"
        done
        fail "GPU is not isolated in its own IOMMU group — passthrough will not work reliably."
    fi
    ok "GPU is isolated in IOMMU group ${grp}."
}

check_vmid_free() {
    if qm status "$VMID" &>/dev/null; then
        fail "VMID ${VMID} is already in use. Choose another VMID or remove the existing VM."
    fi
    ok "VMID ${VMID} is free."
}

run_prereqs() {
    local slot="$1" vendor="$2"
    echo ""
    echo "  Running GPU passthrough prerequisite checks..."
    check_iommu
    check_blacklist "$vendor"
    check_iommu_group "$slot"
    check_vmid_free
    ok "All prerequisite checks passed."
}

# ============================================================================
# CREATE
# ============================================================================
do_create() {
    echo ""
    echo "================================================="
    echo "  Proxmox Host — Create Ubuntu VM"
    echo "================================================="

    # --- Prompts (env pre-seeds the defaults) --------------------------------
    VMID="$(asknum 'VMID' 100 999999 "$VMID")"
    VM_NAME="$(askstr 'Hostname' "$VM_NAME")"
    # Show host core count so the user doesn't accidentally over-allocate. CPU
    # over-commit is allowed (vCPUs are time-shared) so this is informational,
    # not a hard limit.
    local host_cores; host_cores="$(nproc 2>/dev/null || echo '?')"
    VM_CORES="$(asknum "CPU cores (host has ${host_cores})" 1 512 "$VM_CORES")"
    VM_MEMORY="$(asknum 'Memory max (MiB)' 512 4194304 "$VM_MEMORY")"
    VM_BALLOON="$(asknum 'Memory min / balloon (MiB)' 0 "$VM_MEMORY" "$VM_BALLOON")"
    VM_DISK="$(asknum 'Disk size (GiB)' 8 65536 "$VM_DISK")"
    VM_BRIDGE="$(askstr 'Network bridge' "$VM_BRIDGE")"

    # --- GPU + ISO selection -------------------------------------------------
    select_gpu
    select_iso

    # --- GPU vendor + prereqs ------------------------------------------------
    local gpu_vendor="" hostpci0="" hostpci1=""
    if [[ -n "$GPU_PCI" ]]; then
        if lspci -nns "$GPU_PCI" 2>/dev/null | grep -qi 'nvidia'; then
            gpu_vendor="nvidia"
        fi
        run_prereqs "$GPU_PCI" "$gpu_vendor"
        hostpci0="${GPU_PCI}.0,pcie=1"
        hostpci1="${GPU_PCI}.1,pcie=1"
    else
        # Still guard against clobbering an existing VM even without a GPU.
        check_vmid_free
    fi

    # --- Review screen -------------------------------------------------------
    echo ""
    echo "================================================="
    echo "  Review — VM to be created"
    echo "================================================="
    echo "  VMID / name    ${VMID} / ${VM_NAME}"
    echo "  Cores / CPU    ${VM_CORES} / host"
    echo "  Memory         ${VM_MEMORY} MiB (balloon floor ${VM_BALLOON} MiB)"
    echo "  Disk           ${VM_DISK} GiB on ${VM_STORAGE}"
    echo "  Network        virtio on ${VM_BRIDGE} (firewall=1)"
    echo "  BIOS           ovmf (UEFI) + efidisk0"
    echo "  Machine        q35"
    if [[ -n "$GPU_PCI" ]]; then
        echo "  GPU            hostpci0=${hostpci0}"
        echo "                 hostpci1=${hostpci1}"
    else
        echo "  GPU            none (no passthrough)"
    fi
    echo "  ISO            ${ISO_STORAGE}:iso/${VM_ISO}"
    echo "  Autostart      onboot=1"
    echo "================================================="
    echo ""

    local proceed; proceed="$(asknum 'Proceed?' 0 1 1)"
    [[ "$proceed" == "1" ]] || { info "Cancelled — nothing created."; return 0; }

    # --- Creation ------------------------------------------------------------
    # --efidisk0 MUST be in the same qm create call as --bios ovmf; adding UEFI
    # to an existing VM without an EFI disk leaves it unbootable.
    info "Creating VM ${VMID}..."
    qm create "$VMID" \
        --name "$VM_NAME" \
        --machine q35 \
        --bios ovmf \
        --cpu host \
        --cores "$VM_CORES" \
        --sockets 1 \
        --numa 0 \
        --memory "$VM_MEMORY" \
        --balloon "$VM_BALLOON" \
        --scsihw virtio-scsi-single \
        --scsi0 "${VM_STORAGE}:${VM_DISK},discard=on,iothread=1,ssd=1" \
        --efidisk0 "${VM_STORAGE}:4,efitype=4m" \
        --net0 "virtio,bridge=${VM_BRIDGE},firewall=1" \
        --ide2 "${ISO_STORAGE}:iso/${VM_ISO},media=cdrom" \
        --boot 'order=scsi0;ide2;net0' \
        --ostype l26 \
        --agent 1 \
        --onboot 1 \
        || fail "qm create failed."
    ok "VM ${VMID} created."

    # Attach BOTH GPU functions (.0 video + .1 audio). Mandatory — passing only
    # .0 leaves the audio function on the host and breaks guest driver init.
    if [[ -n "$GPU_PCI" ]]; then
        info "Attaching GPU functions to VM ${VMID}..."
        qm set "$VMID" \
            --hostpci0 "$hostpci0" \
            --hostpci1 "$hostpci1" \
            || fail "Failed to attach GPU functions."
        ok "GPU functions attached (hostpci0 + hostpci1)."
    fi

    info "Starting VM ${VMID}..."
    qm start "$VMID" || fail "Failed to start VM ${VMID}."
    ok "VM ${VMID} started."

    # --- Completion ----------------------------------------------------------
    echo ""
    echo "================================================="
    echo "  VM ${VMID} created. Next steps:"
    echo "================================================="
    echo "  1) Install Ubuntu via the Proxmox console (VM ${VMID} -> Console)"
    echo "  2) After install, run vm-setup.sh INSIDE the VM"
    echo "     (docker / nvidia driver / virtiofs)"
    echo "  3) Run virtiofs-setup.sh on the HOST to attach the share"
    echo "================================================="
    echo ""
}

# ============================================================================
# STATUS
# ============================================================================
do_status() {
    echo ""
    echo "  VM Create Status"
    echo "  ----------------"
    echo "  VMID:  ${VMID}"
    if qm status "$VMID" &>/dev/null; then
        echo "  State: $(qm status "$VMID" | awk '{print $2}')"
        echo ""
        echo "  qm config highlights:"
        qm config "$VMID" 2>/dev/null | grep -E \
            '^(name|cores|cpu|memory|balloon|bios|machine|efidisk0|scsi0|net0|ide2|hostpci[0-9]|onboot|agent):' \
            | sed 's/^/    /'
    else
        echo "  State: does not exist"
    fi
    echo ""
    echo "  Host passthrough prereqs:"
    grep -qE 'intel_iommu=on|amd_iommu=on' /proc/cmdline \
        && echo "    IOMMU:            enabled" || echo "    IOMMU:            NOT enabled"
    grep -rqsE 'blacklist[[:space:]]+nouveau\b' /etc/modprobe.d/ 2>/dev/null \
        && echo "    nouveau blacklist: present" || echo "    nouveau blacklist: MISSING"
    echo ""
}

# ============================================================================
# REMOVE
# ============================================================================
do_remove() {
    echo ""
    if ! qm status "$VMID" &>/dev/null; then
        info "VM ${VMID} does not exist — nothing to remove."
        return 0
    fi
    warn "This will STOP and DESTROY VM ${VMID} and its disks. This cannot be undone."
    local ans="n"
    if [[ -r /dev/tty ]]; then
        read -rp "Type the VMID (${VMID}) to confirm removal: " ans </dev/tty || ans="n"
    fi
    [[ "$ans" == "$VMID" ]] || { info "Cancelled."; return 0; }

    if [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]; then
        info "Stopping VM ${VMID}..."
        qm stop "$VMID" || fail "Failed to stop VM ${VMID}."
    fi
    qm destroy "$VMID" --purge && ok "VM ${VMID} destroyed." || fail "Failed to destroy VM ${VMID}."
    echo ""
}

# ============================================================================
# DISPATCH
# ============================================================================
cmd="${1:-create}"
case "$cmd" in
    create) do_create ;;
    status) do_status ;;
    remove) do_remove ;;
    *) fail "Unknown command '${cmd}' (use: create | status | remove)" ;;
esac
