#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/backup-winstorage.sh?$(date +%s))"
# purpose: backups storage folder in a docker container called windows

set -euo pipefail

SOURCE_DIR="/mnt/sec/apps/windows/storage/"
DEST_DIR="/mnt/sec/backup/docker/storage/"
REQUIRED_PKGS=("rsync" "findutils")

# Dependency check & install
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! command -v "${pkg%%-*}" >/dev/null 2>&1; then
        echo "Installing $pkg..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y "$pkg"
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y "$pkg"
        else
            echo "Package manager not found. Install $pkg manually."
            exit 1
        fi
    fi
done

# Cleanup old timestamped backups
find "$(dirname "${DEST_DIR%/}")" -maxdepth 1 -type d -name "$(basename "${DEST_DIR%/}")-*" -exec rm -rf {} + || true

# Ensure destination exists & sync
mkdir -p "$DEST_DIR"
rsync -a --delete --exclude='.sync' "$SOURCE_DIR" "$DEST_DIR"

echo "Backup refreshed: $(date)"

