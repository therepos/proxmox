#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/vm-setup.sh?$(date +%s))"
# Purpose: Orchestrate Ubuntu VM setup (delegates to standalone installers)
# =============================================================================
# This script auto-detects where it runs and does the matching half. It is a
# PURE ORCHESTRATOR: every install is a standalone script in this folder, so the
# installers remain the single source of truth — update one and every caller
# (including this script) picks up the change automatically.
#
#   RUN IT ON THE PROXMOX HOST FIRST:
#     Delegates to virtiofs-setup.sh to map a host directory and attach it to
#     the VM as a virtiofs device.
#
#   THEN RUN THE SAME SCRIPT INSIDE THE UBUNTU VM:
#     It runs two phases.
#
#     BASE (fixed order, always runs — every useful VM needs these):
#       1. Webmin        — web-based system admin        (webmin-setup.sh)
#       2. LVM expand    — grow root LV to fill the disk   (lvm-setup.sh)
#       3. Docker        — container runtime              (docker-setup.sh)
#       4. NVIDIA driver — driver + container toolkit     (gpu-setup.sh driver)
#                          Auto-skips if no GPU passthrough is present. If the
#                          driver is freshly installed it reboots (exit 10) and
#                          setup resumes automatically afterwards.
#       5. VirtIO-FS     — mount the host share           (virtiofs-setup.sh mount)
#
#     APPS (order-free, configurable via VM_APPS — this is the expandable part):
#       Default: kasm
#       Each name 'foo' runs 'foo-setup.sh' from this folder, so adding an app is
#       just adding its name. Override (resume-safe — persisted across reboot):
#         VM_APPS="kasm portainer filebrowser" \
#           bash -c "$(wget -qLO- .../vm-setup.sh?$(date +%s))"
#
# Two runs, one file. The host/VM split is physical (different machines), so
# that is the safest automation boundary.
#
# Config (override via env): VMID, VIRTIOFS_TAG, MOUNT_POINT, HOST_SHARE_PATH,
#   CHOWN_ENABLE, CHOWN_PATH, CHOWN_UID, CHOWN_GID, SHUTDOWN_TIMEOUT,
#   KASM_VERSION, KASM_PORT, NVIDIA_DRIVER_VERSION, VM_APPS
# =============================================================================

set -euo pipefail

# --- Helpers ----------------------------------------------------------------
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

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

GITHUB_BASE="https://github.com/therepos/proxmox/raw/main/apps/installers"

# Fetch and execute a standalone installer from the repo. Keeps the standalone
# scripts the single source of truth. The ?$(date +%s) cache-buster forces the
# always-latest copy from 'main'. Args after the script name are passed through
# (e.g. run_remote gpu-setup.sh driver -y). Returns the remote script's own exit
# code so callers can act on it (notably exit 10 = "reboot required").
run_remote() {
    local script="$1"; shift
    local url="${GITHUB_BASE}/${script}?$(date +%s)"
    local body
    body="$(wget -qLO- "$url")" || fail "Failed to download ${script} from ${GITHUB_BASE}."
    [[ -n "$body" ]] || fail "Downloaded ${script} but it was empty (bad URL / missing script?)."
    bash -c "$body" "$script" "$@"
}

# ============================================================================
# HOST SIDE — the host's only job is the virtiofs share; delegate it entirely.
# ============================================================================
if is_proxmox_host; then
    info "Proxmox host detected — delegating to virtiofs-setup.sh."
    run_remote virtiofs-setup.sh "$@"
    exit $?
fi

# ============================================================================
# VM SIDE
# ============================================================================
STATE_DIR="/var/lib/setup-vm"
COMPLETED_FILE="${STATE_DIR}/completed"   # one completed step name per line
APPS_FILE="${STATE_DIR}/apps"             # persisted VM_APPS selection (resume-safe)
VERIFY_NVIDIA_FLAG="${STATE_DIR}/verify-nvidia"
mkdir -p "$STATE_DIR"

# Base phase: fixed order. The reboot lives here (NVIDIA).
BASE_STEPS=(webmin lvm docker nvidia virtiofs)

# App phase: order-free, user-configurable (env override; default kasm).
VM_APPS="${VM_APPS:-kasm}"

