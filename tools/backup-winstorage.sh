#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/backup-winstorage.sh?$(date +%s))"
# purpose: this script backups storage folder in a docker container called windows
# interactive: no

# Source and destination directories
SOURCE_DIR="/mnt/sec/apps/windows/storage/"
DEST_DIR="/mnt/sec/backup/docker/storage/"

# Check if the destination folder exists
if [ -d "$DEST_DIR" ]; then
    # Get the current date and time, formatted as yyyymmdd-hhmm
    CURRENT_TIME=$(date +"%Y%m%d-%H%M")

    # Rename the existing folder by appending the current timestamp
    mv "$DEST_DIR" "${DEST_DIR%/}-$CURRENT_TIME"
    echo "Renamed existing folder to ${DEST_DIR%/}-$CURRENT_TIME"
fi

# Create the destination directory again (if it doesn't exist)
mkdir -p "$DEST_DIR" || { echo "Failed to create destination directory $DEST_DIR"; exit 1; }

# Copy the source folder to the destination, overwriting the new empty folder
rsync -av --delete --exclude='.sync' "$SOURCE_DIR" "$DEST_DIR" || { echo "rsync failed"; exit 1; }
