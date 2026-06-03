#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/vm-setup.sh?$(date +%s))"
# Purpose: Ubuntu VM setup + Proxmox-host VirtIO-FS share setup (one script)
# =============================================================================
# This ONE script auto-detects where it runs and does the matching half:
#
#   RUN IT ON THE PROXMOX HOST FIRST:
#     - Creates a directory mapping for the share
#     - Attaches it to the VM as a virtiofs device (auto stop/start the VM)
#     - Optionally chowns the share to the VM user (prompted, irreversible)
#     - Starts the VM
#
#   THEN RUN THE SAME SCRIPT INSIDE THE UBUNTU VM:
#     1. Webmin          — web-based system admin (via webmin-setup.sh)
#     2. Docker          — container runtime (from official Docker repo)
#     3. LVM expand      — grow root LV to fill the disk
#     4. NVIDIA driver   — headless driver + container toolkit (via gpu-driver.sh)
#     5. [REBOOT]        — required to load NVIDIA kernel module (auto-resumes)
#     6. Kasm Workspaces — browser-based desktops/apps (via kasm-setup.sh)
#     7. VirtIO-FS mount — mounts the host share at MOUNT_POINT (persisted, nofail)
#
# So: run on host -> run in VM. Two runs, one file. The host/VM split is
# physical (different machines), so this is the safest automation boundary.
#
# Config (override via env): VMID, VIRTIOFS_TAG, MOUNT_POINT, HOST_SHARE_PATH,
#   CHOWN_ENABLE, CHOWN_PATH, CHOWN_UID, CHOWN_GID, SHUTDOWN_TIMEOUT,
#   KASM_VERSION, KASM_PORT, NVIDIA_DRIVER_VERSION
# =============================================================================

set -euo pipefail

# --- Helpers ----------------------------------------------------------------
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

# Interactive numeric prompt that works under: bash -c "$(wget ...)"
# Reads from /dev/tty when available so piped stdin doesn't swallow input.
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

# --- Environment detection --------------------------------------------------
# This single script runs in TWO places:
#   - On the Proxmox HOST: sets up the directory mapping + attaches virtiofs to
#     the VM + (optionally) chowns the share + starts the VM.
#   - In the Ubuntu VM:     installs Webmin/Docker/NVIDIA/Kasm + mounts virtiofs.
# It auto-detects which side it is on.
is_proxmox_host() {
    [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null
}

# --- Shared config (used by both sides) -------------------------------------
VMID="${VMID:-200}"                   # VM that receives the virtiofs share
VIRTIOFS_TAG="${VIRTIOFS_TAG:-sec}"   # mapping id (host) and mount tag (guest)
MOUNT_POINT="${MOUNT_POINT:-/mnt/sec}"  # where it mounts inside the VM

# --- Host-side config -------------------------------------------------------
HOST_SHARE_PATH="${HOST_SHARE_PATH:-/mnt/sec}"  # directory on the host to share
CHOWN_ENABLE="${CHOWN_ENABLE:-1}"               # 1 = chown the share, 0 = skip
CHOWN_PATH="${CHOWN_PATH:-/mnt/sec}"            # what to chown (WHOLE drive by default)
CHOWN_UID="${CHOWN_UID:-1000}"                  # target owner UID (toor = 1000)
CHOWN_GID="${CHOWN_GID:-1000}"                  # target owner GID
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-120}"     # seconds to wait for graceful VM shutdown

# --- State tracking (VM side only) ------------------------------------------
STATE_FILE="/var/lib/setup-vm/state"
GITHUB_BASE="https://github.com/therepos/proxmox/raw/main/apps/installers"

# Only the VM side uses state tracking; create the dir there.
is_proxmox_host || mkdir -p "$(dirname "$STATE_FILE")"

