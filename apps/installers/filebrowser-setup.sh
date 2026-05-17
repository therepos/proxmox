#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/filebrowser-setup.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall FileBrowser LXC on Proxmox
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
HOSTNAME="filebrowser"
CTID_DEFAULT=120
MEMORY=512
CORES=1
DISK=4
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"
FB_PORT=8080
FB_BIN="/usr/local/bin/filebrowser"

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

install_filebrowser_inside_lxc() {
    local ctid=$1
    local fb_password=$2

    pct exec "$ctid" -- bash <<EOSCRIPT
set -euo pipefail
export LC_ALL=C
export LANG=C
export PATH=/usr/local/bin:/usr/local/sbin:\$PATH
echo 'LC_ALL=C' > /etc/default/locale

echo '[*] Installing prerequisites...'
apt update -qq >/dev/null 2>&1
apt install -y -qq curl tar ca-certificates >/dev/null 2>&1

echo '[*] Fetching latest FileBrowser version...'
FB_VERSION=\$(curl -fsSL https://api.github.com/repos/filebrowser/filebrowser/releases/latest | grep tag_name | cut -d'"' -f4)
if [[ -z "\$FB_VERSION" ]]; then
    echo 'FATAL: could not fetch FileBrowser version from GitHub API' >&2
    exit 1
fi
echo "[*] Latest version: \$FB_VERSION"

echo '[*] Downloading binary...'
cd /tmp
rm -f fb.tar.gz filebrowser
curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/\${FB_VERSION}/linux-amd64-filebrowser.tar.gz" -o fb.tar.gz
if [[ ! -s fb.tar.gz ]]; then
    echo 'FATAL: download produced empty file' >&2
    exit 1
fi

echo '[*] Extracting...'
tar -xzf fb.tar.gz
if [[ ! -f /tmp/filebrowser ]]; then
    echo 'FATAL: filebrowser binary not found in archive' >&2
    exit 1
fi

echo '[*] Installing to ${FB_BIN}...'
install -m 755 /tmp/filebrowser ${FB_BIN}
rm -f /tmp/fb.tar.gz /tmp/filebrowser /tmp/LICENSE /tmp/README.md /tmp/CHANGELOG.md 2>/dev/null || true

if [[ ! -x ${FB_BIN} ]]; then
    echo 'FATAL: ${FB_BIN} not found or not executable after install' >&2
    exit 1
fi
echo "[*] Installed: \$(${FB_BIN} version | head -1)"

echo '[*] Initializing config...'
mkdir -p /etc/filebrowser /srv/filebrowser
${FB_BIN} config init --database /etc/filebrowser/filebrowser.db >/dev/null
${FB_BIN} config set --address 0.0.0.0 --port ${FB_PORT} --root / --database /etc/filebrowser/filebrowser.db >/dev/null
${FB_BIN} users add admin '${fb_password}' --perm.admin --database /etc/filebrowser/filebrowser.db >/dev/null

echo '[*] Setting up systemd service...'
cat > /etc/systemd/system/filebrowser.service <<'UNIT'
[Unit]
Description=FileBrowser
After=network.target

[Service]
ExecStart=${FB_BIN} --database /etc/filebrowser/filebrowser.db
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now filebrowser >/dev/null 2>&1
echo '[*] Done.'
EOSCRIPT
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

    echo ""
    echo "Bind mount host paths into the LXC? (comma-separated, blank for none)"
    echo "Examples: /mnt/data, /var/lib/vz, /"
    echo ""
    read -p "Paths: " bind_input </dev/tty
    echo ""

    local ctid=$CTID_DEFAULT
    while pct status "$ctid" &>/dev/null; do
        ctid=$((ctid + 1))
    done
    status_message "info" "Using CTID $ctid"

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
    local fb_password
    fb_password=$(openssl rand -base64 12)

    status_message "info" "Creating LXC..."
    pct create "$ctid" "${TEMPLATE_STORAGE}:vztmpl/${template}" \
        --hostname "$HOSTNAME" \
        --cores "$CORES" --memory "$MEMORY" --swap "$MEMORY" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
        --rootfs "${STORAGE}:${DISK}" \
        --unprivileged 0 --features nesting=1 --onboot 1 \
        --password "$lxc_password" >/dev/null

    echo "$lxc_password" > "/root/.filebrowser-lxc-${ctid}.pw"
    chmod 600 "/root/.filebrowser-lxc-${ctid}.pw"

    if [[ -n "$bind_input" ]]; then
        local mp_idx=0
        IFS=',' read -ra paths <<< "$bind_input"
        for raw_path in "${paths[@]}"; do
            local path
            path=$(echo "$raw_path" | xargs)
            if [[ -z "$path" || ! -e "$path" ]]; then
                status_message "info" "Skipping invalid path: $path"
                continue
            fi
            local mount_name
            mount_name=$(basename "$path")
            [[ "$path" == "/" ]] && mount_name="host"
            pct set "$ctid" -mp${mp_idx} "${path},mp=/mnt/${mount_name}"
            status_message "info" "Bind mount: $path → /mnt/${mount_name}"
            mp_idx=$((mp_idx + 1))
        done
    fi

    pct start "$ctid"
    sleep 5

    status_message "info" "Installing FileBrowser inside LXC..."
    if ! install_filebrowser_inside_lxc "$ctid" "$fb_password"; then
        status_message "error" "FileBrowser install failed inside LXC. See output above for FATAL line."
    fi

    echo "admin:${fb_password}" > "/root/.filebrowser-lxc-${ctid}.creds"
    chmod 600 "/root/.filebrowser-lxc-${ctid}.creds"

    sleep 3
    local lxc_ip
    lxc_ip=$(pct exec "$ctid" -- hostname -I | awk '{print $1}')

    if ! pct exec "$ctid" -- systemctl is-active --quiet filebrowser; then
        status_message "error" "FileBrowser service is not active. Check: pct exec $ctid -- journalctl -u filebrowser"
    fi

    echo ""
    status_message "success" "FileBrowser running at http://${lxc_ip}:${FB_PORT}"
    echo ""
    echo "  Login:        admin / ${fb_password}"
    echo "  Creds file:   /root/.filebrowser-lxc-${ctid}.creds"
    echo "  LXC root pw:  /root/.filebrowser-lxc-${ctid}.pw"
    echo ""
    [[ -n "$bind_input" ]] && echo "  Host paths visible under /mnt/ inside FileBrowser"
}

action_update() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "error" "No FileBrowser LXC installed."
    fi
    status_message "info" "Updating FileBrowser in CTID $EXISTING_CTID..."
    pct exec "$EXISTING_CTID" -- bash <<EOSCRIPT
set -euo pipefail
export LC_ALL=C
export PATH=/usr/local/bin:/usr/local/sbin:\$PATH

systemctl stop filebrowser

FB_VERSION=\$(curl -fsSL https://api.github.com/repos/filebrowser/filebrowser/releases/latest | grep tag_name | cut -d'"' -f4)
if [[ -z "\$FB_VERSION" ]]; then
    echo 'FATAL: could not fetch FileBrowser version' >&2
    exit 1
fi

cd /tmp
rm -f fb.tar.gz filebrowser
curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/\${FB_VERSION}/linux-amd64-filebrowser.tar.gz" -o fb.tar.gz
if [[ ! -s fb.tar.gz ]]; then
    echo 'FATAL: download produced empty file' >&2
    exit 1
fi
tar -xzf fb.tar.gz
if [[ ! -f /tmp/filebrowser ]]; then
    echo 'FATAL: binary not in archive' >&2
    exit 1
fi
install -m 755 /tmp/filebrowser ${FB_BIN}
rm -f /tmp/fb.tar.gz /tmp/filebrowser /tmp/LICENSE /tmp/README.md /tmp/CHANGELOG.md 2>/dev/null || true

systemctl start filebrowser
EOSCRIPT

    sleep 2
    if pct exec "$EXISTING_CTID" -- systemctl is-active --quiet filebrowser; then
        local version
        version=$(pct exec "$EXISTING_CTID" -- ${FB_BIN} version 2>/dev/null | head -1)
        status_message "success" "Updated. $version"
    else
        status_message "error" "Service failed to restart after update."
    fi
}

action_uninstall_silent() {
    if [[ -n "$EXISTING_CTID" ]]; then
        pct stop "$EXISTING_CTID" 2>/dev/null || true
        pct destroy "$EXISTING_CTID" --purge 2>/dev/null
        rm -f "/root/.filebrowser-lxc-${EXISTING_CTID}.pw"
        rm -f "/root/.filebrowser-lxc-${EXISTING_CTID}.creds"
    fi
}

action_uninstall() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "error" "No FileBrowser LXC installed."
    fi
    echo "This will permanently destroy LXC $EXISTING_CTID and remove FileBrowser data."
    read -p "Type 'yes' to confirm: " confirm </dev/tty
    if [[ "$confirm" != "yes" ]]; then
        status_message "info" "Cancelled."
        exit 0
    fi
    status_message "info" "Destroying LXC $EXISTING_CTID..."
    action_uninstall_silent
    status_message "success" "FileBrowser LXC removed."
}

