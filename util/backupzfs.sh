#!/bin/bash

# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/util/backupzfs.sh)"

# Variables
ZFS_POOL="rpool"
SNAPSHOT_NAME="backup_snapshot_$(date +%Y%m%d%H%M)"
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

# Step 3: Optional - Clean up old snapshots (older than 7 days)
log_message "Cleaning up snapshots older than 7 days..."
if ! zfs list -t snapshot | grep -q "${ZFS_POOL}"; then
    log_message "Error: No snapshots found for cleanup."
else
    zfs list -H -o name -t snapshot | grep "${ZFS_POOL}@" | while read snapshot; do
        # Delete snapshots older than 7 days
        snapshot_date=$(echo "$snapshot" | sed 's/.*@\(.*\)/\1/')
        snapshot_timestamp=$(date -d "$snapshot_date" +%s)
        current_timestamp=$(date +%s)
        age=$(( (current_timestamp - snapshot_timestamp) / 86400 )) # age in days

        if [ "$age" -gt 7 ]; then
            log_message "Deleting snapshot $snapshot as it is older than 7 days."
            zfs destroy "$snapshot"
        fi
    done
fi

# Step 4: Clean up the snapshot created for backup
log_message "Destroying the backup snapshot ${SNAPSHOT_NAME}..."
if ! zfs destroy "${ZFS_POOL}@${SNAPSHOT_NAME}"; then
    log_message "Error: Failed to destroy snapshot ${SNAPSHOT_NAME}."
    exit 1
fi
log_message "Backup snapshot ${SNAPSHOT_NAME} destroyed successfully."

log_message "Backup process completed successfully."

exit 0