get_state() {
    [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "start"
}

set_state() {
    echo "$1" > "$STATE_FILE"
}

# --- Resume hook (runs remaining steps after reboot) ------------------------
RESUME_SERVICE="/etc/systemd/system/setup-vm-resume.service"
RESUME_SCRIPT="/var/lib/setup-vm/resume.sh"

install_resume_hook() {
    # Save env overrides so they survive the reboot
    cat > "$RESUME_SCRIPT" <<'INNEREOF'
#!/usr/bin/env bash
exec &> >(tee -a /var/log/setup-vm.log)
echo ""
echo "[$(date)] setup-vm resuming after reboot..."
INNEREOF

    # Append env vars if set
    [[ -n "${KASM_VERSION:-}" ]]          && echo "export KASM_VERSION=\"${KASM_VERSION}\"" >> "$RESUME_SCRIPT"
    [[ -n "${KASM_PORT:-}" ]]             && echo "export KASM_PORT=\"${KASM_PORT}\"" >> "$RESUME_SCRIPT"
    [[ -n "${NVIDIA_DRIVER_VERSION:-}" ]] && echo "export NVIDIA_DRIVER_VERSION=\"${NVIDIA_DRIVER_VERSION}\"" >> "$RESUME_SCRIPT"

    cat >> "$RESUME_SCRIPT" <<INNEREOF
bash -c "\$(wget -qLO- '${GITHUB_BASE}/vm-setup.sh?\$(date +%s)')"
INNEREOF
    chmod +x "$RESUME_SCRIPT"

    cat > "$RESUME_SERVICE" <<EOF
[Unit]
Description=setup-vm resume after reboot
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $RESUME_SCRIPT
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable setup-vm-resume.service
    ok "Resume hook installed (will run automatically after reboot)."
}

remove_resume_hook() {
    if [[ -f "$RESUME_SERVICE" ]]; then
        systemctl disable setup-vm-resume.service 2>/dev/null || true
        rm -f "$RESUME_SERVICE" "$RESUME_SCRIPT"
        systemctl daemon-reload
    fi
}

# --- Step runners -----------------------------------------------------------

run_step() {
    local name="$1" fn="$2"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  STEP: ${name}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    "$fn"
}

step_webmin() {
    if dpkg -l webmin &>/dev/null 2>&1; then
        ok "Webmin is already installed. Skipping."
        return 0
    fi
    bash -c "$(wget -qLO- "${GITHUB_BASE}/webmin-setup.sh?$(date +%s)")"
}

step_docker() {
    if command -v docker &>/dev/null; then
        ok "Docker is already installed. Skipping."
        return 0
    fi
    info "Installing Docker from official repository..."
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg > /dev/null 2>&1

    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list
    fi

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1

    systemctl enable --now docker
    ok "Docker installed and running."

    # Add invoking user to docker group
    REAL_USER="${SUDO_USER:-root}"
    if [[ "$REAL_USER" != "root" ]]; then
        usermod -aG docker "$REAL_USER" 2>/dev/null || true
        ok "User '${REAL_USER}' added to docker group."
    fi
}

step_lvm_expand() {
    # Auto-expand the root LV to use all free space in the VG.
    # Skips if free space is less than 1 GiB (nothing meaningful to claim).

    local lv
    lv=$(findmnt -n -o SOURCE / 2>/dev/null || true)

    if [[ -z "$lv" ]]; then
        warn "Could not detect root LV device. Skipping LVM expansion."
        return 0
    fi

    # Check if it's actually an LVM device
    if ! lvdisplay "$lv" &>/dev/null 2>&1; then
        info "Root filesystem is not on LVM. Skipping LVM expansion."
        return 0
    fi

    # Get free PE count in the VG
    local vg free_pe
    vg=$(lvs --noheadings -o vg_name "$lv" 2>/dev/null | tr -d ' ')
    free_pe=$(vgs --noheadings --units b -o vg_free "$vg" 2>/dev/null | tr -d ' B' || echo 0)

    # Convert to GiB for comparison (1 GiB = 1073741824 bytes)
    local free_gib=$(( free_pe / 1073741824 ))

    if (( free_gib < 1 )); then
        ok "LVM: No significant free space in VG '${vg}' (${free_gib} GiB free). Skipping."
        return 0
    fi

    info "LVM: ${free_gib} GiB free in VG '${vg}'. Expanding root LV to use all available space..."

    lvextend -l +100%FREE "$lv" \
        && ok "Logical volume extended." \
        || { warn "lvextend failed (may already be at max). Continuing."; return 0; }

    resize2fs "$lv" \
        && ok "Filesystem resized. Root partition is now $(df -h / | awk 'NR==2{print $2}')." \
        || warn "resize2fs failed. You may need to resize manually."
}

step_gpudriver() {
    # If nvidia-smi works, driver is loaded — skip
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        ok "NVIDIA driver is loaded. Skipping."
        # Still run the script to pick up container toolkit if Docker was added
        if command -v docker &>/dev/null && ! docker info 2>/dev/null | grep -q "nvidia"; then
            info "Re-running GPU driver script to configure Docker NVIDIA runtime..."
            bash -c "$(wget -qLO- "${GITHUB_BASE}/gpu-driver.sh?$(date +%s)")"
        fi
        return 0
    fi

    bash -c "$(wget -qLO- "${GITHUB_BASE}/gpu-driver.sh?$(date +%s)")"

    # If driver was freshly installed, we need to reboot
    if ! nvidia-smi &>/dev/null 2>&1; then
        set_state "post-reboot"
        install_resume_hook
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  REBOOTING to load NVIDIA kernel module..."
        echo "  Setup will resume automatically after reboot."
        echo "  Progress is logged to /var/log/setup-vm.log"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        sleep 3
        reboot
        exit 0  # unreachable, but keeps shellcheck happy
    fi
}

step_kasm() {
    # Check if Kasm is already installed at target version
    local target="${KASM_VERSION:-1.18.1}"
    if [[ -d /opt/kasm/current ]]; then
        local current
        current=$(readlink -f /opt/kasm/current | grep -oP '\d+\.\d+\.\d+' || true)
        if [[ "$current" == "$target" ]]; then
            ok "Kasm ${target} is already installed. Skipping."
            return 0
        fi
    fi
    bash -c "$(wget -qLO- "${GITHUB_BASE}/kasm-setup.sh?$(date +%s)")"
}

step_virtiofs() {
    # Mount a host directory shared to this VM via virtiofs, and persist it.
    # Requires the host-side device (qm set <vmid> -virtiofs0 dirid=...) to exist.

    # Already mounted? Skip.
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        ok "VirtIO-FS already mounted at ${MOUNT_POINT}. Skipping."
        return 0
    fi

    # Ensure the virtiofs kernel module is available (built-in on modern kernels).
    modprobe virtiofs 2>/dev/null || true

    mkdir -p "$MOUNT_POINT"

    # Add a persistent fstab entry (idempotent). 'nofail' so the VM boots even
    # if the share is not attached on the host.
    local fstab_line="${VIRTIOFS_TAG}  ${MOUNT_POINT}  virtiofs  defaults,nofail  0  0"
    if ! grep -qsE "^\s*${VIRTIOFS_TAG}\s+${MOUNT_POINT}\s+virtiofs" /etc/fstab; then
        echo "$fstab_line" >> /etc/fstab
        ok "Added VirtIO-FS entry to /etc/fstab."
    else
        ok "VirtIO-FS fstab entry already present."
    fi

    # Try to mount now.
    if mount -t virtiofs "$VIRTIOFS_TAG" "$MOUNT_POINT" 2>/dev/null; then
        ok "Mounted VirtIO-FS tag '${VIRTIOFS_TAG}' at ${MOUNT_POINT}."
    else
        warn "Could not mount VirtIO-FS tag '${VIRTIOFS_TAG}'."
        warn "Verify the host has attached the device:"
        warn "    qm set <vmid> -virtiofs0 dirid=${VIRTIOFS_TAG}"
        warn "and that the VM was fully restarted after attaching it."
        warn "Continuing (fstab entry uses 'nofail', so boot is unaffected)."
    fi
}

# ============================================================================
# HOST SIDE — runs only on the Proxmox host
# ============================================================================
# NOTE: pvesh '/cluster/mapping/dir' and 'qm set -virtiofsN' are PVE 8.x/9.x
# syntax. Verified on PVE 9.2.x. Older/newer majors may differ.
host_setup() {
    local VM_WAS_RUNNING=0
    echo ""
    echo "================================================="
    echo "  Proxmox Host — VirtIO-FS Share Setup"
    echo "================================================="
    echo ""

    # Sanity: required tools
    command -v qm   >/dev/null || fail "'qm' not found — is this really a Proxmox host?"
    command -v pvesh >/dev/null || fail "'pvesh' not found — is this really a Proxmox host?"

    # VM must exist
    qm status "$VMID" &>/dev/null || fail "VM ${VMID} does not exist on this host."

    # 1. Ensure the host share directory exists
    if [[ ! -d "$HOST_SHARE_PATH" ]]; then
        fail "Host share path '${HOST_SHARE_PATH}' does not exist. Mount your storage there first."
    fi
    ok "Host share path present: ${HOST_SHARE_PATH}"

    # 2. Create/confirm the directory mapping (idempotent)
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

    # 3. Attach the virtiofs device to the VM (needs VM stopped)
    if qm config "$VMID" | grep -qE "^virtiofs[0-9]+:.*dirid=${VIRTIOFS_TAG}"; then
        ok "VM ${VMID} already has a virtiofs device for '${VIRTIOFS_TAG}'."
    else
        # Stop the VM gracefully if it is running
        local status; status="$(qm status "$VMID" | awk '{print $2}')"
        if [[ "$status" == "running" ]]; then
            info "VM ${VMID} is running; sending graceful shutdown..."
            qm shutdown "$VMID" --timeout "$SHUTDOWN_TIMEOUT" \
                || fail "Graceful shutdown failed/timed out. Aborting (not force-killing)."
            # Wait until actually stopped
            local waited=0
            while [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]]; do
                sleep 2; waited=$((waited+2))
                (( waited >= SHUTDOWN_TIMEOUT )) && fail "VM did not stop within ${SHUTDOWN_TIMEOUT}s."
            done
            ok "VM ${VMID} stopped."
            VM_WAS_RUNNING=1
        else
            VM_WAS_RUNNING=0
        fi

        info "Attaching virtiofs0 (dirid=${VIRTIOFS_TAG}) to VM ${VMID}..."
        qm set "$VMID" -virtiofs0 "dirid=${VIRTIOFS_TAG}" \
            || fail "Failed to attach virtiofs device."
        ok "VirtIO-FS device attached to VM ${VMID}."
    fi

    # 4. Optionally chown the share (BIG, irreversible on whole drive — confirm)
    if [[ "$CHOWN_ENABLE" == "1" ]]; then
        echo ""
        warn "About to: chown -R ${CHOWN_UID}:${CHOWN_GID} ${CHOWN_PATH}"
        warn "This changes ownership of ALL files under that path and cannot be undone."
        if [[ -r /dev/tty ]]; then
            read -rp "Proceed with chown? [y/N]: " ans </dev/tty || ans="n"
        else
            ans="n"
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

    # 5. Start the VM (if we stopped it, or if it was already stopped)
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
    echo "  Next: run THIS SAME SCRIPT inside the VM to finish setup:"
    echo "    bash -c \"\$(wget -qLO- ${GITHUB_BASE}/vm-setup.sh?\$(date +%s))\""
    echo ""
    echo "  The VM-side run will mount the share at ${MOUNT_POINT}"
    echo "  and install Docker / NVIDIA / etc."
    echo ""
}

