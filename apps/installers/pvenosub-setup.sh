#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/pvenosub-setup.sh?$(date +%s))"
# Purpose: Automate the Proxmox VE Helper-Scripts post-install with single-node
#          homelab defaults. Primary objective: remove the subscription nag.
# =============================================================================
# Defaults applied (no prompts):
#   - Correct Proxmox/Debian base sources
#   - Disable pve-enterprise repo
#   - Disable ceph-enterprise repo
#   - Enable pve-no-subscription repo
#   - Add pve-test repo (disabled state)
#   - Disable subscription nag (web + mobile UI)
#   - Disable HA services (pve-ha-lrm, pve-ha-crm)
#   - Disable Corosync
#   - Run apt dist-upgrade (no prompts)
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

LOG_FILE="/tmp/pve-postinstall-auto.log"
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

# --- Preconditions -----------------------------------------------------------
[[ $EUID -eq 0 ]] || status_message "error" "Must be run as root."
command -v pveversion &>/dev/null || status_message "error" "Not a Proxmox VE host."

PVE_VERSION="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
PVE_MAJOR="${PVE_VERSION%%.*}"
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
[[ -n "$CODENAME" ]] || status_message "error" "Could not detect Debian codename."

status_message "info" "Detected Proxmox VE $PVE_VERSION (Debian $CODENAME)"

if [[ "$PVE_MAJOR" != "8" && "$PVE_MAJOR" != "9" ]]; then
    status_message "error" "Unsupported Proxmox VE major version: $PVE_MAJOR (supports 8.x and 9.x)"
fi

echo ""
echo "================================================================"
echo "  Proxmox VE Post-Install (Automated, single-node defaults)"
echo "================================================================"
echo ""
echo "This will:"
echo "  - Correct base Debian/Proxmox sources"
echo "  - Disable enterprise repos (PVE + Ceph)"
echo "  - Enable no-subscription repo"
echo "  - Add pve-test repo (disabled)"
echo "  - Disable subscription nag (web + mobile)"
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

# --- Sources -----------------------------------------------------------------
if [[ "$PVE_MAJOR" == "8" ]]; then
    # Bookworm: legacy .list format
    status_message "info" "Correcting base Debian sources (.list)..."
    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${CODENAME} main contrib
deb http://deb.debian.org/debian ${CODENAME}-updates main contrib
deb http://security.debian.org/debian-security ${CODENAME}-security main contrib
EOF
    echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' \
        > /etc/apt/apt.conf.d/no-bookworm-firmware.conf

    status_message "info" "Disabling pve-enterprise repo..."
    cat > /etc/apt/sources.list.d/pve-enterprise.list <<EOF
# deb https://enterprise.proxmox.com/debian/pve ${CODENAME} pve-enterprise
EOF

    status_message "info" "Enabling pve-no-subscription repo..."
    cat > /etc/apt/sources.list.d/pve-install-repo.list <<EOF
deb http://download.proxmox.com/debian/pve ${CODENAME} pve-no-subscription
EOF

    status_message "info" "Disabling ceph-enterprise repo..."
    cat > /etc/apt/sources.list.d/ceph.list <<EOF
# deb https://enterprise.proxmox.com/debian/ceph-reef ${CODENAME} enterprise
# deb http://download.proxmox.com/debian/ceph-reef ${CODENAME} no-subscription
EOF

    status_message "info" "Adding pve-test repo (disabled)..."
    cat > /etc/apt/sources.list.d/pvetest-for-beta.list <<EOF
# deb http://download.proxmox.com/debian/pve ${CODENAME} pvetest
EOF

else
    # Trixie (PVE 9): deb822 .sources format
    status_message "info" "Migrating to deb822 base sources (.sources)..."
    rm -f /etc/apt/sources.list.d/*.list
    sed -i '/proxmox/d;/'"${CODENAME}"'/d' /etc/apt/sources.list 2>/dev/null || true
    cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${CODENAME}
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: ${CODENAME}-security
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: ${CODENAME}-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    status_message "info" "Disabling pve-enterprise repo..."
    disable_sources_file /etc/apt/sources.list.d/pve-enterprise.sources

    status_message "info" "Disabling ceph-enterprise repo..."
    disable_sources_file /etc/apt/sources.list.d/ceph.sources
    disable_sources_file /etc/apt/sources.list.d/ceph-enterprise.sources

    status_message "info" "Enabling pve-no-subscription repo..."
    cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
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
Components: pve-test
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: false
EOF
fi

# --- Subscription nag (web + mobile, via Helper-Scripts method) ---------------
status_message "info" "Disabling subscription nag..."
mkdir -p /usr/local/bin
cat > /usr/local/bin/pve-remove-nag.sh <<'EOF'
#!/bin/sh
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    echo "Patching Web UI nag..."
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    echo "Patching Mobile UI nag..."
    printf "%s\n" \
      "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');" \
      "    dialogs.forEach(dialog => {" \
      "      const text = (dialog.textContent || '').toLowerCase();" \
      "      if (text.includes('subscription')) { dialog.remove(); }" \
      "    });" \
      "    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');" \
      "    cards.forEach(card => {" \
      "      const text = (card.textContent || '').toLowerCase();" \
      "      const hasButton = card.querySelector('button');" \
      "      if (!hasButton && text.includes('subscription')) { card.remove(); }" \
      "    });" \
      "  }" \
      "  const observer = new MutationObserver(removeSubscriptionElements);" \
      "  observer.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => {observer.disconnect();}, 10000);" \
      "</script>" \
      "" >> "$MOBILE_TPL"
fi
EOF
chmod 755 /usr/local/bin/pve-remove-nag.sh

cat > /etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };
EOF
chmod 644 /etc/apt/apt.conf.d/no-nag-script

# Reinstall toolkit to trigger the patch immediately
apt --reinstall install -y proxmox-widget-toolkit >>"$LOG_FILE" 2>&1 \
    || status_message "info" "Widget toolkit reinstall deferred to upgrade step"

# --- HA + Corosync (single-node) ---------------------------------------------
status_message "info" "Disabling HA services..."
systemctl disable --now pve-ha-lrm pve-ha-crm 2>/dev/null || true

status_message "info" "Disabling Corosync..."
systemctl disable --now corosync 2>/dev/null || true

# --- Upgrade -----------------------------------------------------------------
run_with_spinner "Refreshing package lists..." \
    apt-get update -qq

run_with_spinner "Running full system upgrade (this takes a few minutes)..." \
    apt-get -y -qq \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    dist-upgrade

run_with_spinner "Cleaning up unused packages..." \
    apt-get -y -qq autoremove

run_with_spinner "Clearing apt cache..." \
    apt-get -y -qq autoclean

status_message "success" "Post-install complete. Full log: ${LOG_FILE}"

echo ""
echo "Clear your browser cache / hard-reload (Ctrl+Shift+R) after reboot."
echo "Rebooting in 10 seconds. Press Ctrl+C to cancel."
sleep 10
reboot