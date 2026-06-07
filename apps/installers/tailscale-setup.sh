#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/tailscale-setup.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall Tailscale subnet router LXC on Proxmox
# =============================================================================

set -euo pipefail

if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }

CYAN="\e[36m"
RESET="\e[0m"

# Back-compat wrapper used within this script:
status_message() {
    case "$1" in
        success) ok "$2" ;;
        info)    info "$2" ;;
        *)       fail "$2" ;;   # error → print + exit
    esac
}

# --- Config ------------------------------------------------------------------
HOSTNAME="tailscale"
CTID_DEFAULT=100
MEMORY=512
CORES=1
DISK=2
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"

# --- Precheck ----------------------------------------------------------------
if ! command -v pct &> /dev/null; then
    status_message "error" "pct not found. Run this on the Proxmox host."
fi

# Find existing CTID (if installed)
find_ctid() {
    for id in $(pct list | awk 'NR>1 {print $1}'); do
        if pct config "$id" 2>/dev/null | grep -q "hostname: ${HOSTNAME}"; then
            echo "$id"
            return
        fi
    done
}

EXISTING_CTID=$(find_ctid)

# --- Actions -----------------------------------------------------------------

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

    # Pick free CTID
    local ctid=$CTID_DEFAULT
    while pct status "$ctid" &>/dev/null; do
        ctid=$((ctid + 1))
    done
    status_message "info" "Using CTID $ctid"

    # Detect subnet
    local lan_subnet
    lan_subnet=$(ip -4 -o addr show "$BRIDGE" 2>/dev/null | awk '{print $4}' | head -1 | \
        awk -F/ 'NF==2 {split($1,a,"."); print a[1]"."a[2]"."a[3]".0/"$2}')
    if [[ -z "$lan_subnet" || ! "$lan_subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        status_message "error" "Could not detect subnet from $BRIDGE."
    fi
    status_message "info" "Detected LAN subnet: $lan_subnet"

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

    echo "$lxc_password" > "/root/.tailscale-lxc-${ctid}.pw"
    chmod 600 "/root/.tailscale-lxc-${ctid}.pw"

    # TUN device
    cat >> "/etc/pve/lxc/${ctid}.conf" <<EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

    pct start "$ctid"
    sleep 5

    status_message "info" "Installing Tailscale..."
    pct exec "$ctid" -- bash -c "
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

    # Auth
    echo ""
    echo -e "${CYAN}=============================================="
    echo "  Open the URL below in your browser to log in:"
    echo -e "==============================================${RESET}"
    pct exec "$ctid" -- tailscale up --advertise-routes="$lan_subnet" --accept-routes

    echo ""
    status_message "success" "Setup complete (CTID $ctid, subnet $lan_subnet)."
    echo ""
    echo "  Next: approve subnet route at https://login.tailscale.com/admin/machines"
}

action_update() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "error" "No Tailscale LXC installed."
    fi
    status_message "info" "Updating Tailscale in CTID $EXISTING_CTID..."
    pct exec "$EXISTING_CTID" -- bash -c "
        export LC_ALL=C
        apt update -qq >/dev/null 2>&1
        apt install -y -qq --only-upgrade tailscale
    "
    local version
    version=$(pct exec "$EXISTING_CTID" -- tailscale version | head -1)
    status_message "success" "Tailscale updated. Version: $version"
}

action_uninstall_silent() {
    if [[ -n "$EXISTING_CTID" ]]; then
        pct stop "$EXISTING_CTID" 2>/dev/null || true
        pct destroy "$EXISTING_CTID" --purge 2>/dev/null
        rm -f "/root/.tailscale-lxc-${EXISTING_CTID}.pw"
    fi
}

action_uninstall() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "error" "No Tailscale LXC installed."
    fi
    echo "This will permanently destroy LXC $EXISTING_CTID and remove it from Tailscale."
    read -p "Type 'yes' to confirm: " confirm </dev/tty
    if [[ "$confirm" != "yes" ]]; then
        status_message "info" "Cancelled."
        exit 0
    fi
    status_message "info" "Logging out of Tailscale..."
    pct exec "$EXISTING_CTID" -- tailscale logout 2>/dev/null || true
    status_message "info" "Destroying LXC $EXISTING_CTID..."
    action_uninstall_silent
    status_message "success" "Tailscale LXC removed."
    echo ""
    echo "  Also remove the device from https://login.tailscale.com/admin/machines"
}

action_status() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "info" "Tailscale LXC: not installed"
        return
    fi
    echo ""
    echo "LXC $EXISTING_CTID status:"
    pct status "$EXISTING_CTID"
    echo ""
    echo "Tailscale status:"
    pct exec "$EXISTING_CTID" -- tailscale status 2>/dev/null || echo "  (LXC not running or tailscale not authenticated)"
    echo ""
    echo "Tailscale version:"
    pct exec "$EXISTING_CTID" -- tailscale version 2>/dev/null | head -1 || true
}

# --- Menu --------------------------------------------------------------------

echo ""
echo "================================================================"
echo "  Tailscale LXC Manager"
echo "================================================================"
echo ""
if [[ -n "$EXISTING_CTID" ]]; then
    ok "Installed (CTID $EXISTING_CTID)"
else
    info "Not installed"
fi
echo ""
echo "  1) Install / Reinstall"
echo "  2) Update Tailscale"
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