# --- Host: status -----------------------------------------------------------
host_status() {
    echo ""
    echo "  VirtIO-FS Share Status"
    echo "  ----------------------"
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

# --- Host: remove (undo) ----------------------------------------------------
host_remove() {
    echo ""
    warn "This will detach the virtiofs device from VM ${VMID} and delete the"
    warn "'${VIRTIOFS_TAG}' mapping. Files on ${HOST_SHARE_PATH} are NOT touched."
    local ans="n"
    if [[ -r /dev/tty ]]; then
        read -rp "Proceed with removal? [y/N]: " ans </dev/tty || ans="n"
    fi
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { info "Cancelled."; return 0; }

    # Detach any virtiofs device pointing at our tag (needs VM stopped)
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

    # Delete the mapping
    if pvesh get /cluster/mapping/dir 2>/dev/null | grep -qw "$VIRTIOFS_TAG"; then
        pvesh delete "/cluster/mapping/dir/${VIRTIOFS_TAG}" \
            && ok "Deleted mapping '${VIRTIOFS_TAG}'." \
            || warn "Failed to delete mapping (may not exist)."
    else
        info "Mapping '${VIRTIOFS_TAG}' not present."
    fi
    echo ""
}

# ============================================================================
# DISPATCH — pick host or VM path (each shows an interactive menu)
# ============================================================================
if is_proxmox_host; then
    echo ""
    echo "================================================="
    echo "  Proxmox Host — VirtIO-FS for VM ${VMID}"
    echo "================================================="
    echo "  1) Setup share   (map + attach to VM + chown + restart)"
    echo "  2) Status        (show mapping + device state)"
    echo "  3) Remove        (detach device + delete mapping)"
    echo "  0) Exit"
    choice="$(asknum 'Choose' 0 3 1)"
    case "$choice" in
        0) ok "Bye."; exit 0 ;;
        1) host_setup ;;
        2) host_status ;;
        3) host_remove ;;
    esac
    exit 0
