#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/dufs-setup.sh?$(date +%s))"
# Purpose: Install / Update / Change creds / Uninstall Dufs on Proxmox host
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

# Back-compat wrapper used within this script:
status_message() {
    case "$1" in
        success) ok "$2" ;;
        info)    info "$2" ;;
        *)       fail "$2" ;;   # error → print + exit
    esac
}

DUFS_BIN="/usr/local/bin/dufs"
DUFS_DEFAULT_PORT=3001
DUFS_DEFAULT_ROOT="/"

[[ $EUID -eq 0 ]] || status_message "error" "Run as root."

INSTALLED=0
[[ -x "$DUFS_BIN" ]] && INSTALLED=1

action_install() {
    if [[ $INSTALLED -eq 1 ]]; then
        echo "Dufs already installed."
        read -p "Reinstall? [y/N]: " r </dev/tty
        [[ ! "$r" =~ ^[Yy]$ ]] && exit 0
        action_uninstall_silent
    fi

    read -p "Root path Dufs will serve (default ${DUFS_DEFAULT_ROOT}): " root_input </dev/tty
    local dufs_root="${root_input:-$DUFS_DEFAULT_ROOT}"
    if [[ ! -d "$dufs_root" ]]; then
        status_message "error" "Path '$dufs_root' does not exist."
    fi

    read -p "Port (default ${DUFS_DEFAULT_PORT}): " port_input </dev/tty
    local dufs_port="${port_input:-$DUFS_DEFAULT_PORT}"
    if [[ ! "$dufs_port" =~ ^[0-9]+$ ]] || [[ "$dufs_port" -lt 1024 || "$dufs_port" -gt 65535 ]]; then
        status_message "error" "Invalid port."
    fi

    local dufs_password
    dufs_password=$(openssl rand -base64 12 | tr -d '=+/')

    status_message "info" "Installing Dufs..."
    apt update -qq >/dev/null
    apt install -y -qq curl tar ca-certificates >/dev/null

    local dufs_version
    dufs_version=$(curl -fsSL https://api.github.com/repos/sigoden/dufs/releases/latest | grep tag_name | cut -d'"' -f4)
    [[ -z "$dufs_version" ]] && status_message "error" "Could not fetch Dufs version."
    echo "[*] Latest version: $dufs_version"

    cd /tmp
    rm -f dufs.tar.gz dufs
    local arch_tag="x86_64-unknown-linux-musl"
    echo "[*] Downloading binary..."
    curl -fsSL "https://github.com/sigoden/dufs/releases/download/${dufs_version}/dufs-${dufs_version}-${arch_tag}.tar.gz" -o dufs.tar.gz
    [[ ! -s dufs.tar.gz ]] && status_message "error" "Download failed."

    tar -xzf dufs.tar.gz
    [[ ! -f /tmp/dufs ]] && status_message "error" "Binary not in archive."

    echo "[*] Installing to ${DUFS_BIN}..."
    install -m 755 /tmp/dufs "$DUFS_BIN"
    rm -f /tmp/dufs.tar.gz /tmp/dufs /tmp/LICENSE /tmp/README.md 2>/dev/null || true

    [[ ! -x "$DUFS_BIN" ]] && status_message "error" "Install failed."

    echo "[*] Setting up systemd service..."
    cat > /etc/systemd/system/dufs.service <<EOF
[Unit]
Description=Dufs File Server
After=network.target

[Service]
ExecStart=${DUFS_BIN} ${dufs_root} --bind 0.0.0.0 --port ${dufs_port} --auth admin:${dufs_password}@/:rw --allow-all
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now dufs >/dev/null

    echo "admin:${dufs_password}" > /root/.dufs-host.creds
    chmod 600 /root/.dufs-host.creds

    sleep 2
    if ! systemctl is-active --quiet dufs; then
        echo ""
        journalctl -u dufs --no-pager -n 20
        status_message "error" "Service failed to start."
    fi

    local ip
    ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo "================================================================"
    status_message "success" "Setup complete."
    echo "================================================================"
    echo ""
    echo "  Login:        admin / ${dufs_password}"
    echo "  Creds file:   /root/.dufs-host.creds"
    echo "  Root path:    ${dufs_root}"
    echo ""
    echo "  Access:       http://${ip}:${dufs_port}"
    echo ""
}

action_update() {
    [[ $INSTALLED -eq 0 ]] && status_message "error" "Not installed."
    status_message "info" "Updating Dufs..."
    systemctl stop dufs

    local dufs_version
    dufs_version=$(curl -fsSL https://api.github.com/repos/sigoden/dufs/releases/latest | grep tag_name | cut -d'"' -f4)
    [[ -z "$dufs_version" ]] && status_message "error" "Could not fetch version."

    cd /tmp
    rm -f dufs.tar.gz dufs
    local arch_tag="x86_64-unknown-linux-musl"
    curl -fsSL "https://github.com/sigoden/dufs/releases/download/${dufs_version}/dufs-${dufs_version}-${arch_tag}.tar.gz" -o dufs.tar.gz
    [[ ! -s dufs.tar.gz ]] && status_message "error" "Download failed."
    tar -xzf dufs.tar.gz
    install -m 755 /tmp/dufs "$DUFS_BIN"
    rm -f /tmp/dufs.tar.gz /tmp/dufs /tmp/LICENSE /tmp/README.md 2>/dev/null || true

    systemctl start dufs
    sleep 2
    if systemctl is-active --quiet dufs; then
        status_message "success" "Updated to $("$DUFS_BIN" --version | head -1)"
    else
        status_message "error" "Service failed to restart."
    fi
}

action_change_creds() {
    [[ $INSTALLED -eq 0 ]] && status_message "error" "Not installed."

    local current_user
    current_user=$(grep -oP 'auth \K[^:]+' /etc/systemd/system/dufs.service)
    echo "Current user: $current_user"
    echo ""

    read -p "New username (blank to keep '${current_user}'): " new_user </dev/tty
    new_user="${new_user:-$current_user}"

    read -rsp "New password (blank to auto-generate, hidden): " new_pass </dev/tty
    echo ""
    if [[ -z "$new_pass" ]]; then
        new_pass=$(openssl rand -base64 12 | tr -d '=+/')
        echo "Auto-generated password: $new_pass"
    fi

    sed -i -E "s|--auth [^@]+@|--auth ${new_user}:${new_pass}@|" /etc/systemd/system/dufs.service
    echo "${new_user}:${new_pass}" > /root/.dufs-host.creds
    chmod 600 /root/.dufs-host.creds

    systemctl daemon-reload
    systemctl restart dufs
    sleep 2

    if systemctl is-active --quiet dufs; then
        status_message "success" "Credentials updated and service restarted"
        echo ""
        echo "  Login: ${new_user} / ${new_pass}"
    else
        echo ""
        journalctl -u dufs --no-pager -n 10
        status_message "error" "Service failed to restart."
    fi
}

action_uninstall_silent() {
    systemctl stop dufs 2>/dev/null || true
    systemctl disable dufs 2>/dev/null || true
    rm -f /etc/systemd/system/dufs.service
    rm -f "$DUFS_BIN"
    rm -f /root/.dufs-host.creds
    systemctl daemon-reload
}

action_uninstall() {
    [[ $INSTALLED -eq 0 ]] && status_message "error" "Not installed."
    read -p "Type 'yes' to confirm full uninstall: " c </dev/tty
    [[ "$c" != "yes" ]] && { status_message "info" "Cancelled."; exit 0; }
    action_uninstall_silent
    status_message "success" "Dufs fully removed."
}

action_status() {
    [[ $INSTALLED -eq 0 ]] && { status_message "info" "Not installed."; return; }
    echo ""
    echo "Service:  $(systemctl is-active dufs)"
    echo "Version:  $("$DUFS_BIN" --version 2>/dev/null | head -1)"
    local port
    port=$(grep -oP 'port \K\d+' /etc/systemd/system/dufs.service 2>/dev/null | head -1)
    local user
    user=$(grep -oP 'auth \K[^:]+' /etc/systemd/system/dufs.service 2>/dev/null | head -1)
    local ip
    ip=$(hostname -I | awk '{print $1}')
    echo "User:     ${user:-?}"
    echo "Access:   http://${ip}:${port:-?}"
    echo ""
    echo "Recent logs:"
    journalctl -u dufs --no-pager -n 5
}

echo ""
echo "================================================================"
echo "  Dufs Host Manager"
echo "================================================================"
echo ""
if [[ $INSTALLED -eq 1 ]]; then
    ok "Installed"
else
    info "Not installed"
fi
echo ""
echo "  1) Install / Reinstall"
echo "  2) Update"
echo "  3) Change credentials"
echo "  4) Uninstall"
echo "  5) Status"
echo "  q) Quit"
echo ""
read -p "Select: " choice </dev/tty
echo ""

case "$choice" in
    1) action_install ;;
    2) action_update ;;
    3) action_change_creds ;;
    4) action_uninstall ;;
    5) action_status ;;
    q|Q) exit 0 ;;
    *) status_message "error" "Invalid." ;;
esac