# --- Resume hook (re-runs this orchestrator after a reboot) -----------------
RESUME_SERVICE="/etc/systemd/system/setup-vm-resume.service"
RESUME_SCRIPT="${STATE_DIR}/resume.sh"

install_resume_hook() {
    cat > "$RESUME_SCRIPT" <<'INNEREOF'
#!/usr/bin/env bash
exec &> >(tee -a /var/log/setup-vm.log)
echo ""
echo "[$(date)] setup-vm resuming after reboot..."
INNEREOF

    # Persist env overrides the standalones consume so they survive the reboot.
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

# --- Completed-step tracking ------------------------------------------------
step_completed() { [[ -f "$COMPLETED_FILE" ]] && grep -qxF "$1" "$COMPLETED_FILE"; }
mark_completed() { step_completed "$1" || echo "$1" >> "$COMPLETED_FILE"; }

# --- Base steps that keep a lightweight orchestrator-side guard --------------
# (Their standalones aren't fully self-skipping, so we avoid re-fetching/running
#  them when the thing is already present. Other steps rely on the standalone's
#  own idempotency.)
step_webmin() {
    if dpkg -l webmin &>/dev/null 2>&1; then
        ok "Webmin is already installed. Skipping."
        return 0
    fi
    run_remote webmin-setup.sh
}

step_docker() {
    if command -v docker &>/dev/null; then
        ok "Docker is already installed. Skipping."
        return 0
    fi
    run_remote docker-setup.sh
    # docker-setup.sh doesn't manage user groups; do it here so the invoking
    # user can run docker without sudo.
    local real_user="${SUDO_USER:-root}"
    if [[ "$real_user" != "root" ]]; then
        usermod -aG docker "$real_user" 2>/dev/null || true
        ok "User '${real_user}' added to docker group."
    fi
}

# --- Step dispatch + titles -------------------------------------------------
# Returns the action's exit code (10 = reboot required).
dispatch_step() {
    case "$1" in
        webmin)     step_webmin ;;
        docker)     step_docker ;;
        lvm)        run_remote lvm-setup.sh ;;
        nvidia)     run_remote gpu-setup.sh driver -y ;;
        virtiofs)   run_remote virtiofs-setup.sh mount ;;
        *)          run_remote "${1}-setup.sh" ;;   # convention: <app> -> <app>-setup.sh
    esac
}

step_title() {
    case "$1" in
        webmin)     echo "Webmin" ;;
        docker)     echo "Docker" ;;
        lvm)        echo "LVM Expand" ;;
        nvidia)     echo "NVIDIA Driver" ;;
        virtiofs)   echo "VirtIO-FS Mount" ;;
        kasm)       echo "Kasm Workspaces" ;;
        *)          echo "$1" ;;
    esac
}

