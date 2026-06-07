#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/virtiofs-setup.sh?$(date +%s))"
# Purpose: VirtIO-FS share — Proxmox host setup + Ubuntu VM mount (auto-detects)
# =============================================================================
# Auto-detects whether it runs on a Proxmox host or inside a VM.
#
#   On the Proxmox HOST (run this first):
#     virtiofs-setup            Interactive menu
#     virtiofs-setup setup      Map a host dir + attach virtiofs to the VM
#                               (gracefully stops/starts the VM as needed)
#     virtiofs-setup status     Show mapping + device state
#     virtiofs-setup remove     Detach device + delete mapping
#
#   Inside the Ubuntu VM:
#     virtiofs-setup            Interactive menu
#     virtiofs-setup mount      Mount the share + persist in fstab (idempotent)
#     virtiofs-setup status     Show mount state
#     virtiofs-setup unmount    Unmount + remove the fstab entry
#
# Config (override via env): VMID, VIRTIOFS_TAG, MOUNT_POINT, HOST_SHARE_PATH,
#   CHOWN_ENABLE, CHOWN_PATH, CHOWN_UID, CHOWN_GID, SHUTDOWN_TIMEOUT
#
# NOTE: pvesh '/cluster/mapping/dir' and 'qm set -virtiofsN' are PVE 8.x/9.x
# syntax. Verified on PVE 9.2.x. Older/newer majors may differ.
# =============================================================================

set -euo pipefail

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

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

