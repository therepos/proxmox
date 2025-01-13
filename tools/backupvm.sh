#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/backupvm.sh)"

# Variables
BACKUP_SRC_DIR="/var/lib/vz/dump"  # Default location for vzdump backups
BACKUP_DEST_DIR="/mnt/sec/backup"  # Destination directory (external storage or custom directory)
PROXMOX_BACKUP_DIR="/var/lib/vz/dump"  # Proxmox default backup folder

# Function to save the backup
save_backup() {
    # Check if the source backup directory exists
    if [ ! -d "$BACKUP_SRC_DIR" ]; then
        echo "Error: Source backup directory $BACKUP_SRC_DIR does not exist."
        exit 1
    fi

    # Check if the destination directory exists, if not create it
    if [ ! -d "$BACKUP_DEST_DIR" ]; then
        echo "Destination directory $BACKUP_DEST_DIR does not exist. Creating it now..."
        mkdir -p "$BACKUP_DEST_DIR"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create destination directory $BACKUP_DEST_DIR."
            exit 1
        fi
        echo "Destination directory $BACKUP_DEST_DIR created successfully."
    fi

    # Get the latest backup file
    LATEST_BACKUP_VMA=$(ls -t $BACKUP_SRC_DIR/*.vma.zst | head -n 1)
    LATEST_BACKUP_LOG=$(ls -t $BACKUP_SRC_DIR/*.log | head -n 1)

    # Check if the backup files exist
    if [ -z "$LATEST_BACKUP_VMA" ]; then
        echo "Error: No .vma.zst backup files found in $BACKUP_SRC_DIR."
        exit 1
    fi

    if [ -z "$LATEST_BACKUP_LOG" ]; then
        echo "Error: No .log backup files found in $BACKUP_SRC_DIR."
        exit 1
    fi

    # Get the backup file names
    BACKUP_FILE_VMA=$(basename "$LATEST_BACKUP_VMA")
    BACKUP_FILE_LOG=$(basename "$LATEST_BACKUP_LOG")

    # Copy the .vma.zst backup file to the destination directory
    echo "Copying backup file $BACKUP_FILE_VMA to $BACKUP_DEST_DIR..."
    cp "$LATEST_BACKUP_VMA" "$BACKUP_DEST_DIR"
    if [ $? -eq 0 ]; then
        echo "Backup file $BACKUP_FILE_VMA successfully copied."
    else
        echo "Error: Failed to copy $BACKUP_FILE_VMA."
        exit 1
    fi

    # Copy the .log backup file to the destination directory
    echo "Copying backup log file $BACKUP_FILE_LOG to $BACKUP_DEST_DIR..."
    cp "$LATEST_BACKUP_LOG" "$BACKUP_DEST_DIR"
    if [ $? -eq 0 ]; then
        echo "Backup log file $BACKUP_FILE_LOG successfully copied."
    else
        echo "Error: Failed to copy $BACKUP_FILE_LOG."
        exit 1
    fi

    echo "Both files successfully copied to $BACKUP_DEST_DIR."
}

# Function to restore the backup
restore_backup() {
    # Check if the destination directory exists
    if [ ! -d "$BACKUP_DEST_DIR" ]; then
        echo "Error: Backup directory $BACKUP_DEST_DIR does not exist."
        exit 1
    fi

    # Get the latest backup file in the destination directory
    RESTORE_BACKUP_VMA=$(ls -t $BACKUP_DEST_DIR/*.vma.zst | head -n 1)
    RESTORE_BACKUP_LOG=$(ls -t $BACKUP_DEST_DIR/*.log | head -n 1)

    # Check if the backup files exist
    if [ -z "$RESTORE_BACKUP_VMA" ]; then
        echo "Error: No .vma.zst backup files found in $BACKUP_DEST_DIR."
        exit 1
    fi

    if [ -z "$RESTORE_BACKUP_LOG" ]; then
        echo "Error: No .log backup files found in $BACKUP_DEST_DIR."
        exit 1
    fi

    # Copy the files back to the Proxmox default backup folder
    echo "Restoring backup file $(basename $RESTORE_BACKUP_VMA) to $PROXMOX_BACKUP_DIR..."
    cp "$RESTORE_BACKUP_VMA" "$PROXMOX_BACKUP_DIR"
    if [ $? -eq 0 ]; then
        echo "Backup file $(basename $RESTORE_BACKUP_VMA) successfully restored."
    else
        echo "Error: Failed to restore $(basename $RESTORE_BACKUP_VMA)."
        exit 1
    fi

    echo "Restoring backup log file $(basename $RESTORE_BACKUP_LOG) to $PROXMOX_BACKUP_DIR..."
    cp "$RESTORE_BACKUP_LOG" "$PROXMOX_BACKUP_DIR"
    if [ $? -eq 0 ]; then
        echo "Backup log file $(basename $RESTORE_BACKUP_LOG) successfully restored."
    else
        echo "Error: Failed to restore $(basename $RESTORE_BACKUP_LOG)."
        exit 1
    fi

    echo "Both files successfully restored to $PROXMOX_BACKUP_DIR."
}

# Main menu
echo "Choose an option:"
echo "1. Save VM backup"
echo "2. Restore VM backup"
read -p "Enter your choice (1/2): " CHOICE

case $CHOICE in
    1)
        save_backup
        ;;
    2)
        restore_backup
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

exit 0
