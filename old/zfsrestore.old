#!/bin/bash

# Variables
BACKUP_DEST="/mnt/nvme0n1"         # Location of backups on the ext4 drive
ZFS_POOL="rpool"                  # ZFS pool to restore into
LOG_FILE="${BACKUP_DEST}/zfs_recovery_log.txt"  # Log file path

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Step 1: List available backups
log_message "Listing available backups in ${BACKUP_DEST}..."
backups=($(ls "$BACKUP_DEST"/*.gz 2>/dev/null))  # Find all .gz files
echo "DEBUG: Found backups: ${backups[@]}" | tee -a "$LOG_FILE"

if [ ${#backups[@]} -eq 0 ]; then
    log_message "No valid backup files found in ${BACKUP_DEST}. Exiting."
    ls "$BACKUP_DEST" >> "$LOG_FILE"  # Log directory contents for debugging
    exit 1
fi

echo "Available backups:"
for i in "${!backups[@]}"; do
    echo "$i) ${backups[$i]}"
done

# Step 2: Ask the user to select a backup
echo "Enter the number of the backup to restore:"
read -r selection

if [[ "$selection" -lt 0 || "$selection" -ge ${#backups[@]} ]]; then
    log_message "Invalid selection. Exiting."
    exit 1
fi

selected_backup="${backups[$selection]}"
log_message "DEBUG: User selected backup: ${selected_backup}" | tee -a "$LOG_FILE"

# Step 3: Confirm restoration
echo "This will overwrite the current state of ${ZFS_POOL}. Proceed? (yes/no)"
read -r confirm
if [[ "$confirm" != "yes" ]]; then
    log_message "Restoration cancelled by user. Exiting."
    exit 0
fi

# Step 4: Restore the backup
log_message "Restoring backup ${selected_backup} to ZFS pool ${ZFS_POOL}..."
if ! gunzip < "$selected_backup" | zfs receive -F "${ZFS_POOL}"; then
    log_message "Error: Failed to restore backup ${selected_backup}."
    exit 1
fi

log_message "Backup ${selected_backup} restored successfully to ZFS pool ${ZFS_POOL}."
exit 0
