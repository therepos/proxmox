#!/bin/bash

# wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/util/format-disk.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/util/format-disk.sh | bash

# Define colors for status messages (green tick and red cross)
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to check if a package is installed, and install it if not
install_package_if_missing() {
    local package=$1
    if ! dpkg -l | grep -q "$package"; then
        echo -e "${RED}${RESET} $package not found. Installing..."
        sudo apt update -y > /dev/null 2>&1
        sudo apt install -y $package > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} $package installed successfully."
        else
            echo -e "${RED}${RESET} Failed to install $package."
            exit 1
        fi
    else
        echo -e "${GREEN}${RESET} $package is already installed."
    fi
}

# Check and install parted if not installed
install_package_if_missing "parted"

# Step 1: List available disks and prompt the user to select one
echo -e "${RESET}Listing available disks:${RESET}"
lsblk -d -o NAME,SIZE | grep -v "NAME" | nl

# Prompt the user to select a disk by number
read -p "Enter the number of the disk you want to partition: " disk_choice

# Get the selected disk based on the user's input
DISK=$(lsblk -d -o NAME,SIZE | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')

# Validate the selected disk
if [ ! -e "$DISK" ]; then
    echo -e "${RED}${RESET} Error: The selected disk does not exist."
    exit 1
fi

echo -e "${GREEN}${RESET} You selected $DISK."

# Step 2: Warning message before proceeding
echo -e "${RED}${RESET} Warning: This script will erase all data on the disk ${DISK} and create a new partition table."
read -p "Do you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo -e "${RED}${RESET} Aborting the process."
    exit 1
fi

# Step 3: Create GPT partition table on the selected disk
echo -e "${GREEN}${RESET} Creating GPT partition table on ${DISK}..."
sudo parted $DISK mklabel gpt > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} GPT partition table created."
else
    echo -e "${RED}${RESET} Failed to create GPT partition table."
    exit 1
fi

# Step 4: Create a single partition on the disk
echo -e "${GREEN}${RESET} Creating primary partition on ${DISK}..."
sudo parted $DISK mkpart primary 0% 100% > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} Primary partition created."
else
    echo -e "${RED}${RESET} Failed to create primary partition."
    exit 1
fi

# Prompt user to select a file system type
echo -e "${RESET}Select a file system to format the partition:"
echo -e "1) ext4"
echo -e "2) zfs"
echo -e "3) fat32"
echo -e "4) ntfs"
echo -e "5) exfat"
read -p "Enter the number of your choice: " fs_choice

# Step 5: Format the new partition with the selected file system
PARTITION="${DISK}p1"
case $fs_choice in
    1)
        echo -e "${GREEN}${RESET} Formatting the partition ${PARTITION} with EXT4..."
        sudo mkfs.ext4 $PARTITION > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} Partition formatted as EXT4."
        else
            echo -e "${RED}${RESET} Failed to format as EXT4."
            exit 1
        fi
        ;;
    2)
        echo -e "${GREEN}${RESET} Installing ZFS..."
        install_package_if_missing "zfsutils-linux"
        echo -e "${GREEN}${RESET} Formatting the partition ${PARTITION} with ZFS..."
        sudo zpool create $PARTITION $PARTITION > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} Partition formatted as ZFS."
        else
            echo -e "${RED}${RESET} Failed to format as ZFS."
            exit 1
        fi
        ;;
    3)
        echo -e "${GREEN}${RESET} Formatting the partition ${PARTITION} with FAT32..."
        sudo mkfs.fat -F 32 $PARTITION > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} Partition formatted as FAT32."
        else
            echo -e "${RED}${RESET} Failed to format as FAT32."
            exit 1
        fi
        ;;
    4)
        echo -e "${GREEN}${RESET} Installing NTFS-3G..."
        install_package_if_missing "ntfs-3g"
        echo -e "${GREEN}${RESET} Formatting the partition ${PARTITION} with NTFS..."
        sudo mkfs.ntfs $PARTITION > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} Partition formatted as NTFS."
        else
            echo -e "${RED}${RESET} Failed to format as NTFS."
            exit 1
        fi
        ;;
    5)
        echo -e "${GREEN}${RESET} Installing exFAT utilities..."
        install_package_if_missing "exfat-utils"
        echo -e "${GREEN}${RESET} Formatting the partition ${PARTITION} with exFAT..."
        sudo mkfs.exfat $PARTITION > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} Partition formatted as exFAT."
        else
            echo -e "${RED}${RESET} Failed to format as exFAT."
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}${RESET} Invalid choice, aborting."
        exit 1
        ;;
esac

# Step 6: Create a mount point and mount the partition
MOUNT_POINT="/mnt/4tb"
echo -e "${GREEN}${RESET} Creating mount point ${MOUNT_POINT}..."
sudo mkdir -p $MOUNT_POINT > /dev/null 2>&1

echo -e "${GREEN}${RESET} Mounting ${PARTITION} to ${MOUNT_POINT}..."
sudo mount $PARTITION $MOUNT_POINT > /dev/null 2>&1

# Step 7: Add the partition to /etc/fstab for auto-mount on boot
UUID=$(sudo blkid -s UUID -o value $PARTITION)
echo -e "${GREEN}${RESET} Adding ${PARTITION} to /etc/fstab for auto-mount on boot..."
echo "UUID=$UUID $MOUNT_POINT $fs_choice defaults 0 2" | sudo tee -a /etc/fstab > /dev/null

# Step 8: Verify the changes
echo -e "${GREEN}${RESET} The disk has been successfully partitioned, formatted, and mounted."
echo -e "${RESET}You can verify the mounted disk with 'df -h'."

df -h