fi

# ----------------------------------------------------------------------------
# Everything below this point runs ONLY inside the Ubuntu VM.
# ----------------------------------------------------------------------------
echo ""
echo "================================================="
echo "  Ubuntu VM Setup — One-Click Installer"
echo "================================================="
echo ""

STATE=$(get_state)

# Detect whether the host attached a virtiofs device (used by menu + warning).
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

# Standalone mount action (used by menu option 2).
do_mount_only() {
    run_step "VirtIO-FS Mount" step_virtiofs
    local ip; ip=$(hostname -I | awk '{print $1}')
    echo ""
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        ok "Mounted at ${MOUNT_POINT}."
    else
        warn "${MOUNT_POINT} not mounted — run the host-side setup first."
    fi
}

# VM status action (menu option 3).
vm_status() {
    echo ""
    echo "  VM Status"
    echo "  ---------"
    echo "  Docker:      $(command -v docker >/dev/null && echo installed || echo missing)"
    echo "  NVIDIA:      $( (command -v nvidia-smi >/dev/null && nvidia-smi &>/dev/null) && echo loaded || echo 'not loaded')"
    echo "  Webmin:      $(dpkg -l webmin &>/dev/null 2>&1 && echo installed || echo missing)"
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        echo "  ${MOUNT_POINT}:  mounted (virtiofs)"
    else
        echo "  ${MOUNT_POINT}:  not mounted"
    fi
    echo "  VirtIO-FS device present: $(virtiofs_device_present && echo yes || echo no)"
    echo ""
}

