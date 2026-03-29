#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-kasm.sh?$(date +%s))"
# Purpose: Install Kasm Workspaces
# Version: Ubuntu
# =============================================================================
# Usage:
#   - No existing install       -> fresh install
#   - Existing install found    -> upgrade (with database backup)
#   - Already on target version -> skip, nothing to do
#
# Defaults:
#   Password                                            (default: password)
#   KASM_VERSION        Target version                  (default: 1.18.1)
#   KASM_SWAP_GB        Swap size in GB                 (default: 4)
#   KASM_PORT           Web UI port                     (default: 443)
#   SKIP_QEMU_AGENT     Set "true" to skip              (default: false)
#   SKIP_PERSISTENT     Set "true" to skip dirs         (default: false)
# =============================================================================

set -euo pipefail

# Helpers
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

# Root check
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# Configuration
KASM_VERSION="${KASM_VERSION:-1.18.1}"
KASM_TARBALL="kasm_release_${KASM_VERSION}.tar.gz"
KASM_URL="https://kasm-static-content.s3.amazonaws.com/${KASM_TARBALL}"
KASM_SWAP_GB="${KASM_SWAP_GB:-4}"
KASM_PORT="${KASM_PORT:-443}"
SKIP_QEMU_AGENT="${SKIP_QEMU_AGENT:-false}"
SKIP_PERSISTENT="${SKIP_PERSISTENT:-false}"
DEFAULT_PASS="password"

# Auto-detect mode
MODE="install"
EXISTING_VERSION=""

if [[ -d /opt/kasm/current ]]; then
    EXISTING_VERSION=$(readlink -f /opt/kasm/current | grep -oP '\d+\.\d+\.\d+' || true)

    if [[ "$EXISTING_VERSION" == "$KASM_VERSION" ]]; then
        ok "Kasm ${KASM_VERSION} is already installed. Nothing to do."
        exit 0
    fi

    MODE="upgrade"
fi

echo ""
if [[ "$MODE" == "upgrade" ]]; then
    echo "Kasm Workspaces - Upgrade ${EXISTING_VERSION} -> ${KASM_VERSION}"
else
    echo "Kasm Workspaces ${KASM_VERSION} - Fresh Install"
fi
echo "================================================="
echo ""

# System update
info "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
ok "System packages updated."

# Prerequisites
info "Installing prerequisites..."
apt-get install -y -qq curl wget apt-transport-https ca-certificates > /dev/null 2>&1
ok "Prerequisites installed."

# QEMU Guest Agent (install only)
if [[ "$MODE" == "install" && "${SKIP_QEMU_AGENT}" != "true" ]]; then
    info "Installing QEMU guest agent..."
    apt-get install -y -qq qemu-guest-agent > /dev/null 2>&1
    systemctl enable --now qemu-guest-agent 2>/dev/null || true
    ok "QEMU guest agent active."
elif [[ "${SKIP_QEMU_AGENT}" == "true" ]]; then
    warn "Skipping QEMU guest agent."
fi

# Swap (install only)
if [[ "$MODE" == "install" ]]; then
    SWAP_FILE="/mnt/${KASM_SWAP_GB}GiB.swap"
    if [[ ! -f "${SWAP_FILE}" ]]; then
        info "Creating ${KASM_SWAP_GB} GB swap file..."
        fallocate -l "${KASM_SWAP_GB}g" "${SWAP_FILE}"
        chmod 600 "${SWAP_FILE}"
        mkswap "${SWAP_FILE}"
        swapon "${SWAP_FILE}"
        grep -q "${SWAP_FILE}" /etc/fstab || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
        ok "Swap configured (${KASM_SWAP_GB} GB, persistent)."
    else
        warn "Swap file already exists at ${SWAP_FILE} - skipping."
    fi
fi

# Download
info "Downloading Kasm Workspaces v${KASM_VERSION}..."
cd /tmp
if [[ -f "${KASM_TARBALL}" ]]; then
    warn "Tarball already present in /tmp - reusing."
else
    curl -fSL -O "${KASM_URL}" || fail "Download failed. Check KASM_VERSION or network connectivity."
fi
ok "Download complete."

# Extract
info "Extracting..."
tar -xf "${KASM_TARBALL}"
ok "Extracted."

