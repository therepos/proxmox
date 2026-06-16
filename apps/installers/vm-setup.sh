#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/vm-setup.sh?$(date +%s))"
# Purpose: Orchestrate Ubuntu VM setup (delegates to standalone installers)
# =============================================================================
# Usage (auto-detects side; run on host first, then inside the VM):
#   Host:  delegates to virtiofs-setup.sh (map host dir + attach to VM)
#   VM:    BASE steps (fixed order): webmin -> disk -> docker -> nvidia -> virtiofs
#          APPS (order-free, env VM_APPS; default kasm): each 'foo' -> foo-setup.sh
#
# Note: NVIDIA auto-skips without GPU; a fresh driver reboots (exit 10) and
#   setup resumes automatically. VM_APPS is persisted resume-safe across reboot.
# Config (env): VMID, VIRTIOFS_TAG, MOUNT_POINT, HOST_SHARE_PATH, CHOWN_ENABLE,
#   CHOWN_PATH, CHOWN_UID, CHOWN_GID, SHUTDOWN_TIMEOUT, KASM_VERSION, KASM_PORT,
#   NVIDIA_DRIVER_VERSION, VM_APPS.
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
LOG_FILE="/var/log/setup-vm.log"
mkdir -p "$STATE_DIR"

# Base phase: fixed order. The reboot lives here (NVIDIA).
BASE_STEPS=(webmin disk docker nvidia virtiofs)

# App phase: order-free, user-configurable (env override; default kasm).
VM_APPS="${VM_APPS:-kasm}"

# --- Resume hook (re-runs this orchestrator after a reboot) ------------------
RESUME_SERVICE="/etc/systemd/system/setup-vm-resume.service"
RESUME_SCRIPT="${STATE_DIR}/resume.sh"

install_resume_hook() {
    cat > "$RESUME_SCRIPT" <<'INNEREOF'
#!/usr/bin/env bash
# vm-setup.sh tees its own output to the log, so we don't duplicate it here.
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

# --- Completed-step tracking -------------------------------------------------
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

# --- Step dispatch + titles --------------------------------------------------
# Returns the action's exit code (10 = reboot required).
dispatch_step() {
    case "$1" in
        webmin)     step_webmin ;;
        docker)     step_docker ;;
        disk)       run_remote disk-setup.sh expand ;;
        nvidia)     run_remote gpu-setup.sh driver -y ;;
        virtiofs)   run_remote virtiofs-setup.sh mount ;;
        *)          run_remote "${1}-setup.sh" ;;   # convention: <app> -> <app>-setup.sh
    esac
}

step_title() {
    case "$1" in
        webmin)     echo "Webmin" ;;
        docker)     echo "Docker" ;;
        disk)       echo "Disk Expand" ;;
        nvidia)     echo "NVIDIA Driver" ;;
        virtiofs)   echo "VirtIO-FS Mount" ;;
        kasm)       echo "Kasm Workspaces" ;;
        *)          echo "$1" ;;
    esac
}

# --- The resumable plan loop -------------------------------------------------
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

# --- Friendly one-line summary of everything Full setup will run -------------
full_summary() {
    local apps_disp="" a
    for a in $VM_APPS; do apps_disp+=", ${a^}"; done   # capitalize each app name
    echo "Webmin, Disk, Docker, NVIDIA, VirtIO-FS${apps_disp}"
}

# --- Status (menu option) ----------------------------------------------------
vm_status() {
    echo ""
    echo "================================================="
    echo "  Status"
    echo "================================================="
    echo "  Webmin    $(dpkg -l webmin &>/dev/null 2>&1 && echo installed || echo missing)"
    echo "  Docker    $(command -v docker >/dev/null && echo installed || echo missing)"
    echo "  NVIDIA    $( (command -v nvidia-smi >/dev/null && nvidia-smi &>/dev/null) && echo loaded || echo 'not loaded')"
    echo "  Kasm      $([[ -d /opt/kasm/current ]] && echo installed || echo missing)"
    echo "  Root disk $(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" used ("$5")"}')"
    echo "  /mnt/sec  $(mountpoint -q /mnt/sec 2>/dev/null && echo 'mounted (virtiofs)' || echo 'not mounted')"
    echo "================================================="
    echo ""
}