# Show the menu ONLY on a fresh run. The post-reboot resume must NOT stop for
# input, so it skips the menu and falls straight into the state machine.
if [[ "$STATE" == "start" ]]; then
    if ! virtiofs_device_present; then
        warn "═══════════════════════════════════════════════════════════"
        warn " No VirtIO-FS device detected on this VM."
        warn " The HOST-SIDE setup likely hasn't run yet (run this script"
        warn " on the Proxmox host first to attach the '${VIRTIOFS_TAG}' share)."
        warn " You can still proceed; the ${MOUNT_POINT} mount will be skipped."
        warn "═══════════════════════════════════════════════════════════"
        echo ""
    fi

    echo "================================================="
    echo "  Ubuntu VM Setup"
    echo "================================================="
    echo "  1) Full setup    (Webmin, Docker, NVIDIA, Kasm, mount)"
    echo "  2) Mount share   (VirtIO-FS only)"
    echo "  3) Status"
    echo "  0) Exit"
    choice="$(asknum 'Choose' 0 3 1)"
    case "$choice" in
        0) ok "Bye."; exit 0 ;;
        2) do_mount_only; exit 0 ;;
        3) vm_status; exit 0 ;;
        1) : ;;  # fall through to full setup below
    esac
fi

echo ""
echo "================================================="
echo "  Ubuntu VM Setup — One-Click Installer"
echo "================================================="
echo ""

