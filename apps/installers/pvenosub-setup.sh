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

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export APT_LISTCHANGES_FRONTEND=none
export UCF_FORCE_CONFFOLD=1

GREEN="\e[32m\xe2\x9c\x94\e[0m"
RED="\e[31m\xe2\x9c\x98\e[0m"
YELLOW="\e[33m\xe2\x9e\x9c\e[0m"

C_GREEN="\e[32m"
C_RED="\e[31m"
C_YELLOW="\e[33m"
C_DIM="\e[90m"
C_RESET="\e[0m"

LOG_FILE="/tmp/pvenosub-setup.log"
: > "$LOG_FILE"

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

function disable_sources_file() {
    local f=$1
    [[ -f "$f" ]] || return 0
    if grep -qi '^Enabled:' "$f"; then
        sed -i 's/^[Ee]nabled:.*/Enabled: false/' "$f"
    else
        [[ -n "$(tail -c1 "$f")" ]] && echo "" >> "$f"
        echo "Enabled: false" >> "$f"
    fi
}

function disable_list_file() {
    local f=$1
    [[ -f "$f" ]] || return 0
    sed -i 's/^deb/#deb/g' "$f"
}

SPIN_FRAMES=("\xe2\xa0\x8b" "\xe2\xa0\x99" "\xe2\xa0\xb9" "\xe2\xa0\xb8" "\xe2\xa0\xbc" "\xe2\xa0\xb4" "\xe2\xa0\xa6" "\xe2\xa0\xa7" "\xe2\xa0\x87" "\xe2\xa0\x8f")

function run_with_spinner() {
    local msg=$1
    shift

    if [[ ! -t 1 ]]; then
        echo -e "${YELLOW} ${msg}"
        if "$@" >>"$LOG_FILE" 2>&1; then
            echo -e "${GREEN} ${msg}"
            return 0
        else
            echo -e "${RED} ${msg} (see ${LOG_FILE})"
            exit 1
        fi
    fi

    "$@" >>"$LOG_FILE" 2>&1 &
    local pid=$!

    local i=0 start now elapsed mins secs
    start=$(date +%s)
    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$(( now - start ))
        mins=$(( elapsed / 60 ))
        secs=$(( elapsed % 60 ))
        i=$(( (i + 1) % ${#SPIN_FRAMES[@]} ))
        printf "\r${C_YELLOW}${SPIN_FRAMES[$i]}${C_RESET} %s ${C_DIM}(%d:%02d)${C_RESET} " \
            "$msg" "$mins" "$secs"
        sleep 0.2
    done

    wait "$pid"
    local rc=$?
    tput cnorm 2>/dev/null || true

    now=$(date +%s)
    elapsed=$(( now - start ))
    mins=$(( elapsed / 60 ))
    secs=$(( elapsed % 60 ))

    if [[ $rc -eq 0 ]]; then
        printf "\r${C_GREEN}\xe2\x9c\x94${C_RESET} %s ${C_DIM}(%d:%02d)${C_RESET}\e[K\n" \
            "$msg" "$mins" "$secs"
        return 0
    else
        printf "\r${C_RED}\xe2\x9c\x98${C_RESET} %s ${C_DIM}(failed, see ${LOG_FILE})${C_RESET}\e[K\n" \
            "$msg"
        exit 1
    fi
}

[[ $EUID -eq 0 ]] || status_message "error" "Must be run as root."
command -v pveversion &>/dev/null || status_message "error" "Not a Proxmox VE host."

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

status_message "info" "Disabling pve-enterprise repo..."
disable_list_file    /etc/apt/sources.list.d/pve-enterprise.list
disable_sources_file /etc/apt/sources.list.d/pve-enterprise.sources

status_message "info" "Disabling ceph-enterprise repo..."
disable_list_file    /etc/apt/sources.list.d/ceph.list
disable_list_file    /etc/apt/sources.list.d/ceph-enterprise.list
disable_sources_file /etc/apt/sources.list.d/ceph.sources
disable_sources_file /etc/apt/sources.list.d/ceph-enterprise.sources

status_message "info" "Adding pve-no-subscription repo..."
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

status_message "info" "Adding pve-test repo (disabled)..."
cat > /etc/apt/sources.list.d/pve-test.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pvetest
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF

status_message "info" "Disabling subscription nag..."
NAG_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$NAG_FILE" ]]; then
    sed -i.bak "s/data.status !== 'Active'/false/g" "$NAG_FILE" || true
    systemctl restart pveproxy.service 2>/dev/null || true
fi

status_message "info" "Disabling HA services..."
systemctl disable --now pve-ha-lrm pve-ha-crm 2>/dev/null || true

status_message "info" "Disabling Corosync..."
systemctl disable --now corosync 2>/dev/null || true

run_with_spinner "Refreshing package lists..." \
    apt-get update -qq

run_with_spinner "Running full system upgrade (this takes a few minutes)..." \
    apt-get -y -qq \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    full-upgrade

run_with_spinner "Cleaning up unused packages..." \
    apt-get -y -qq autoremove

run_with_spinner "Clearing apt cache..." \
    apt-get -y -qq autoclean

status_message "success" "Post-install complete. Full log: ${LOG_FILE}"

echo ""
echo "Rebooting in 10 seconds. Press Ctrl+C to cancel."
sleep 10
reboot