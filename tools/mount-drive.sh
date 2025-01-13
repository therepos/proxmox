#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/mount-drive.sh)"

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# Check if /mnt/extdrive exists, if not create it
if [ ! -d "/mnt/extdrive" ]; then
    mkdir -p /mnt/extdrive || status_message "failure" "Failed to create /mnt/extdrive."
fi

# Check if any external drive is mounted to /mnt/extdrive
MOUNTED_DRIVE=$(mount | grep "/mnt/extdrive")

if [ -n "$MOUNTED_DRIVE" ]; then
    echo "An external drive is already mounted at /mnt/extdrive. Do you want to unmount it? (y/n)"
    read -r RESPONSE
    if [[ "$RESPONSE" =~ ^[Yy]$ ]]; then
        umount /mnt/extdrive || status_message "failure" "Failed to unmount the drive from /mnt/extdrive."
        status_message "success" "Drive unmounted successfully."
    else
        status_message "failure" "Operation aborted by user."
    fi
else
    # List available drives
    echo "No drive currently mounted to /mnt/extdrive. Listing available drives..."
    AVAILABLE_DRIVES=$(lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT | grep -vE "^loop|MOUNTPOINT")

    echo -e "Available drives:\n$AVAILABLE_DRIVES"
    echo "Select a drive to mount (e.g., sdb1):"
    read -r SELECTED_DRIVE

    # Check if the selected drive exists
    if ! lsblk | grep -q "$SELECTED_DRIVE"; then
        status_message "failure" "Invalid drive selected."
    fi

    # Detect the filesystem of the selected drive
    DRIVE_FS=$(lsblk -no FSTYPE "/dev/$SELECTED_DRIVE")
    echo "Detected filesystem: $DRIVE_FS"

    # Install necessary drivers if not installed
    case "$DRIVE_FS" in
        "ntfs")
            if ! command -v ntfs-3g &>/dev/null; then
                echo "ntfs-3g driver not found. Installing..."
                sudo apt-get update && sudo apt-get install -y ntfs-3g || status_message "failure" "Failed to install ntfs-3g."
            fi
            ;;
        "vfat")
            echo "VFAT detected. No additional drivers needed."
            ;;
        "exfat")
            if ! command -v exfat-fuse &>/dev/null; then
                echo "exfat-fuse driver not found. Installing..."
                sudo apt-get update && sudo apt-get install -y exfat-fuse || status_message "failure" "Failed to install exfat-fuse."
            fi
            ;;
        *)
            status_message "failure" "Unsupported filesystem: $DRIVE_FS."
            ;;
    esac

    # Mount the drive
    sudo mount "/dev/$SELECTED_DRIVE" /mnt/extdrive || status_message "failure" "Failed to mount the drive."
    status_message "success" "Drive mounted successfully to /mnt/extdrive."
fi