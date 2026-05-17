#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/YOUR_USER/YOUR_REPO/raw/main/apps/installers/tailscale-setup.sh?$(date +%s))"
# Purpose: Creates an unprivileged LXC running Tailscale as a subnet router (Proxmox)
# =============================================================================
# Usage:
#   Run on the Proxmox host as root.
#   You'll be prompted once to open the Tailscale auth URL in your browser.
#   After login, approve the subnet route at:
#     https://login.tailscale.com/admin/machines
# =============================================================================

set -euo pipefail

# Helpers
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
YELLOW="\e[33m➜\e[0m"
CYAN="\e[36m"
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

# Config (auto-selected, no prompts)
CTID_DEFAULT=100
HOSTNAME="tailscale"
MEMORY=512
CORES=1
DISK=2
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"

# Precheck: must be on Proxmox host
if ! command -v pct &> /dev/null; then
    status_message "error" "pct not found. Run this on the Proxmox host."
fi

# Uninstall flow
uninstall_tailscale_lxc() {
    echo "Looking for existing Tailscale LXC..."
    local found_ctid=""
    for id in $(pct list | awk 'NR>1 {print $1}'); do
        if pct config "$id" 2>/dev/null | grep -q "hostname: tailscale"; then
            found_ctid=$id
            break
        fi
    done
    if [[ -z "$found_ctid" ]]; then
        status_message "error" "No Tailscale LXC found."
    fi
    echo "Stopping and destroying CTID $found_ctid..."
    pct stop "$found_ctid" 2>/dev/null || true
    pct destroy "$found_ctid"
    status_message "success" "Tailscale LXC ($found_ctid) removed."
    exit 0
}

# Precheck: existing install
if pct list | awk 'NR>1 {print $3}' | grep -qx "tailscale"; then
    echo "A Tailscale LXC already exists."
    read -p "Do you want to uninstall it? [y/N]: " uninstall_response
    if [[ "$uninstall_response" =~ ^[Yy]$ ]]; then
        uninstall_tailscale_lxc
    else
        status_message "success" "Existing Tailscale LXC retained."
        exit 0
    fi
fi

# Auto-pick next free CTID starting at 100
CTID=$CTID_DEFAULT
while pct status "$CTID" &>/dev/null; do
    CTID=$((CTID + 1))
done
status_message "info" "Using CTID $CTID"

# Auto-detect LAN subnet from Proxmox host (FIXED)
LAN_SUBNET=$(ip -4 -o addr show "$BRIDGE" 2>/dev/null | awk '{print $4}' | head -1 | \
    awk -F/ 'NF==2 {split($1,a,"."); print a[1]"."a[2]"."a[3]".0/"$2}')

if [[ -z "$LAN_SUBNET" || ! "$LAN_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    status_message "error" "Could not auto-detect subnet from $BRIDGE. Check 'ip -4 addr show $BRIDGE'."
fi
status_message "info" "Detected LAN subnet: $LAN_SUBNET"

# Fetch latest Debian 12 template
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

# Random password (saved to file for reference)
LXC_PASSWORD=$(openssl rand -base64 16)

# Create LXC
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

# Save password
echo "$LXC_PASSWORD" > "/root/.tailscale-lxc-${CTID}.pw"
chmod 600 "/root/.tailscale-lxc-${CTID}.pw"

# Enable TUN
status_message "info" "Enabling TUN device..."
cat >> "/etc/pve/lxc/${CTID}.conf" <<EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

# Start
status_message "info" "Starting LXC..."
pct start "$CTID"
sleep 5

# Install Tailscale (fix locale first to silence warnings)
status_message "info" "Installing Tailscale inside LXC..."
pct exec "$CTID" -- bash -c "
    export LC_ALL=C
    export LANG=C
    echo 'LC_ALL=C' > /etc/default/locale
    apt update -qq >/dev/null 2>&1
    apt install -y -qq curl >/dev/null 2>&1
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
    sysctl -p >/dev/null
    tailscale set --auto-update >/dev/null 2>&1 || true
"
status_message "success" "Tailscale installed."

# Authenticate (idempotent: skip if already logged in)
if pct exec "$CTID" -- tailscale status 2>&1 | grep -qE "^(Logged out|NeedsLogin)"; then
    echo ""
    echo -e "${CYAN}=============================================="
    echo "  TAILSCALE AUTHENTICATION REQUIRED"
    echo "  Open the URL below in your browser to log in:"
    echo -e "==============================================${RESET}"
    echo ""
    # Run in background, capture URL, display prominently
    pct exec "$CTID" -- tailscale up \
        --advertise-routes="$LAN_SUBNET" \
        --accept-routes 2>&1 | tee /tmp/tailscale-up.log &
    TS_PID=$!

    # Wait for URL to appear, then highlight it
    for i in {1..30}; do
        if grep -q "login.tailscale.com" /tmp/tailscale-up.log 2>/dev/null; then
            AUTH_URL=$(grep -oE 'https://login\.tailscale\.com/a/[a-zA-Z0-9]+' /tmp/tailscale-up.log | head -1)
            echo ""
            echo -e "${CYAN}>>> AUTH URL: ${AUTH_URL} <<<${RESET}"
            echo ""
            break
        fi
        sleep 1
    done

    wait $TS_PID
    rm -f /tmp/tailscale-up.log
else
    status_message "success" "Tailscale already authenticated."
    # Make sure routes are up to date
    pct exec "$CTID" -- tailscale set --advertise-routes="$LAN_SUBNET" >/dev/null 2>&1 || true
fi

echo ""
status_message "success" "Setup complete."
echo ""
echo "  LXC ID:       $CTID"
echo "  Hostname:     $HOSTNAME"
echo "  LAN subnet:   $LAN_SUBNET (advertised)"
echo "  Root pw file: /root/.tailscale-lxc-${CTID}.pw"
echo ""
echo -e "${YELLOW} Next steps:${RESET}"
echo "  1. Approve the subnet route at:"
echo "     https://login.tailscale.com/admin/machines"
echo "     -> Find 'tailscale' device -> Edit route settings -> enable $LAN_SUBNET"
echo "  2. (Optional) Disable key expiry on the same page"
echo "  3. Install Tailscale on your laptop/phone, log in to the same account"
echo "  4. Access Proxmox from anywhere at https://<proxmox-lan-ip>:8006"