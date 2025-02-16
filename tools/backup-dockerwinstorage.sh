#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/backup-dockerwinstorage.sh)"

# Source and destination directories
SOURCE_DIR="/mnt/sec/apps/windows/storage/"
DEST_DIR="/mnt/sec/backup/docker/storage/"

# Overwrite the destination folder
rsync -av --delete --exclude='.sync' "$SOURCE_DIR" "$DEST_DIR"
