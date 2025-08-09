#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/backup-winstorage.sh?$(date +%s))"
# purpose: backups storage folder in a docker container called windows

set -euo pipefail

# === Colors & status symbols ===
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# === Config ===
SOURCE_DIR="/mnt/sec/apps/windows/storage/"
DEST_DIR="/mnt/sec/backup/docker/storage/"
REQUIRED_PKGS=("rsync" "findutils")

# === Dependency check & install ===
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v "${pkg%%-*}" >/dev/null 2>&1; then
        echo "Installing $pkg..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y "$pkg" && status_message success "$pkg installed"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "$pkg" && status_message success "$pkg installed"
        else
            status_message fail "Package manager not found. Install $pkg manually."
        fi
    else
        status_message success "$pkg already installed"
    fi
done

# === Cleanup old timestamped backups ===
find "$(dirname "${DEST_DIR%/}")" -maxdepth 1 -type d -name "$(basename "${DEST_DIR%/}")-*" -exec rm -rf {} + && \
status_message success "Old timestamped backups removed"

# === Ensure destination exists ===
mkdir -p "$DEST_DIR" && status_message success "Destination folder ready"

# === Backup with progress ===
echo "Starting backup with progress..."
rsync -a --delete --exclude='.sync' --info=progress2 "$SOURCE_DIR" "$DEST_DIR"
status_message success "Backup refreshed: $(date)"

