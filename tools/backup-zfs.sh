#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/backup-zfs.sh)"
# purpose: this script backups or restores zfs drive

# Variables
ZFS_POOL="rpool"
BACKUP_DEST="/mnt/sec/backup"
LOG_FILE="${BACKUP_DEST}/zfs_backup_log.txt"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to perform ZFS backup
zfs_backup() {
    SNAPSHOT_NAME="backup_snapshot_$(date +'%Y%m%d_%H%M%S')"  # Date format: year-month-day_hour-minute-second
    BACKUP_FILE="${BACKUP_DEST}/zfs_backup_${SNAPSHOT_NAME}.gz"

    # Check if the backup destination exists and is mounted
    if [ ! -d "$BACKUP_DEST" ]; then
        log_message "Error: Backup destination ($BACKUP_DEST) does not exist."
        echo "Backup destination ($BACKUP_DEST) does not exist."
        exit 1
    fi

    # Step 1: Create a ZFS snapshot
    log_message "Creating snapshot ${SNAPSHOT_NAME} of ZFS pool ${ZFS_POOL}..."
    if ! zfs snapshot "${ZFS_POOL}@${SNAPSHOT_NAME}"; then
        log_message "Error: Failed to create snapshot ${SNAPSHOT_NAME}."
        echo "Failed to create snapshot ${SNAPSHOT_NAME}."
        exit 1
    fi
    log_message "Snapshot ${SNAPSHOT_NAME} created successfully."

    # Step 2: Send snapshot to the backup destination
    log_message "Backing up snapshot ${SNAPSHOT_NAME} to ${BACKUP_FILE}..."
    if ! zfs send "${ZFS_POOL}@${SNAPSHOT_NAME}" | gzip > "$BACKUP_FILE"; then
        log_message "Error: Failed to back up snapshot ${SNAPSHOT_NAME}."
        echo "Failed to back up snapshot ${SNAPSHOT_NAME}."
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
    echo "Backup process completed successfully. Check log for details."
}

# Function to restore ZFS backup
zfs_restore() {
    # List available backups
    echo "Available backups in ${BACKUP_DEST}:"
    ls "${BACKUP_DEST}" | grep "zfs_backup_"

    # Ask user to select a backup file
    echo "Enter the name of the backup file to restore (e.g., zfs_backup_20250113_123456.gz):"
    read BACKUP_FILE

    if [ ! -f "${BACKUP_DEST}/${BACKUP_FILE}" ]; then
        log_message "Error: Backup file ${BACKUP_FILE} not found in ${BACKUP_DEST}."
        echo "Backup file ${BACKUP_FILE} not found in ${BACKUP_DEST}."
        exit 1
    fi

    # Ask for confirmation
    echo "Restoring backup from ${BACKUP_DEST}/${BACKUP_FILE} will overwrite data in ${ZFS_POOL}. Proceed? (yes/no)"
    read CONFIRMATION
    if [ "$CONFIRMATION" != "yes" ]; then
        log_message "Restore canceled by user."
        echo "Restore canceled."
        exit 0
    fi

    # Perform restore
    log_message "Restoring ZFS backup from ${BACKUP_DEST}/${BACKUP_FILE}..."
    if ! gunzip < "${BACKUP_DEST}/${BACKUP_FILE}" | zfs receive "${ZFS_POOL}"; then
        log_message "Error: Failed to restore backup from ${BACKUP_FILE}."
        echo "Failed to restore backup from ${BACKUP_FILE}."
        exit 1
    fi
    log_message "Backup ${BACKUP_FILE} restored successfully."
    echo "Backup ${BACKUP_FILE} restored successfully."
}

# Main script logic
echo "Choose an option:"
echo "1) Backup ZFS"
echo "2) Restore ZFS"
read -p "Enter your choice (1 or 2): " CHOICE

case $CHOICE in
    1)
        zfs_backup
        ;;
    2)
        zfs_restore
        ;;
    *)
        echo "Invalid choice. Exiting."
        ;;
esac

exit 0
