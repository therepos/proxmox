#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/setup-vm.sh?$(date +%s))"
# Purpose: One-click Ubuntu VM setup (Webmin + Docker + NVIDIA driver + Kasm)
# Version: Ubuntu
# =============================================================================
# Usage:
#   Run once on a fresh Ubuntu Server VM with GPU passthrough.
#   The script will reboot automatically after the NVIDIA driver install,
#   then resume on next login to complete the remaining steps.
#
# What it installs (in order):
#   1. Webmin           — web-based system admin (makes the rest easier)
#   2. Docker           — container runtime (from official Docker repo)
#   3. NVIDIA driver    — headless driver + container toolkit (via install-gpudriver.sh)
#   4. [REBOOT]         — required to load NVIDIA kernel module
#   5. Kasm Workspaces  — browser-based desktops/apps (via install-kasm.sh)
#
# Environment overrides (same as sub-scripts):
#   KASM_VERSION        Kasm version           (default: 1.18.1)
#   KASM_PORT           Kasm web UI port       (default: 443)
#   NVIDIA_DRIVER_VERSION  Force a driver branch (default: auto-detect)
# =============================================================================

set -euo pipefail

# --- Helpers ----------------------------------------------------------------
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# Proxmox guard
if [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null; then
    fail "This script is for an Ubuntu VM, not the Proxmox host."
fi

# --- State tracking ---------------------------------------------------------
STATE_FILE="/var/lib/setup-vm/state"
GITHUB_BASE="https://github.com/therepos/proxmox/raw/main/apps/installers"

mkdir -p "$(dirname "$STATE_FILE")"

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
bash -c "\$(wget -qLO- '${GITHUB_BASE}/setup-vm.sh?\$(date +%s)')"
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
    bash -c "$(wget -qLO- "${GITHUB_BASE}/install-webmin.sh?$(date +%s)")"
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

step_gpudriver() {
    # If nvidia-smi works, driver is loaded — skip
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        ok "NVIDIA driver is loaded. Skipping."
        # Still run the script to pick up container toolkit if Docker was added
        if command -v docker &>/dev/null && ! docker info 2>/dev/null | grep -q "nvidia"; then
            info "Re-running GPU driver script to configure Docker NVIDIA runtime..."
            bash -c "$(wget -qLO- "${GITHUB_BASE}/install-gpudriver.sh?$(date +%s)")"
        fi
        return 0
    fi

    bash -c "$(wget -qLO- "${GITHUB_BASE}/install-gpudriver.sh?$(date +%s)")"

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
    bash -c "$(wget -qLO- "${GITHUB_BASE}/install-kasm.sh?$(date +%s)")"
}

# --- Main -------------------------------------------------------------------

echo ""
echo "================================================="
echo "  Ubuntu VM Setup — One-Click Installer"
echo "================================================="
echo ""

STATE=$(get_state)

case "$STATE" in
    start)
        info "Starting fresh setup..."
        run_step "1/4  Webmin"        step_webmin
        set_state "docker"
        ;&  # fall through

    docker)
        run_step "2/4  Docker"        step_docker
        set_state "gpudriver"
        ;&

    gpudriver)
        run_step "3/4  NVIDIA Driver" step_gpudriver
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

            # Ensure container toolkit is configured (gpudriver.sh does this,
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
        run_step "4/4  Kasm Workspaces" step_kasm
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

# Cleanup state
rm -rf /var/lib/setup-vm
ok "Setup state cleaned up. All done!"
echo ""