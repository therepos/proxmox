#!/bin/bash

# bash -c "$(wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/util/format-disk.sh)"
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/util/format-disk.sh)"

# Define colors for status messages
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to check and install missing packages
install_package_if_missing() {
    local package=$1
    if ! dpkg -l | grep -q "$package"; then
        echo -e "${RED}${RESET} $package not found. Installing..."
        apt update -y > /dev/null 2>&1
        apt install -y $package > /dev/null 2>&1
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

# Ensure `parted` is available
install_package_if_missing "parted"

# Step 1: List available disks
echo -e "${RESET}Listing available disks:${RESET}"
lsblk -d -o NAME,SIZE | grep -v "NAME" | nl

# Prompt the user to select a disk
read -p "Enter the number of the disk you want to partition: " disk_choice
DISK=$(lsblk -d -o NAME,SIZE | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')

# Validate the selected disk
if [ ! -e "$DISK" ]; then
    echo -e "${RED}${RESET} Error: The selected disk does not exist."
    exit 1
fi
echo -e "${GREEN}${RESET} You selected $DISK."

# Step 2: Warning and Cleanup
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

# Step 3: Create GPT partition table
echo -e "${GREEN}${RESET} Creating GPT partition table on ${DISK}..."
parted $DISK mklabel gpt
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} GPT partition table created."
else
    echo -e "${RED}${RESET} Failed to create GPT partition table."
    exit 1
fi

# Step 4: Create a single partition
echo -e "${GREEN}${RESET} Creating primary partition on ${DISK}..."
parted $DISK mkpart primary 0% 100%
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} Primary partition created."
else
    echo -e "${RED}${RESET} Failed to create primary partition."
    exit 1
fi

# Step 5: Format the partition
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

# Step 6: Mount the partition or ZFS pool
if [[ "$fs_choice" -ne 2 ]]; then
    MOUNT_POINT="/mnt/4tb"
    echo -e "${GREEN}${RESET} Creating mount point ${MOUNT_POINT}..."
    mkdir -p $MOUNT_POINT
    mount $PARTITION $MOUNT_POINT
    echo -e "${GREEN}${RESET} Partition mounted at ${MOUNT_POINT}."
    
    # Step 7: Add to /etc/fstab for auto-mount
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
else
    echo -e "${GREEN}${RESET} ZFS does not require /etc/fstab entry. Pool is mounted automatically."
fi

# Step 8: Verify the changes
echo -e "${GREEN}${RESET} The disk has been successfully partitioned, formatted, and mounted."
echo -e "${RESET}You can verify the mounted disk with 'df -h'."

df -h