is_proxmox_host() {
    [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null
}

# --- Config -----------------------------------------------------------------
VMID="${VMID:-200}"                             # VM that receives the share
VIRTIOFS_TAG="${VIRTIOFS_TAG:-sec}"             # mapping id (host) / mount tag (guest)
MOUNT_POINT="${MOUNT_POINT:-/mnt/sec}"          # where it mounts inside the VM
HOST_SHARE_PATH="${HOST_SHARE_PATH:-/mnt/sec}"  # directory on the host to share
CHOWN_ENABLE="${CHOWN_ENABLE:-1}"               # 1 = offer to chown the share, 0 = skip
CHOWN_PATH="${CHOWN_PATH:-/mnt/sec}"            # what to chown
CHOWN_UID="${CHOWN_UID:-1000}"                  # target owner UID
CHOWN_GID="${CHOWN_GID:-1000}"                  # target owner GID
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"     # seconds to wait for graceful VM shutdown

# ============================================================================
# HOST SIDE
# ============================================================================
host_setup() {
    local VM_WAS_RUNNING=0
    echo ""
    echo "================================================="
    echo "  Proxmox Host — VirtIO-FS Share Setup"
    echo "================================================="
    echo ""

    command -v qm    >/dev/null || fail "'qm' not found — is this really a Proxmox host?"
    command -v pvesh >/dev/null || fail "'pvesh' not found — is this really a Proxmox host?"

    qm status "$VMID" &>/dev/null || fail "VM ${VMID} does not exist on this host."

    if [[ ! -d "$HOST_SHARE_PATH" ]]; then
        fail "Host share path '${HOST_SHARE_PATH}' does not exist. Mount your storage there first."
    fi
    ok "Host share path present: ${HOST_SHARE_PATH}"

    # Create/confirm the directory mapping (idempotent)
    if pvesh get /cluster/mapping/dir 2>/dev/null | grep -qw "$VIRTIOFS_TAG"; then
        ok "Directory mapping '${VIRTIOFS_TAG}' already exists."
    else
        info "Creating directory mapping '${VIRTIOFS_TAG}' -> ${HOST_SHARE_PATH}..."
        local node; node="$(hostname)"
        pvesh create /cluster/mapping/dir \
            --id "$VIRTIOFS_TAG" \
            --map "node=${node},path=${HOST_SHARE_PATH}" \
            || fail "Failed to create directory mapping."
        ok "Directory mapping created."
    fi

    # Attach the virtiofs device to the VM (needs VM stopped)
    if qm config "$VMID" | grep -qE "^virtiofs[0-9]+:.*dirid=${VIRTIOFS_TAG}"; then
        ok "VM ${VMID} already has a virtiofs device for '${VIRTIOFS_TAG}'."
    else
        local status; status="$(qm status "$VMID" | awk '{print $2}')"
        if [[ "$status" == "running" ]]; then
            info "VM ${VMID} is running; sending graceful shutdown..."
            qm shutdown "$VMID" --timeout "$SHUTDOWN_TIMEOUT" \
                || fail "Graceful shutdown failed/timed out. Aborting (not force-killing)."
            local waited=0
            while [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]; do
                sleep 2; waited=$((waited+2))
                (( waited >= SHUTDOWN_TIMEOUT )) && fail "VM did not stop within ${SHUTDOWN_TIMEOUT}s."
            done
            ok "VM ${VMID} stopped."
            VM_WAS_RUNNING=1
        fi

        info "Attaching virtiofs0 (dirid=${VIRTIOFS_TAG}) to VM ${VMID}..."
        qm set "$VMID" -virtiofs0 "dirid=${VIRTIOFS_TAG}" \
            || fail "Failed to attach virtiofs device."
        ok "VirtIO-FS device attached to VM ${VMID}."
    fi

    # Optionally chown the share (BIG, irreversible on whole drive — confirm)
    if [[ "$CHOWN_ENABLE" == "1" ]]; then
        echo ""
        warn "About to: chown -R ${CHOWN_UID}:${CHOWN_GID} ${CHOWN_PATH}"
        warn "This changes ownership of ALL files under that path and cannot be undone."
        local ans="n"
        if [[ -r /dev/tty ]]; then
            read -rp "Proceed with chown? [y/N]: " ans </dev/tty || ans="n"
        fi
        if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
            info "Chowning ${CHOWN_PATH} (this may take a while on large drives)..."
            chown -R "${CHOWN_UID}:${CHOWN_GID}" "$CHOWN_PATH" \
                && ok "Ownership set to ${CHOWN_UID}:${CHOWN_GID} on ${CHOWN_PATH}." \
                || warn "chown encountered errors; review manually."
        else
            warn "Skipped chown. You can set CHOWN_ENABLE=0 to silence this prompt."
        fi
    fi

    # Start the VM
    if [[ "$(qm status "$VMID" | awk '{print $2}')" != "running" ]]; then
        info "Starting VM ${VMID}..."
        qm start "$VMID" || fail "Failed to start VM ${VMID}."
        ok "VM ${VMID} started."
    fi

    echo ""
    echo "================================================="
    echo "  Host side complete."
    echo "================================================="
    echo ""
    echo "  Next: inside the VM, mount the share with:"
    echo "    virtiofs-setup mount"
    echo "  (or run the full vm-setup.sh, which mounts it automatically)"
    echo ""
}

host_status() {
    echo ""
    echo "  VirtIO-FS Share Status (host)"
    echo "  -----------------------------"
    echo "  VMID:            ${VMID}"
    echo "  Tag:             ${VIRTIOFS_TAG}"
    echo "  Host path:       ${HOST_SHARE_PATH}"
    if pvesh get /cluster/mapping/dir 2>/dev/null | grep -qw "$VIRTIOFS_TAG"; then
        echo "  Mapping:         present"
    else
        echo "  Mapping:         MISSING"
    fi
    if qm config "$VMID" 2>/dev/null | grep -qE "^virtiofs[0-9]+:.*dirid=${VIRTIOFS_TAG}"; then
        echo "  VM device:       attached"
    else
        echo "  VM device:       not attached"
    fi
    echo "  VM power state:  $(qm status "$VMID" 2>/dev/null | awk '{print $2}')"
    echo ""
}

host_remove() {
    echo ""
    warn "This will detach the virtiofs device from VM ${VMID} and delete the"
    warn "'${VIRTIOFS_TAG}' mapping. Files on ${HOST_SHARE_PATH} are NOT touched."
    local ans="n"
    if [[ -r /dev/tty ]]; then
        read -rp "Proceed with removal? [y/N]: " ans </dev/tty || ans="n"
    fi
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { info "Cancelled."; return 0; }

    local vfdev
    vfdev="$(qm config "$VMID" 2>/dev/null | grep -oE "^virtiofs[0-9]+" | head -1 || true)"
    if [[ -n "$vfdev" ]]; then
        local status; status="$(qm status "$VMID" | awk '{print $2}')"
        if [[ "$status" == "running" ]]; then
            info "Stopping VM ${VMID} to detach ${vfdev}..."
            qm shutdown "$VMID" --timeout "$SHUTDOWN_TIMEOUT" \
                || fail "Graceful shutdown failed/timed out. Aborting."
            while [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]; do sleep 2; done
            ok "VM stopped."
        fi
        qm set "$VMID" --delete "$vfdev" && ok "Detached ${vfdev} from VM ${VMID}."
    else
        info "No virtiofs device on VM ${VMID}."
    fi

    if pvesh get /cluster/mapping/dir 2>/dev/null | grep -qw "$VIRTIOFS_TAG"; then
        pvesh delete "/cluster/mapping/dir/${VIRTIOFS_TAG}" \
            && ok "Deleted mapping '${VIRTIOFS_TAG}'." \
            || warn "Failed to delete mapping (may not exist)."
    else
        info "Mapping '${VIRTIOFS_TAG}' not present."
    fi
    echo ""
}

host_menu() {
    echo ""
    echo "================================================="
    echo "  Proxmox Host — VirtIO-FS for VM ${VMID}"
    echo "================================================="
    echo "  1) Setup    (map + attach to VM + chown + restart)"
    echo "  2) Status   (show mapping + device state)"
    echo "  3) Remove   (detach device + delete mapping)"
    echo "  0) Exit"
    local choice; choice="$(asknum 'Choose' 0 3 1)"
    case "$choice" in
        0) ok "Bye." ;;
        1) host_setup ;;
        2) host_status ;;
        3) host_remove ;;
    esac
}

