#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/hermes-setup.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall Hermes Agent LXC (Docker) on Proxmox
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

CYAN="\e[36m"
RESET="\e[0m"

status_message() {
    case "$1" in
        success) ok "$2" ;;
        info)    info "$2" ;;
        *)       fail "$2" ;;
    esac
}

# --- Config ------------------------------------------------------------------
HOSTNAME="hermes"
CTID_DEFAULT=120
MEMORY=8192
CORES=2
DISK=32
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"

IMAGE="nousresearch/hermes-agent:latest"
DATA_DIR="/opt/hermes"          # host-side (inside LXC) state: config, sessions, memory, skills
DASH_PORT=9119                  # dashboard
GW_PORT=8642                    # optional chat gateway / OpenAI-compatible API
# Dashboard fails closed without an auth provider when bound off-loopback.
# Default to loopback; reach it over Tailscale + SSH tunnel, or set to 0.0.0.0
# only after configuring auth in the dashboard settings.
DASH_BIND="127.0.0.1"

# --- Precheck ----------------------------------------------------------------
if ! command -v pct &> /dev/null; then
    status_message "error" "pct not found. Run this on the Proxmox host."
fi

find_ctid() {
    for id in $(pct list | awk 'NR>1 {print $1}'); do
        if pct config "$id" 2>/dev/null | grep -q "hostname: ${HOSTNAME}"; then
            echo "$id"
            return
        fi
    done
}

EXISTING_CTID=$(find_ctid)

ct_ip() {
    pct exec "$1" -- ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true
}

# --- Actions -----------------------------------------------------------------

action_install() {
    if [[ -n "$EXISTING_CTID" ]]; then
        echo "Existing LXC found at CTID $EXISTING_CTID. Will be removed first."
        echo "This destroys the Hermes data volume (sessions, memory, skills, cron)."
        read -p "Continue? [y/N]: " confirm </dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            status_message "info" "Cancelled."
            exit 0
        fi
        action_uninstall_silent
    fi

    local ctid=$CTID_DEFAULT
    while pct status "$ctid" &>/dev/null; do
        ctid=$((ctid + 1))
    done
    status_message "info" "Using CTID $ctid"

    # Template
    pveam update >/dev/null
    local template
    template=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1)
    if [[ -z "$template" ]]; then
        status_message "error" "No Debian 12 template found."
    fi
    if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$template"; then
        status_message "info" "Downloading template..."
        pveam download "$TEMPLATE_STORAGE" "$template" >/dev/null
    fi

    local lxc_password
    lxc_password=$(openssl rand -base64 16)

    status_message "info" "Creating LXC..."
    pct create "$ctid" "${TEMPLATE_STORAGE}:vztmpl/${template}" \
        --hostname "$HOSTNAME" \
        --cores "$CORES" --memory "$MEMORY" --swap 2048 \
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
        --rootfs "${STORAGE}:${DISK}" \
        --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 \
        --password "$lxc_password" >/dev/null

    echo "$lxc_password" > "/root/.hermes-lxc-${ctid}.pw"
    chmod 600 "/root/.hermes-lxc-${ctid}.pw"

    pct start "$ctid"
    sleep 5

    status_message "info" "Installing Docker..."
    pct exec "$ctid" -- bash -c "
        export LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive
        echo 'LC_ALL=C' > /etc/default/locale
        apt update -qq >/dev/null 2>&1
        apt install -y -qq curl ca-certificates >/dev/null 2>&1
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        systemctl enable --now docker >/dev/null 2>&1
    " || status_message "error" "Docker install failed."
    status_message "success" "Docker installed."

    status_message "info" "Deploying Hermes Agent..."
    pct exec "$ctid" -- bash -c "
        set -e
        mkdir -p ${DATA_DIR}/data
        cat > ${DATA_DIR}/docker-compose.yml <<'YAML'
services:
  hermes:
    image: ${IMAGE}
    container_name: hermes
    command: gateway run
    restart: unless-stopped
    volumes:
      - ${DATA_DIR}/data:/opt/data
    ports:
      - \"${DASH_BIND}:${DASH_PORT}:${DASH_PORT}\"
      - \"${DASH_BIND}:${GW_PORT}:${GW_PORT}\"
    environment:
      - TZ=Asia/Singapore
YAML
        cd ${DATA_DIR} && docker compose pull -q && docker compose up -d
    " || status_message "error" "Hermes deploy failed. Check: pct exec $ctid -- docker compose -f ${DATA_DIR}/docker-compose.yml logs"

    sleep 5
    local ip
    ip=$(ct_ip "$ctid")

    echo ""
    status_message "success" "Hermes Agent LXC ready (CTID $ctid, ${ip:-no ip})."
    echo ""
    echo -e "${CYAN}=============================================="
    echo "  Next: run the setup wizard"
    echo -e "==============================================${RESET}"
    echo ""
    echo "  pct exec $ctid -- docker exec -it hermes hermes onboarding"
    echo ""
    echo "  You will need: an LLM API key (e.g. Gemini) and a"
    echo "  messaging channel token (e.g. Telegram bot token)."
    echo ""
    echo "  Dashboard is bound to loopback inside the LXC."
    echo "  Reach it with:  ssh -L ${DASH_PORT}:127.0.0.1:${DASH_PORT} root@${ip}"
    echo "  LXC root password: /root/.hermes-lxc-${ctid}.pw"
    echo ""
}

