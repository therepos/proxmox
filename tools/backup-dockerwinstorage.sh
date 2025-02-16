#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/backup-dockerwinstorage.sh)"

# Source and destination directories
SOURCE_DIR="/mnt/sec/apps/windows/storage/"
DEST_DIR="/mnt/sec/backup/docker/storage/"

# Check if the destination folder exists
if [ -d "$DEST_DIR" ]; then
    # Get the creation time of the destination folder and format it as yyyymmdd-hhmm
    CREATION_TIME=$(stat -c %y "$DEST_DIR" | cut -d' ' -f1 | sed 's/-//g')"-"$(stat -c %y "$DEST_DIR" | cut -d' ' -f2 | sed 's/://g' | cut -d'.' -f1)

    # Rename the existing folder to include the timestamp
    mv "$DEST_DIR" "${DEST_DIR}-${CREATION_TIME}"
    echo "Renamed existing folder to ${DEST_DIR}-${CREATION_TIME}"
fi

# Create the destination directory again (if it doesn't exist)
mkdir -p "$DEST_DIR"

# Copy the source folder to the destination, overwriting the new empty folder
rsync -av --delete --exclude='.sync' "$SOURCE_DIR" "$DEST_DIR"