case "$STATE" in
    start)
        info "Starting fresh setup..."
        run_step "1/6  Webmin"        step_webmin
        set_state "docker"
        ;&  # fall through

    docker)
        run_step "2/6  Docker"        step_docker
        set_state "lvm_expand"
        ;&

    lvm_expand)
        run_step "3/6  LVM Expand"    step_lvm_expand
        set_state "gpudriver"
        ;&

    gpudriver)
        run_step "4/6  NVIDIA Driver" step_gpudriver
        # If step_gpudriver triggers a reboot, we never reach here.
        # If we do reach here, driver is loaded — continue.
        set_state "kasm"
        ;&

    kasm|post-reboot)
        # post-reboot lands here: driver should now be loaded
        if [[ "$STATE" == "post-reboot" ]]; then
            remove_resume_hook
            echo ""
            info "Resumed after reboot. Verifying NVIDIA driver..."
            if nvidia-smi &>/dev/null; then
                ok "NVIDIA driver is loaded!"
                nvidia-smi
            else
                fail "NVIDIA driver failed to load after reboot. Check dmesg for errors."
            fi

            # Ensure container toolkit is configured (gpu-driver.sh does this,
            # but we rebooted so let's make sure Docker picked it up)
            if command -v docker &>/dev/null; then
                if command -v nvidia-ctk &>/dev/null; then
                    info "Ensuring Docker NVIDIA runtime is configured..."
                    nvidia-ctk runtime configure --runtime=docker > /dev/null 2>&1 || true
                    systemctl restart docker
                    ok "Docker NVIDIA runtime ready."
                fi
            fi
        fi

        set_state "kasm"
        run_step "5/6  Kasm Workspaces" step_kasm
        set_state "virtiofs"
        ;&

    virtiofs)
        run_step "6/6  VirtIO-FS Mount"  step_virtiofs
        set_state "done"
        ;&

    done)
        remove_resume_hook  # cleanup in case of re-run
        ;;

    *)
        warn "Unknown state '${STATE}'. Resetting..."
        set_state "start"
        exec "$0" "$@"
        ;;
esac

# --- Final summary ----------------------------------------------------------

SERVER_IP=$(hostname -I | awk '{print $1}')
KASM_PORT="${KASM_PORT:-443}"

echo ""
echo ""
echo "================================================="
echo "  VM Setup Complete!"
echo "================================================="
echo ""
echo "  NVIDIA GPU"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    echo "    $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
    echo "    Docker GPU:  docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi"
fi
echo ""
echo "  Webmin"
echo "    https://${SERVER_IP}:10000"
echo "    Login with your system root credentials."
echo ""
echo "  Kasm Workspaces"
echo "    https://${SERVER_IP}:${KASM_PORT}"
echo "    Admin:  admin@kasm.local / password"
echo "    User:   user@kasm.local  / password"
echo "    CHANGE BOTH PASSWORDS IMMEDIATELY."
echo ""
echo "  A self-signed certificate warning is expected for both."
echo ""
echo "  VirtIO-FS Mount"
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "    tag '${VIRTIOFS_TAG}' -> ${MOUNT_POINT} (mounted)"
else
    echo "    ${MOUNT_POINT} (not mounted)"
    echo "    On the Proxmox host, attach the share then restart this VM:"
    echo "      qm set <vmid> -virtiofs0 dirid=${VIRTIOFS_TAG}"
fi
echo ""

# Cleanup state
rm -rf /var/lib/setup-vm
ok "Setup state cleaned up. All done!"
echo ""