#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/backup-winstorage.sh?$(date +%s))"
# purpose: backups storage folder in a docker container called windows

set -euo pipefail

# === Colors & status ===
GREEN="\e[32m✔\e[0m"; RED="\e[31m✘\e[0m"
status_message(){ [[ $1 == success ]] && echo -e "${GREEN} $2" || { echo -e "${RED} $2"; exit 1; }; }

# === Config ===
SOURCE_DIR="/mnt/sec/apps/windows/storage/"
DEST_DIR="/mnt/sec/backup/docker/storage/"

# === Dependency: rsync only ===
if ! command -v rsync >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync
  elif command -v yum >/dev/null 2>&1; then
    sudo yum -q -y install rsync
  else
    status_message fail "No supported package manager for rsync"
  fi
  status_message success "rsync installed"
else
  status_message success "rsync already installed"
fi

# === Cleanup old timestamped backups ===
dest_parent="$(dirname "${DEST_DIR%/}")"
dest_base="$(basename "${DEST_DIR%/}")"
shopt -s nullglob
old_dirs=("$dest_parent/${dest_base}-"*)
shopt -u nullglob
if (( ${#old_dirs[@]} )); then
  rm -rf -- "${old_dirs[@]}"
  status_message success "Old timestamped backups removed"
else
  status_message success "No old timestamped backups found"
fi

# === Ensure destination exists ===
mkdir -p "$DEST_DIR" && status_message success "Destination folder ready"

# === Backup with progress ===
echo "Starting backup with progress..."
rsync -a --delete --exclude='.sync' --info=progress2 "$SOURCE_DIR" "$DEST_DIR"
status_message success "Backup refreshed: $(date)"