action_wizard() {
    [[ -z "$EXISTING_CTID" ]] && status_message "error" "No Hermes LXC installed."
    pct exec "$EXISTING_CTID" -- docker exec -it hermes hermes onboarding
}

action_shell() {
    [[ -z "$EXISTING_CTID" ]] && status_message "error" "No Hermes LXC installed."
    pct exec "$EXISTING_CTID" -- docker exec -it hermes bash
}

action_update() {
    [[ -z "$EXISTING_CTID" ]] && status_message "error" "No Hermes LXC installed."
    status_message "info" "Pulling latest image in CTID $EXISTING_CTID..."
    # Docker installs do not support `hermes update` — pull a new tag instead.
    pct exec "$EXISTING_CTID" -- bash -c "
        cd ${DATA_DIR} && docker compose pull && docker compose up -d && docker image prune -f
    "
    status_message "success" "Hermes updated. State in ${DATA_DIR}/data preserved."
}

action_logs() {
    [[ -z "$EXISTING_CTID" ]] && status_message "error" "No Hermes LXC installed."
    pct exec "$EXISTING_CTID" -- docker logs --tail 100 -f hermes
}

action_backup() {
    [[ -z "$EXISTING_CTID" ]] && status_message "error" "No Hermes LXC installed."
    local stamp dest
    stamp=$(date +%Y%m%d-%H%M%S)
    dest="/root/hermes-backup-${stamp}.tar.gz"
    status_message "info" "Archiving ${DATA_DIR}/data..."
    pct exec "$EXISTING_CTID" -- tar czf - -C "${DATA_DIR}" data > "$dest"
    status_message "success" "Backup written to $dest"
}

action_uninstall_silent() {
    if [[ -n "$EXISTING_CTID" ]]; then
        pct stop "$EXISTING_CTID" 2>/dev/null || true
        pct destroy "$EXISTING_CTID" --purge 2>/dev/null
        rm -f "/root/.hermes-lxc-${EXISTING_CTID}.pw"
    fi
}

action_uninstall() {
    [[ -z "$EXISTING_CTID" ]] && status_message "error" "No Hermes LXC installed."
    echo "This will permanently destroy LXC $EXISTING_CTID including all"
    echo "Hermes sessions, memory, skills and cron jobs."
    read -p "Type 'yes' to confirm: " confirm </dev/tty
    if [[ "$confirm" != "yes" ]]; then
        status_message "info" "Cancelled."
        exit 0
    fi
    status_message "info" "Destroying LXC $EXISTING_CTID..."
    action_uninstall_silent
    status_message "success" "Hermes LXC removed."
}

action_status() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "info" "Hermes LXC: not installed"
        return
    fi

    local state ip
    state=$(pct status "$EXISTING_CTID" | awk '{print $2}')
    ip=$(ct_ip "$EXISTING_CTID")

    echo ""
    echo "LXC $EXISTING_CTID status:"
    echo "${ip:-(no ip)}  ${state}"

    echo ""
    echo "Container:"
    pct exec "$EXISTING_CTID" -- docker ps --filter name=hermes \
        --format '  {{.Image}}  {{.Status}}' 2>/dev/null || echo "  (not running)"

    echo ""
    echo "Health:"
    pct exec "$EXISTING_CTID" -- docker exec hermes hermes doctor 2>/dev/null \
        || warn "hermes doctor failed — not configured yet?"

    echo ""
    echo "Gateways:"
    pct exec "$EXISTING_CTID" -- docker exec hermes hermes gateway status 2>/dev/null \
        || warn "no gateway configured"

    echo ""
    echo "State dir:"
    pct exec "$EXISTING_CTID" -- du -sh "${DATA_DIR}/data" 2>/dev/null || true
}

# --- Menu --------------------------------------------------------------------

echo ""
echo "================================================================"
echo "  Hermes Agent LXC Manager"
echo "================================================================"
echo ""
if [[ -n "$EXISTING_CTID" ]]; then
    ok "Installed (CTID $EXISTING_CTID)"
else
    info "Not installed"
fi
echo ""
echo "  1) Install / Reinstall"
echo "  2) Run setup wizard"
echo "  3) Update Hermes"
echo "  4) Show status"
echo "  5) Follow logs"
echo "  6) Backup state"
echo "  7) Shell into container"
echo "  8) Uninstall"
echo "  q) Quit"
echo ""
read -p "Select an option: " choice </dev/tty
echo ""

case "$choice" in
    1) action_install ;;
    2) action_wizard ;;
    3) action_update ;;
    4) action_status ;;
    5) action_logs ;;
    6) action_backup ;;
    7) action_shell ;;
    8) action_uninstall ;;
    q|Q) status_message "info" "Bye."; exit 0 ;;
    *) status_message "error" "Invalid option." ;;
esac