# --- Access info -------------------------------------------------------------
# Computes everything LIVE (current IP, ports from config) so it is never stale.
# Used both by the menu and the completion summary.
print_access_block() {
    local ip webmin_port kasm_port
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" ]] || ip="<this-vm-ip>"
    webmin_port="$(awk -F= '/^port=/{print $2; exit}' /etc/webmin/miniserv.conf 2>/dev/null)"
    [[ -n "$webmin_port" ]] || webmin_port=10000
    kasm_port="$(docker port kasm_proxy 2>/dev/null | awk -F: 'NR==1{print $2}')"
    [[ -n "$kasm_port" ]] || kasm_port="${KASM_PORT:-443}"

    echo "  IP address   ${ip}"
    echo ""
    if dpkg -l webmin &>/dev/null 2>&1; then
        echo "  Webmin       https://${ip}:${webmin_port}"
        echo "               login: your system root credentials"
        echo ""
    fi
    if [[ -d /opt/kasm/current ]]; then
        echo "  Kasm         https://${ip}:${kasm_port}"
        echo "               user: admin@kasm.local   (password: as you set it)"
        echo ""
    fi
    echo "  VirtIO-FS    $(mountpoint -q /mnt/sec 2>/dev/null && echo '/mnt/sec (mounted)' || echo '/mnt/sec (not mounted)')"
    echo ""
    echo "  Full log     ${LOG_FILE}"
}

access_info() {
    echo ""
    echo "================================================="
    echo "  Access info"
    echo "================================================="
    print_access_block
    echo "================================================="
    echo ""
}

# ============================================================================
# DISPATCH (VM side)
# ============================================================================
# Log the whole VM-side run — both the initial run and the post-reboot resume —
# to a single persistent file. (The resume hook no longer tees, to avoid dupes.)
# Decide colour from the real terminal first, force it on for delegated child
# scripts so colour survives the tee pipe, and strip ANSI on the way to the log
# so the log file stays clean text.
[[ -t 1 ]] && export FORCE_COLOR=1
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

echo ""
echo "================================================="
echo "  Ubuntu VM Setup"
echo "================================================="
echo ""

# Resume vs fresh: the COMPLETED_FILE exists only once a full setup has started,
# so its presence means "in progress" (e.g. resuming after the NVIDIA reboot).
RESUMING=0
[[ -f "$COMPLETED_FILE" ]] && RESUMING=1

if [[ $RESUMING -eq 0 ]]; then
    # Fresh run: interactive menu loop (skipped entirely on resume so the
    # headless post-reboot service never blocks on input). Mount/Status/Access
    # info return to the menu; only Full setup and Exit end the loop.
    while true; do
        echo "  1) Full setup    ($(full_summary))"
        echo "  2) Mount share   (VirtIO-FS only)"
        echo "  3) Disk          (check usage / expand)"
        echo "  4) Status"
        echo "  5) Access info"
        echo "  0) Exit"
        choice="$(asknum 'Choose' 0 5 0)"
        case "$choice" in
            0) ok "Bye."; exit 0 ;;
            1) echo ""; break ;;                         # proceed to full setup
            2) run_remote virtiofs-setup.sh mount; echo "" ;;
            3) run_remote disk-setup.sh; echo "" ;;
            4) vm_status ;;
            5) access_info ;;
        esac
    done

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

# --- Done --------------------------------------------------------------------
remove_resume_hook

echo ""
echo "================================================="
echo "  VM Setup Complete!"
echo "================================================="
echo ""
print_access_block
echo ""
echo "  A self-signed certificate warning is expected for the web UIs."
echo ""

# Cleanup state (the log at $LOG_FILE is kept — it lives outside STATE_DIR).
rm -rf "$STATE_DIR"
ok "Setup state cleaned up. All done!"
echo ""