# --- The resumable plan loop ------------------------------------------------
run_plan() {
    local plan=("$@")
    local total=${#plan[@]} idx=0 step rc
    for step in "${plan[@]}"; do
        idx=$((idx+1))
        if step_completed "$step"; then
            ok "[${idx}/${total}] $(step_title "$step"): already done — skipping."
            continue
        fi

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  STEP ${idx}/${total}: $(step_title "$step")"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        rc=0
        dispatch_step "$step" || rc=$?

        if [[ $rc -eq 10 ]]; then
            # Step installed something that needs a reboot (e.g. NVIDIA module).
            # Mark it completed so we don't re-run (and re-reboot) it on resume.
            mark_completed "$step"
            [[ "$step" == "nvidia" ]] && touch "$VERIFY_NVIDIA_FLAG"
            install_resume_hook
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  REBOOTING (required by '$(step_title "$step")')..."
            echo "  Setup resumes automatically after reboot."
            echo "  Progress is logged to /var/log/setup-vm.log"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            sleep 3
            reboot
            exit 0  # unreachable
        elif [[ $rc -ne 0 ]]; then
            fail "[$(step_title "$step")] failed (exit ${rc})."
        fi

        mark_completed "$step"
    done
}

# --- VM status (menu option) ------------------------------------------------
vm_status() {
    echo ""
    echo "  VM Status"
    echo "  ---------"
    echo "  Docker:   $(command -v docker >/dev/null && echo installed || echo missing)"
    echo "  NVIDIA:   $( (command -v nvidia-smi >/dev/null && nvidia-smi &>/dev/null) && echo loaded || echo 'not loaded')"
    echo "  Webmin:   $(dpkg -l webmin &>/dev/null 2>&1 && echo installed || echo missing)"
    if mountpoint -q "/mnt/sec" 2>/dev/null; then
        echo "  /mnt/sec: mounted (virtiofs)"
    else
        echo "  /mnt/sec: not mounted"
    fi
    echo ""
}

# ============================================================================
# DISPATCH (VM side)
# ============================================================================
echo ""
echo "================================================="
echo "  Ubuntu VM Setup — Orchestrator"
echo "================================================="
echo ""

# Resume vs fresh: the COMPLETED_FILE exists only once a full setup has started,
# so its presence means "in progress" (e.g. resuming after the NVIDIA reboot).
RESUMING=0
[[ -f "$COMPLETED_FILE" ]] && RESUMING=1

if [[ $RESUMING -eq 0 ]]; then
    # Fresh run: show the interactive menu (skipped entirely on resume so the
    # headless post-reboot service never blocks on input).
    echo "  1) Full setup    (base: Webmin, LVM, Docker, NVIDIA, mount; apps: ${VM_APPS})"
    echo "  2) Mount share   (VirtIO-FS only)"
    echo "  3) Status"
    echo "  0) Exit"
    choice="$(asknum 'Choose' 0 3 1)"
    case "$choice" in
        0) ok "Bye."; exit 0 ;;
        2) run_remote virtiofs-setup.sh mount; exit 0 ;;
        3) vm_status; exit 0 ;;
        1) : ;;  # fall through to full setup
    esac

    # Lock in the chosen app list (resume-safe) and mark the run as started.
    echo "$VM_APPS" > "$APPS_FILE"
    : > "$COMPLETED_FILE"
else
    info "Resuming setup after reboot..."
    # Use the app list chosen at the start of this run, not the current env.
    [[ -f "$APPS_FILE" ]] && VM_APPS="$(cat "$APPS_FILE")"
fi

# Post-reboot NVIDIA verification (runs once, only after an NVIDIA reboot).
# This is also the loop-breaker: nvidia is already marked completed, so it won't
# re-run; here we just confirm the kernel module actually loaded.
if [[ -f "$VERIFY_NVIDIA_FLAG" ]]; then
    info "Verifying NVIDIA driver after reboot..."
    if nvidia-smi &>/dev/null; then
        ok "NVIDIA driver is loaded!"
        nvidia-smi
        rm -f "$VERIFY_NVIDIA_FLAG"
    else
        rm -f "$VERIFY_NVIDIA_FLAG"
        fail "NVIDIA driver failed to load after reboot. Check dmesg for errors."
    fi
fi

# Run base phase (fixed order) then app phase (order-free). Completed steps are
# skipped, so this is safe to re-enter after the reboot.
run_plan "${BASE_STEPS[@]}" $VM_APPS

# --- Done -------------------------------------------------------------------
remove_resume_hook

SERVER_IP=$(hostname -I | awk '{print $1}')
KASM_PORT="${KASM_PORT:-443}"

echo ""
echo "================================================="
echo "  VM Setup Complete!"
echo "================================================="
echo ""
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    echo "  NVIDIA GPU"
    echo "    $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
    echo "    Docker GPU:  docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi"
    echo ""
fi
echo "  Webmin"
echo "    https://${SERVER_IP}:10000   (system root credentials)"
echo ""
if echo " $VM_APPS " | grep -q " kasm "; then
    echo "  Kasm Workspaces"
    echo "    https://${SERVER_IP}:${KASM_PORT}"
    echo "    admin@kasm.local / password   (CHANGE IMMEDIATELY)"
    echo ""
fi
echo "  VirtIO-FS Mount"
if mountpoint -q "/mnt/sec" 2>/dev/null; then
    echo "    mounted at /mnt/sec"
else
    echo "    /mnt/sec not mounted — run 'virtiofs-setup setup' on the host, then restart the VM."
fi
echo ""
echo "  A self-signed certificate warning is expected for the web UIs."
echo ""

# Cleanup state
rm -rf "$STATE_DIR"
ok "Setup state cleaned up. All done!"
echo ""
