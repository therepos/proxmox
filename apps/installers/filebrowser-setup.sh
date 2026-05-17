#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/filebrowser-setup.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall FileBrowser directly on Proxmox host
# WARNING: Installing on host is not best practice. Prefer LXC.

set -euo pipefail

GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
YELLOW="\e[33m➜\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then echo -e "${GREEN} ${message}"
    elif [[ "$status" == "info" ]]; then echo -e "${YELLOW} ${message}"
    else echo -e "${RED} ${message}"; exit 1
    fi
}

FB_BIN="/usr/local/bin/filebrowser"
FB_DB="/etc/filebrowser/filebrowser.db"
FB_PORT=3001
FB_ROOT="/"

[[ $EUID -eq 0 ]] || status_message "error" "Run as root."

INSTALLED=0
[[ -x "$FB_BIN" ]] && INSTALLED=1

action_install() {
    if [[ $INSTALLED -eq 1 ]]; then
        echo "FileBrowser already installed."
        read -p "Reinstall? [y/N]: " r </dev/tty
        [[ ! "$r" =~ ^[Yy]$ ]] && exit 0
        action_uninstall_silent
    fi

    read -p "Root path FileBrowser will serve (default /): " root_input </dev/tty
    FB_ROOT="${root_input:-/}"

    read -p "Port (default 3001): " port_input </dev/tty
    FB_PORT="${port_input:-3001}"

    local fb_password
    fb_password=$(openssl rand -base64 12)

    status_message "info" "Installing FileBrowser..."
    apt update -qq >/dev/null
    apt install -y -qq curl tar ca-certificates >/dev/null

    local fb_version
    fb_version=$(curl -fsSL https://api.github.com/repos/filebrowser/filebrowser/releases/latest | grep tag_name | cut -d'"' -f4)
    [[ -z "$fb_version" ]] && status_message "error" "Could not fetch FileBrowser version."

    cd /tmp
    rm -f fb.tar.gz filebrowser
    curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/${fb_version}/linux-amd64-filebrowser.tar.gz" -o fb.tar.gz
    [[ ! -s fb.tar.gz ]] && status_message "error" "Download failed."
    tar -xzf fb.tar.gz
    [[ ! -f /tmp/filebrowser ]] && status_message "error" "Binary not in archive."
    install -m 755 /tmp/filebrowser "$FB_BIN"
    rm -f /tmp/fb.tar.gz /tmp/filebrowser /tmp/LICENSE /tmp/README.md /tmp/CHANGELOG.md 2>/dev/null || true

    mkdir -p /etc/filebrowser /srv/filebrowser
    "$FB_BIN" config init --database "$FB_DB" >/dev/null
    "$FB_BIN" config set --address 0.0.0.0 --port "$FB_PORT" --root "$FB_ROOT" --database "$FB_DB" >/dev/null
    "$FB_BIN" users add admin "$fb_password" --perm.admin --database "$FB_DB" >/dev/null

    cat > /etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=FileBrowser
After=network.target

[Service]
ExecStart=${FB_BIN} --database ${FB_DB}
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now filebrowser >/dev/null

    echo "admin:${fb_password}" > /root/.filebrowser-host.creds
    chmod 600 /root/.filebrowser-host.creds

    sleep 2
    if ! systemctl is-active --quiet filebrowser; then
        status_message "error" "Service failed to start. journalctl -u filebrowser"
    fi

    local ip
    ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo "================================================================"
    status_message "success" "FileBrowser installed."
    echo "================================================================"
    echo ""
    echo "  Login:        admin / ${fb_password}"
    echo "  Creds file:   /root/.filebrowser-host.creds"
    echo "  Root path:    ${FB_ROOT}"
    echo ""
    echo -e "  ${GREEN} Access:       http://${ip}:${FB_PORT}"
    echo ""
}

action_update() {
    [[ $INSTALLED -eq 0 ]] && status_message "error" "Not installed."
    status_message "info" "Updating FileBrowser..."
    systemctl stop filebrowser

    local fb_version
    fb_version=$(curl -fsSL https://api.github.com/repos/filebrowser/filebrowser/releases/latest | grep tag_name | cut -d'"' -f4)
    cd /tmp
    rm -f fb.tar.gz filebrowser
    curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/${fb_version}/linux-amd64-filebrowser.tar.gz" -o fb.tar.gz
    tar -xzf fb.tar.gz
    install -m 755 /tmp/filebrowser "$FB_BIN"
    rm -f /tmp/fb.tar.gz /tmp/filebrowser /tmp/LICENSE /tmp/README.md /tmp/CHANGELOG.md 2>/dev/null || true

    systemctl start filebrowser
    sleep 2
    if systemctl is-active --quiet filebrowser; then
        status_message "success" "Updated to $("$FB_BIN" version | head -1)"
    else
        status_message "error" "Service failed to restart."
    fi
}

action_uninstall_silent() {
    systemctl stop filebrowser 2>/dev/null || true
    systemctl disable filebrowser 2>/dev/null || true
    rm -f /etc/systemd/system/filebrowser.service
    rm -f "$FB_BIN"
    rm -rf /etc/filebrowser /srv/filebrowser
    rm -f /root/.filebrowser-host.creds
    systemctl daemon-reload
}

action_uninstall() {
    [[ $INSTALLED -eq 0 ]] && status_message "error" "Not installed."
    read -p "Type 'yes' to confirm full uninstall: " c </dev/tty
    [[ "$c" != "yes" ]] && { status_message "info" "Cancelled."; exit 0; }
    action_uninstall_silent
    status_message "success" "FileBrowser fully removed."
}

action_status() {
    [[ $INSTALLED -eq 0 ]] && { status_message "info" "Not installed."; return; }
    echo ""
    echo "Service:  $(systemctl is-active filebrowser)"
    echo "Version:  $("$FB_BIN" version 2>/dev/null | head -1)"
    local ip
    ip=$(hostname -I | awk '{print $1}')
    local port
    port=$("$FB_BIN" config cat --database "$FB_DB" 2>/dev/null | grep -oP 'port:\s*\K\d+' | head -1)
    echo "Access:   http://${ip}:${port:-?}"
}

echo ""
echo "================================================================"
echo "  FileBrowser Host Manager"
echo "================================================================"
echo ""
if [[ $INSTALLED -eq 1 ]]; then
    echo -e "  Status: ${GREEN} Installed"
else
    echo -e "  Status: ${YELLOW} Not installed"
fi
echo ""
echo "  1) Install / Reinstall"
echo "  2) Update"
echo "  3) Uninstall"
echo "  4) Status"
echo "  q) Quit"
echo ""
read -p "Select: " choice </dev/tty
echo ""

case "$choice" in
    1) action_install ;;
    2) action_update ;;
    3) action_uninstall ;;
    4) action_status ;;
    q|Q) exit 0 ;;
    *) status_message "error" "Invalid." ;;
esac