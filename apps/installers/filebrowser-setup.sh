#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/filebrowser-setup.sh?$(date +%s))"
# Purpose: Installs FileBrowser via official binary (Ubuntu/PVE9)
# =============================================================================
# Usage:
#   Username: admin
#   Password: password@12345  (change after first login)
# =============================================================================

set -euo pipefail

# --- Variables ---------------------------------------------------------------
PORT="3001"
FB_ADDRESS="0.0.0.0"
FB_ROOT="/"
FB_CONFIG_DIR="/etc/filebrowser"
FB_DB="${FB_CONFIG_DIR}/fb.db"
FB_USER="admin"
FB_PASS="password@12345"
FB_BIN="/usr/local/bin/filebrowser"
SERVICE_FILE="/etc/systemd/system/filebrowser.service"
INSTALL_URL="https://raw.githubusercontent.com/filebrowser/get/master/get.sh"

# --- Helpers -----------------------------------------------------------------
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"

status_message() {
    local status=$1 message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# --- Uninstall ---------------------------------------------------------------
uninstall_filebrowser() {
    echo "Uninstalling FileBrowser..."
    systemctl stop filebrowser 2>/dev/null || true
    systemctl disable filebrowser 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "$FB_BIN"
    rm -rf "$FB_CONFIG_DIR"
    systemctl daemon-reload
    status_message "success" "FileBrowser has been uninstalled."
}

# --- Precheck ----------------------------------------------------------------
if command -v filebrowser &> /dev/null; then
    echo "FileBrowser is already installed."
    read -p "Do you want to uninstall it? [y/N]: " uninstall_response
    if [[ "$uninstall_response" =~ ^[Yy]$ ]]; then
        uninstall_filebrowser
    else
        status_message "success" "Existing FileBrowser installation retained."
    fi
    exit 0
fi

# --- Install binary ----------------------------------------------------------
curl -fsSL "$INSTALL_URL" | bash >/dev/null
if ! command -v filebrowser &> /dev/null; then
    status_message "error" "FileBrowser binary not found after install. Check network or install URL."
fi
status_message "success" "FileBrowser binary installed."

# --- Configure ---------------------------------------------------------------
mkdir -p "$FB_CONFIG_DIR"

filebrowser config init -d "$FB_DB" >/dev/null
filebrowser config set -d "$FB_DB" -a "$FB_ADDRESS" -p "$PORT" -r "$FB_ROOT" >/dev/null
status_message "success" "Configuration applied (${FB_ADDRESS}:${PORT}, root: ${FB_ROOT})."

filebrowser users add "$FB_USER" "$FB_PASS" --perm.admin -d "$FB_DB" >/dev/null
status_message "success" "Admin user created."

# --- systemd service ---------------------------------------------------------
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=FileBrowser
After=network.target

[Service]
ExecStart=${FB_BIN} -d ${FB_DB}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now filebrowser >/dev/null 2>&1

if systemctl is-active --quiet filebrowser; then
    status_message "success" "FileBrowser running at http://$(hostname -I | awk '{print $1}'):${PORT}"
else
    status_message "error" "FileBrowser service failed to start. Check: journalctl -u filebrowser"
fi