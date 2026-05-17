#!/usr/bin/env bash
# CF_TOKEN="eyJh..." bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/cloudflared-setup.sh?$(date +%s))"
# Purpose: Creates an unprivileged LXC running Cloudflared tunnel (Proxmox)
# =============================================================================
# Usage:
#   1. Create a tunnel in Cloudflare Zero Trust dashboard:
#        Networks → Tunnels → Create a tunnel → Cloudflared → Name it
#   2. Copy the token from the "Install and run a connector" page
#        (the long string after --token in the docker command)
#   3. Run:
#        CF_TOKEN="paste-token-here" bash -c "$(wget -qLO- <raw-url>)"
#   4. Add public hostnames in the same Cloudflare dashboard, pointing to your
#      internal IPs (e.g. proxmox.yourdomain.com → http://192.168.0.111:8006)
# =============================================================================

set -euo pipefail

GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
YELLOW="\e[33m➜\e[0m"

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

CTID_DEFAULT=110
HOSTNAME="cloudflared"
MEMORY=256
CORES=1
DISK=2
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"

if ! command -v pct &> /dev/null; then
    status_message "error" "pct not found. Run this on the Proxmox host."
fi

uninstall_cloudflared_lxc() {
    echo "Looking for existing Cloudflared LXC..."
    local found_ctid=""
    for id in $(pct list | awk 'NR>1 {print $1}'); do
        if pct config "$id" 2>/dev/null | grep -q "hostname: cloudflared"; then
            found_ctid=$id
            break
        fi
    done
    if [[ -z "$found_ctid" ]]; then
        status_message "error" "No Cloudflared LXC found."
    fi
    echo "Stopping and destroying CTID $found_ctid..."
    pct stop "$found_ctid" 2>/dev/null || true
    pct destroy "$found_ctid"
    status_message "success" "Cloudflared LXC ($found_ctid) removed."
    exit 0
}

# Precheck: existing install
if pct list | awk 'NR>1 {print $3}' | grep -qx "cloudflared"; then
    echo "A Cloudflared LXC already exists."
    read -p "Do you want to uninstall it? [y/N]: " uninstall_response
    if [[ "$uninstall_response" =~ ^[Yy]$ ]]; then
        uninstall_cloudflared_lxc
    else
        status_message "success" "Existing Cloudflared LXC retained."
        exit 0
    fi
fi

# Token required
if [[ -z "${CF_TOKEN:-}" ]]; then
    status_message "error" "CF_TOKEN env var not set. See script header for usage."
fi

# Auto-pick next free CTID
CTID=$CTID_DEFAULT
while pct status "$CTID" &>/dev/null; do
    CTID=$((CTID + 1))
done
status_message "info" "Using CTID $CTID"

# Template
status_message "info" "Updating template list..."
pveam update >/dev/null
TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1)
if [[ -z "$TEMPLATE" ]]; then
    status_message "error" "No Debian 12 template found in pveam."
fi
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
    status_message "info" "Downloading template $TEMPLATE..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null
fi

LXC_PASSWORD=$(openssl rand -base64 16)

status_message "info" "Creating LXC $CTID..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$MEMORY" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --rootfs "${STORAGE}:${DISK}" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --password "$LXC_PASSWORD" >/dev/null

echo "$LXC_PASSWORD" > "/root/.cloudflared-lxc-${CTID}.pw"
chmod 600 "/root/.cloudflared-lxc-${CTID}.pw"

status_message "info" "Starting LXC..."
pct start "$CTID"
sleep 5

status_message "info" "Installing cloudflared inside LXC..."
pct exec "$CTID" -- bash -c "
    apt update -qq
    apt install -y -qq curl >/dev/null
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main' \
        > /etc/apt/sources.list.d/cloudflared.list
    apt update -qq
    apt install -y -qq cloudflared >/dev/null
"

status_message "info" "Installing tunnel service with provided token..."
pct exec "$CTID" -- cloudflared service install "$CF_TOKEN" >/dev/null

status_message "info" "Verifying service is running..."
sleep 3
if pct exec "$CTID" -- systemctl is-active --quiet cloudflared; then
    status_message "success" "Cloudflared tunnel is running."
else
    status_message "error" "Cloudflared service failed to start. Check 'pct enter $CTID' and 'journalctl -u cloudflared'."
fi

echo ""
status_message "success" "Setup complete."
echo ""
echo "  LXC ID:       $CTID"
echo "  Hostname:     $HOSTNAME"
echo "  Root pw file: /root/.cloudflared-lxc-${CTID}.pw"
echo ""
echo "  Next: add public hostnames in the Cloudflare Zero Trust dashboard,"
echo "  pointing to your internal services, e.g.:"
echo "    proxmox.yourdomain.com → http://192.168.0.111:8006"