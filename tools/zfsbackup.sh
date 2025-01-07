#!/bin/bash

# Variables
ZFS_POOL="rpool"
SNAPSHOT_NAME="backup_snapshot_$(date +'%Y%m%d_%H%M%S')"  # Date format: year-month-day_hour-minute-second
BACKUP_DEST="/mnt/nvme0n1"
BACKUP_FILE="${BACKUP_DEST}/zfs_backup_${SNAPSHOT_NAME}.gz"
LOG_FILE="${BACKUP_DEST}/zfs_backup_log.txt"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Check if the backup destination is mounted
if ! mount | grep -q "$BACKUP_DEST"; then
    log_message "Error: Backup destination ($BACKUP_DEST) is not mounted."
    exit 1
fi

# Step 1: Create a ZFS snapshot
log_message "Creating snapshot ${SNAPSHOT_NAME} of ZFS pool ${ZFS_POOL}..."
if ! zfs snapshot "${ZFS_POOL}@${SNAPSHOT_NAME}"; then
    log_message "Error: Failed to create snapshot ${SNAPSHOT_NAME}."
    exit 1
fi
log_message "Snapshot ${SNAPSHOT_NAME} created successfully."

# Step 2: Send snapshot to the backup destination (4TB ext4 drive)
log_message "Backing up snapshot ${SNAPSHOT_NAME} to ${BACKUP_FILE}..."
if ! zfs send "${ZFS_POOL}@${SNAPSHOT_NAME}" | gzip > "$BACKUP_FILE"; then
    log_message "Error: Failed to back up snapshot ${SNAPSHOT_NAME}."
    exit 1
fi
log_message "Snapshot ${SNAPSHOT_NAME} backed up successfully to ${BACKUP_FILE}."

# Step 3: Clean up all snapshots
log_message "Cleaning up all ZFS snapshots..."
if zfs list -t snapshot | grep -q "${ZFS_POOL}@"; then
    zfs list -H -o name -t snapshot | grep "${ZFS_POOL}@" | while read snapshot; do
        log_message "Deleting snapshot $snapshot..."
        if ! zfs destroy "$snapshot"; then
            log_message "Error: Failed to delete snapshot $snapshot."
        else
            log_message "Snapshot $snapshot deleted successfully."
        fi
    done
else
    log_message "No snapshots found for cleanup."
fi

log_message "Backup process completed successfully."

exit 0
