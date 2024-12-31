#!/bin/bash

# bash -c "$(wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/util/formatdisk.sh)"
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/util/formatdisk.sh)"

# Define colors for status messages
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to check if the disk is part of an existing ZFS pool
check_zfs_pool() {
    local disk=$1
    zpool list -v | grep -q "${disk}" && return 0 || return 1
}

# List available disks and prompt the user to select one
echo -e "${RESET}Listing available disks:${RESET}"
lsblk -d -o NAME,SIZE | grep -v "NAME" | nl
read -p "Enter the number of the disk you want to format or expand: " disk_choice
DISK=$(lsblk -d -o NAME,SIZE | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')

# Validate the selected disk
if [ ! -e "$DISK" ]; then
    echo -e "${RED}${RESET} Error: The selected disk does not exist."
    exit 1
fi

# Step 1: Check if the disk is part of an existing ZFS pool
if check_zfs_pool "${DISK}"; then
    echo -e "${GREEN}${RESET} The disk ${DISK} is part of an existing ZFS pool."
    read -p "Do you want to expand the ZFS pool using this disk or format it? (expand/format): " action_choice
    if [[ "$action_choice" == "expand" ]]; then
        # Expand the ZFS pool
        echo -e "${GREEN}${RESET} Expanding the ZFS pool with ${DISK}..."
        zpool online -e $(zpool list -v | grep "${DISK}" | awk '{print $1}') ${DISK}
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ZFS pool expanded successfully."
        else
            echo -e "${RED}${RESET} Failed to expand ZFS pool. Aborting."
            exit 1
        fi
    elif [[ "$action_choice" == "format" ]]; then
        # Proceed with formatting the disk
        echo -e "${RED}${RESET} Warning: This will erase all data on ${DISK}."
        read -p "Do you want to clean the disk and proceed? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            echo -e "${RED}${RESET} Aborting."
            exit 1
        fi

        # Cleanup existing partitions and filesystems
        echo -e "${GREEN}${RESET} Wiping existing filesystems and partitions on ${DISK}..."
        wipefs --all $DISK
        dd if=/dev/zero of=$DISK bs=1M count=10 > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} Disk wiped successfully."
        else
            echo -e "${RED}${RESET} Failed to wipe the disk."
            exit 1
        fi
    else
        echo -e "${RED}${RESET} Invalid choice. Exiting."
        exit 1
    fi
else
    echo -e "${RED}${RESET} The disk ${DISK} is not part of any ZFS pool."
    read -p "Do you want to format it? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo -e "${RED}${RESET} Aborting."
        exit 1
    fi

    # Proceed with formatting the disk
    echo -e "${RED}${RESET} Warning: This will erase all data on ${DISK}."
    echo -e "${GREEN}${RESET} Wiping existing filesystems and partitions on ${DISK}..."
    wipefs --all $DISK
    dd if=/dev/zero of=$DISK bs=1M count=10 > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${RESET} Disk wiped successfully."
    else
        echo -e "${RED}${RESET} Failed to wipe the disk."
        exit 1
    fi
fi

# Proceed with the format step
# Step 2: Create GPT partition table
echo -e "${GREEN}${RESET} Creating GPT partition table on ${DISK}..."
parted $DISK mklabel gpt
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} GPT partition table created."
else
    echo -e "${RED}${RESET} Warning: Unable to inform the kernel about the changes."
    echo -e "${RESET}Attempting to refresh the kernel's view of the disk..."
    partprobe $DISK || { echo -e "${RED}${RESET} Kernel re-read failed. You may need to reboot."; exit 1; }
    echo -e "${GREEN}${RESET} Kernel successfully updated."
fi

# Step 3: Create a single partition
echo -e "${GREEN}${RESET} Creating primary partition on ${DISK}..."
parted $DISK mkpart primary 0% 100%
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} Primary partition created."
else
    echo -e "${RED}${RESET} Failed to create primary partition."
    exit 1
fi

# Step 4: Format the partition
PARTITION="${DISK}p1"
echo -e "${RESET}Select a file system to format the partition:"
echo -e "1) ext4"
echo -e "2) zfs"
echo -e "3) fat32"
echo -e "4) ntfs"
echo -e "5) exfat"
read -p "Enter the number of your choice: " fs_choice

case $fs_choice in
    1)
        echo -e "${GREEN}${RESET} Formatting the partition ${PARTITION} with EXT4..."
        mkfs.ext4 $PARTITION
        ;;
    2)
        echo -e "${GREEN}${RESET} Installing ZFS utilities..."
        install_package_if_missing "zfsutils-linux"
        echo -e "${GREEN}${RESET} Formatting the disk ${DISK} as a ZFS pool..."
        zpool create -f -o ashift=12 mypool $DISK
        ;;
    3)
        echo -e "${GREEN}${RESET} Formatting the partition ${PARTITION} with FAT32..."
        mkfs.fat -F 32 $PARTITION
        ;;
    4)
        echo -e "${GREEN}${RESET} Installing NTFS utilities..."
        install_package_if_missing "ntfs-3g"
        mkfs.ntfs $PARTITION
        ;;
    5)
        echo -e "${GREEN}${RESET} Installing exFAT utilities..."
        install_package_if_missing "exfat-utils"
        mkfs.exfat $PARTITION
        ;;
    *)
        echo -e "${RED}${RESET} Invalid choice. Aborting."
        exit 1
        ;;
esac

# Step 5: Mount the partition or ZFS pool
MOUNT_POINT="/mnt/4tb"
echo -e "${GREEN}${RESET} Creating mount point ${MOUNT_POINT}..."
mkdir -p $MOUNT_POINT
mount $PARTITION $MOUNT_POINT
echo -e "${GREEN}${RESET} Partition mounted at ${MOUNT_POINT}."

# Step 6: Add to /etc/fstab for auto-mount
echo -e "${GREEN}${RESET} Adding ${PARTITION} to /etc/fstab for auto-mount on boot..."
UUID=$(blkid -s UUID -o value $PARTITION)
echo "UUID=$UUID $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
mount -a
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} Partition added to /etc/fstab and verified successfully."
else
    echo -e "${RED}${RESET} Failed to add partition to /etc/fstab or verify mount."
    exit 1
fi

# Step 7: Verify the changes
echo -e "${GREEN}${RESET} The disk has been successfully partitioned, formatted, and mounted."
df -h