# Install or Upgrade
if [[ "$MODE" == "upgrade" ]]; then

    info "Backing up database before upgrade..."
    mkdir -p /opt/kasm/backups
    chown -R 70:70 /opt/kasm/backups

    BACKUP_FILE="/opt/kasm/backups/kasm_db_backup_pre_${KASM_VERSION}.tar"
    bash /opt/kasm/current/bin/utils/db_backup -f "${BACKUP_FILE}" -p /opt/kasm/current/ \
        && ok "Database backed up to ${BACKUP_FILE}." \
        || warn "Database backup failed. Consider a VM snapshot as fallback."

    info "Running upgrade (this may take several minutes)..."
    echo ""
    bash kasm_release/upgrade.sh -L "${KASM_PORT}" || fail "Upgrade failed. Check /tmp for kasm_upgrade_*.log."
    echo ""
    ok "Upgraded from ${EXISTING_VERSION} to ${KASM_VERSION}."

else

    info "Running installer (this may take several minutes)..."
    echo ""
    bash kasm_release/install.sh \
        -L "${KASM_PORT}" \
        -e \
        --admin-password "${DEFAULT_PASS}" \
        --user-password "${DEFAULT_PASS}" \
        || fail "Installer failed."
    echo ""
    ok "Kasm Workspaces ${KASM_VERSION} installed."
fi

# Docker group
# Kasm's installer sets up Docker. Add the invoking user to the docker group
# so they can run docker commands without sudo.
if [[ "$MODE" == "install" ]]; then
    REAL_USER="${SUDO_USER:-root}"
    if getent group docker > /dev/null 2>&1; then
        usermod -aG docker "${REAL_USER}" 2>/dev/null || true
        ok "User '${REAL_USER}' added to docker group (log out and back in to take effect)."
    fi
fi

# Persistent storage
if [[ "${SKIP_PERSISTENT}" != "true" ]]; then
    info "Ensuring persistent storage directories exist..."
    mkdir -p /data/kasm-profiles
    chown -R 1000:1000 /data/kasm-profiles
    mkdir -p /data/kasm-shared
    chown -R 1000:1000 /data/kasm-shared
    ok "Persistent storage ready."
fi

# Cleanup
info "Cleaning up /tmp..."
rm -rf /tmp/kasm_release /tmp/"${KASM_TARBALL}"
ok "Cleanup done."

# Summary
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
if [[ "$MODE" == "upgrade" ]]; then
    echo "Upgrade Complete"
    echo "================================================="
    echo ""
    echo "  ${EXISTING_VERSION} -> ${KASM_VERSION}"
    echo "  Web UI        https://${SERVER_IP}:${KASM_PORT}"
    echo "  Backup        ${BACKUP_FILE}"
    echo ""
    echo "  Log in with your existing credentials."
    echo "  Check the Workspace Registry for updated images."
else
    echo "Install Complete"
    echo "================================================="
    echo ""
    echo "  Web UI        https://${SERVER_IP}:${KASM_PORT}"
    echo ""
    echo "  Admin login   admin@kasm.local"
    echo "  User login    user@kasm.local"
    echo "  Password      ${DEFAULT_PASS}"
fi

echo ""
echo "  A self-signed certificate warning is expected."
echo ""
echo ""
echo "Getting Started"
echo "================================================="
echo ""
echo "  1. Open https://${SERVER_IP}:${KASM_PORT} in your browser."
echo "     Accept the self-signed certificate warning."
echo ""
echo "  2. Log in as admin@kasm.local with password: ${DEFAULT_PASS}"
echo ""
echo "  3. CHANGE BOTH PASSWORDS IMMEDIATELY."
echo "     Admin > Users > select user > edit > update password."
echo ""
echo ""
echo "Persistent Profiles Setup Guide"
echo "================================================="
echo ""
echo "  Kasm does not persist user data between sessions by default."
echo "  To enable it, configure each workspace in the Admin UI:"
echo ""
echo "    1. Go to Admin > Workspaces > edit the workspace image."
echo "    2. Under 'Persistent Profile Path', enter:"
echo "       /data/kasm-profiles/<workspace-name>/{user_id}"
echo ""
echo "       Examples:"
echo "       /data/kasm-profiles/brave/{user_id}"
echo "       /data/kasm-profiles/desktop/{user_id}"
echo ""
echo "       Use any name that identifies the workspace. Kasm creates"
echo "       the subdirectories automatically on first session launch."
echo ""
echo "    3. Under 'Docker Run Config Override', add a shared volume:"
echo '       {'
echo '         "/data/kasm-shared": {'
echo '           "bind": "/home/kasm-user/shared",'
echo '           "mode": "rw",'
echo '           "uid": 1000,'
echo '           "gid": 1000'
echo '         }'
echo '       }'
echo ""
echo "       This mounts /data/kasm-shared on the host to"
echo "       /home/kasm-user/shared inside every workspace,"
echo "       giving users a common folder to share files across"
echo "       different workspace types."
echo ""
echo "  Storage locations:"
echo "    Profiles    /data/kasm-profiles/"
echo "    Shared      /data/kasm-shared/"
echo ""