# ============================================================================
# VM SIDE
# ============================================================================
virtiofs_device_present() {
    local d
    for d in /sys/bus/virtio/devices/virtio*; do
        [[ -e "$d/driver" ]] || continue
        if readlink "$d/driver" 2>/dev/null | grep -q "virtiofs"; then
            return 0
        fi
    done
    return 1
}

vm_mount() {
    # Mount the host directory shared to this VM via virtiofs, and persist it.
    # Requires the host-side device to exist (virtiofs-setup setup, on the host).
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        ok "VirtIO-FS already mounted at ${MOUNT_POINT}. Nothing to do."
        return 0
    fi

    modprobe virtiofs 2>/dev/null || true
    mkdir -p "$MOUNT_POINT"

    # Persistent fstab entry (idempotent). 'nofail' so the VM boots even if the
    # share is not attached on the host.
    local fstab_line="${VIRTIOFS_TAG}  ${MOUNT_POINT}  virtiofs  defaults,nofail  0  0"
    if ! grep -qsE "^\s*${VIRTIOFS_TAG}\s+${MOUNT_POINT}\s+virtiofs" /etc/fstab; then
        echo "$fstab_line" >> /etc/fstab
        ok "Added VirtIO-FS entry to /etc/fstab."
    else
        ok "VirtIO-FS fstab entry already present."
    fi

    if mount -t virtiofs "$VIRTIOFS_TAG" "$MOUNT_POINT" 2>/dev/null; then
        ok "Mounted VirtIO-FS tag '${VIRTIOFS_TAG}' at ${MOUNT_POINT}."
    else
        warn "Could not mount VirtIO-FS tag '${VIRTIOFS_TAG}'."
        warn "Verify the host has attached the device (run on the host):"
        warn "    virtiofs-setup setup"
        warn "and that the VM was fully restarted afterwards."
        warn "Continuing (fstab entry uses 'nofail', so boot is unaffected)."
    fi
}

vm_unmount() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" && ok "Unmounted ${MOUNT_POINT}." || warn "umount failed."
    else
        info "${MOUNT_POINT} is not mounted."
    fi
    if grep -qsE "^\s*${VIRTIOFS_TAG}\s+${MOUNT_POINT}\s+virtiofs" /etc/fstab; then
        sed -i -E "\#^[[:space:]]*${VIRTIOFS_TAG}[[:space:]]+${MOUNT_POINT}[[:space:]]+virtiofs#d" /etc/fstab
        ok "Removed VirtIO-FS entry from /etc/fstab."
    fi
}

vm_status() {
    echo ""
    echo "  VirtIO-FS Status (VM)"
    echo "  ---------------------"
    echo "  Tag:           ${VIRTIOFS_TAG}"
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        echo "  ${MOUNT_POINT}:  mounted (virtiofs)"
    else
        echo "  ${MOUNT_POINT}:  not mounted"
    fi
    echo "  Device present: $(virtiofs_device_present && echo yes || echo no)"
    echo ""
}

vm_menu() {
    echo ""
    echo "================================================="
    echo "  VirtIO-FS (VM)"
    echo "================================================="
    if ! virtiofs_device_present; then
        warn "No VirtIO-FS device detected — run 'virtiofs-setup setup' on the host first."
    fi
    echo "  1) Mount share   (mount + persist fstab)"
    echo "  2) Status"
    echo "  3) Unmount       (umount + remove fstab entry)"
    echo "  0) Exit"
    local choice; choice="$(asknum 'Choose' 0 3 1)"
    case "$choice" in
        0) ok "Bye." ;;
        1) vm_mount ;;
        2) vm_status ;;
        3) vm_unmount ;;
    esac
}

# ============================================================================
# DISPATCH
# ============================================================================
if is_proxmox_host; then
    cmd="${1:-menu}"
    case "$cmd" in
        menu)   host_menu ;;
        setup)  host_setup ;;
        status) host_status ;;
        remove) host_remove ;;
        *) fail "Unknown host command '${cmd}' (use: setup | status | remove)" ;;
    esac
else
    cmd="${1:-menu}"
    case "$cmd" in
        menu)    vm_menu ;;
        mount)   vm_mount ;;
        status)  vm_status ;;
        unmount) vm_unmount ;;
        *) fail "Unknown VM command '${cmd}' (use: mount | status | unmount)" ;;
    esac
fi
