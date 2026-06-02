#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/pvenosub-setup.sh?$(date +%s))"
# Purpose: Auto-runs Proxmox VE post-install with sane homelab defaults
# =============================================================================
# Defaults applied:
#   - Disable pve-enterprise repo
#   - Disable ceph-enterprise repo
#   - Add pve-no-subscription repo
#   - Add pve-test repo (disabled state)
#   - Disable subscription nag
#   - Disable HA services
#   - Disable Corosync
#   - Run apt full-upgrade (no prompts)
#   - Reboot at the end
# =============================================================================

set -euo pipefail

# Suppress ALL interactive prompts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none
export UCF_FORCE_CONFFOLD=1

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

# Prechecks
[[ $EUID -eq 0 ]] || status_message "error" "Must be run as root."
command -v pveversion &>/dev/null || status_message "error" "Not a Proxmox VE host."

# Detect Debian codename (bookworm for PVE 8, trixie for PVE 9)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
if [[ -z "$CODENAME" ]]; then
    status_message "error" "Could not detect Debian codename."
fi
status_message "info" "Detected Debian codename: $CODENAME"

echo ""
echo "================================================================"
echo "  Proxmox VE Post-Install (Automated)"
echo "================================================================"
echo ""
echo "This will:"
echo "  - Disable enterprise repos (PVE + Ceph)"
echo "  - Add no-subscription repo"
echo "  - Disable subscription nag"
echo "  - Disable HA + Corosync (single-node)"
echo "  - Run full system upgrade"
echo "  - Reboot when done"
echo ""
read -p "Continue? [y/N]: " confirm </dev/tty
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    status_message "info" "Cancelled."
    exit 0
fi
echo ""

# 1. Disable pve-enterprise (handles both legacy .list and new deb822 .sources)
status_message "info" "Disabling pve-enterprise repo..."
if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
    sed -i 's/^deb/#deb/g' /etc/apt/sources.list.d/pve-enterprise.list
fi
if [[ -f /etc/apt/sources.list.d/pve-enterprise.sources ]]; then
    sed -i 's/^Enabled: true/Enabled: false/g' /etc/apt/sources.list.d/pve-enterprise.sources
fi

# 2. Disable ceph-enterprise
status_message "info" "Disabling ceph-enterprise repo..."
for f in /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph-enterprise.list; do
    [[ -f "$f" ]] && sed -i 's/^deb/#deb/g' "$f"
done
for f in /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph-enterprise.sources; do
    [[ -f "$f" ]] && sed -i 's/^Enabled: true/Enabled: false/g' "$f"
done

# 3. Add pve-no-subscription
status_message "info" "Adding pve-no-subscription repo..."
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# 4. Add pve-test (disabled state, ready to enable manually if ever needed)
status_message "info" "Adding pve-test repo (disabled)..."
cat > /etc/apt/sources.list.d/pve-test.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pvetest
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF

# 5. Disable subscription nag
status_message "info" "Disabling subscription nag..."
NAG_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$NAG_FILE" ]]; then
    sed -i.bak "s/data.status !== 'Active'/false/g" "$NAG_FILE" || true
    systemctl restart pveproxy.service
fi

# 6. Disable HA
status_message "info" "Disabling HA services..."
systemctl disable --now pve-ha-lrm pve-ha-crm 2>/dev/null || true

# 7. Disable Corosync
status_message "info" "Disabling Corosync..."
systemctl disable --now corosync 2>/dev/null || true

# 8. Update (fully non-interactive)
status_message "info" "Running apt update + full-upgrade (this takes a few minutes)..."
apt-get update -qq

apt-get -y -qq \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    full-upgrade

# Clean up
apt-get -y -qq autoremove
apt-get -y -qq autoclean

status_message "success" "Post-install complete."

# 9. Reboot
echo ""
echo "Rebooting in 10 seconds. Press Ctrl+C to cancel."
sleep 10
reboot