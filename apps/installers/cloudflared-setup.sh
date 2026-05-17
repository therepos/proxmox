#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/cloudflared-setup.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall Cloudflared tunnel LXC on Proxmox
# =============================================================================

set -euo pipefail

GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
YELLOW="\e[33m➜\e[0m"
RESET="\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    elif [[ "$status" == "info" ]]; then
        echo -e "${YELLOW} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# Config
HOSTNAME="cloudflared"
CTID_DEFAULT=110
MEMORY=256
CORES=1
DISK=2
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"

# Precheck
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

# ===== Actions =====

action_install() {
    if [[ -n "$EXISTING_CTID" ]]; then
        echo "Existing LXC found at CTID $EXISTING_CTID. Will be removed first."
        read -p "Continue? [y/N]: " confirm </dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            status_message "info" "Cancelled."
            exit 0
        fi
        action_uninstall_silent
    fi

    # Get token
    local cf_token="${CF_TOKEN:-}"
    if [[ -z "$cf_token" ]]; then
        echo ""
        echo "Get your token: Cloudflare Zero Trust → Networks → Tunnels → Add a connector → copy the 'eyJ...' string"
        echo ""
        read -rsp "CF_TOKEN: " cf_token </dev/tty
        echo ""
    fi
    if [[ -z "$cf_token" ]]; then
        status_message "error" "No token provided."
    fi
    if [[ ! "$cf_token" =~ ^eyJ ]]; then
        status_message "error" "Token doesn't look valid (should start with 'eyJ')."
    fi
    status_message "success" "Token accepted"
    echo ""

    # Pick free CTID
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
        --cores "$CORES" --memory "$MEMORY" --swap "$MEMORY" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
        --rootfs "${STORAGE}:${DISK}" \
        --unprivileged 1 --features nesting=1 --onboot 1 \
        --password "$lxc_password" >/dev/null

    echo "$lxc_password" > "/root/.cloudflared-lxc-${ctid}.pw"
    chmod 600 "/root/.cloudflared-lxc-${ctid}.pw"

    pct start "$ctid"
    sleep 5

    status_message "info" "Installing cloudflared..."
    pct exec "$ctid" -- bash -c "
        export LC_ALL=C
        export LANG=C
        echo 'LC_ALL=C' > /etc/default/locale
        apt update -qq >/dev/null 2>&1
        apt install -y -qq curl >/dev/null 2>&1
        mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main' \
            > /etc/apt/sources.list.d/cloudflared.list
        apt update -qq >/dev/null 2>&1
        apt install -y -qq cloudflared >/dev/null 2>&1
    "

    status_message "info" "Registering tunnel..."
    pct exec "$ctid" -- cloudflared service install "$cf_token" >/dev/null 2>&1
    unset cf_token
    unset CF_TOKEN

    sleep 5
    if pct exec "$ctid" -- systemctl is-active --quiet cloudflared; then
        status_message "success" "Tunnel is running."
    else
        echo ""
        pct exec "$ctid" -- journalctl -u cloudflared --no-pager -n 20
        status_message "error" "Cloudflared service failed to start. Check token validity."
    fi

    echo ""
    status_message "success" "Setup complete (CTID $ctid). Add public hostnames in Cloudflare dashboard to expose services."
}

action_update() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "error" "No Cloudflared LXC installed."
    fi
    status_message "info" "Updating cloudflared in CTID $EXISTING_CTID..."
    pct exec "$EXISTING_CTID" -- bash -c "
        export LC_ALL=C
        apt update -qq >/dev/null 2>&1
        apt install -y -qq --only-upgrade cloudflared
    "
    pct exec "$EXISTING_CTID" -- systemctl restart cloudflared
    sleep 3
    if pct exec "$EXISTING_CTID" -- systemctl is-active --quiet cloudflared; then
        local version
        version=$(pct exec "$EXISTING_CTID" -- cloudflared --version | head -1)
        status_message "success" "Updated and restarted. $version"
    else
        status_message "error" "Service failed to restart after update."
    fi
}

action_uninstall_silent() {
    if [[ -n "$EXISTING_CTID" ]]; then
        # Cleanly remove the connector from Cloudflare's side
        pct exec "$EXISTING_CTID" -- cloudflared service uninstall 2>/dev/null || true
        pct stop "$EXISTING_CTID" 2>/dev/null || true
        pct destroy "$EXISTING_CTID" --purge 2>/dev/null
        rm -f "/root/.cloudflared-lxc-${EXISTING_CTID}.pw"
    fi
}

action_uninstall() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "error" "No Cloudflared LXC installed."
    fi
    echo "This will permanently destroy LXC $EXISTING_CTID and unregister the tunnel connector."
    read -p "Type 'yes' to confirm: " confirm </dev/tty
    if [[ "$confirm" != "yes" ]]; then
        status_message "info" "Cancelled."
        exit 0
    fi
    status_message "info" "Removing connector and destroying LXC $EXISTING_CTID..."
    action_uninstall_silent
    status_message "success" "Cloudflared LXC removed."
    echo ""
    echo "  Tunnel itself is still in Cloudflare. Delete from dashboard if no longer needed."
}

action_status() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "info" "Cloudflared LXC: not installed"
        return
    fi
    echo ""
    echo "LXC $EXISTING_CTID status:"
    pct status "$EXISTING_CTID"
    echo ""
    echo "Cloudflared service:"
    pct exec "$EXISTING_CTID" -- systemctl is-active cloudflared 2>/dev/null || echo "  (not running)"
    echo ""
    echo "Cloudflared version:"
    pct exec "$EXISTING_CTID" -- cloudflared --version 2>/dev/null | head -1 || true
    echo ""
    echo "Recent logs:"
    pct exec "$EXISTING_CTID" -- journalctl -u cloudflared --no-pager -n 5 2>/dev/null || true
}

# ===== Menu =====

echo ""
echo "================================================================"
echo "  Cloudflared LXC Manager"
echo "================================================================"
echo ""
if [[ -n "$EXISTING_CTID" ]]; then
    echo -e "  Status: ${GREEN} Installed (CTID $EXISTING_CTID)"
else
    echo -e "  Status: ${YELLOW} Not installed"
fi
echo ""
echo "  1) Install / Reinstall"
echo "  2) Update Cloudflared"
echo "  3) Uninstall"
echo "  4) Show status"
echo "  q) Quit"
echo ""
read -p "Select an option: " choice </dev/tty
echo ""

case "$choice" in
    1) action_install ;;
    2) action_update ;;
    3) action_uninstall ;;
    4) action_status ;;
    q|Q) status_message "info" "Bye."; exit 0 ;;
    *) status_message "error" "Invalid option." ;;
esac