action_status() {
    if [[ -z "$EXISTING_CTID" ]]; then
        status_message "info" "FileBrowser LXC: not installed"
        return
    fi
    echo ""
    echo "LXC $EXISTING_CTID status:"
    pct status "$EXISTING_CTID"
    echo ""
    echo "FileBrowser service:"
    pct exec "$EXISTING_CTID" -- systemctl is-active filebrowser 2>/dev/null || echo "  (not running)"
    echo ""
    echo "Version:"
    pct exec "$EXISTING_CTID" -- ${FB_BIN} version 2>/dev/null | head -1 || true
    echo ""
    local lxc_ip
    lxc_ip=$(pct exec "$EXISTING_CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$lxc_ip" ]] && echo "Access: http://${lxc_ip}:${FB_PORT}"
    echo ""
    echo "Bind mounts:"
    pct config "$EXISTING_CTID" | grep -E "^mp[0-9]+:" || echo "  (none)"
}

# ===== Menu =====

echo ""
echo "================================================================"
echo "  FileBrowser LXC Manager"
echo "================================================================"
echo ""
if [[ -n "$EXISTING_CTID" ]]; then
    echo -e "  Status: ${GREEN} Installed (CTID $EXISTING_CTID)"
else
    echo -e "  Status: ${YELLOW} Not installed"
fi
echo ""
echo "  1) Install / Reinstall"
echo "  2) Update FileBrowser"
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