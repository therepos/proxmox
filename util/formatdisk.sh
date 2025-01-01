#!/bin/bash

# bash -c "$(wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/util/formatdisk.sh)"
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/util/formatdisk.sh)"

# Define colors for status messages
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to check if a package is installed, and install it if not
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

# Step 1: Check if parted is installed, and install it if not
install_package_if_missing "parted"

# Step 2: Let the user choose a disk
echo -e "${RESET}Listing available disks:${RESET}"
lsblk -d -o NAME,SIZE | grep -v "NAME" | nl
read -p "Enter the number of the disk you want to format or expand: " disk_choice
DISK=$(lsblk -d -o NAME,SIZE | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')

# Validate the selected disk
if [ ! -e "$DISK" ]; then
    echo -e "${RED}${RESET} Error: The selected disk does not exist."
    exit 1
fi

# Step 3: Ask the user whether they want to format or expand the disk (with numeric options)
echo -e "Choose an option:\n1) Format the disk\n2) Expand the disk"
read -p "Enter your choice (1/2): " action_choice

if [[ "$action_choice" == "2" ]]; then
    echo -e "${GREEN}${RESET} Expanding the disk..."
    
    # Step 4: Check the current format and expand the drive accordingly
    PARTITION="${DISK}p1"
    CURRENT_FS=$(lsblk -no FSTYPE $PARTITION)
    
    if [ "$CURRENT_FS" == "zfs" ]; then
        # Expand ZFS pool
        echo -e "${GREEN}${RESET} Expanding the ZFS pool..."
        zpool online -e $(zpool list -v | grep "${DISK}" | awk '{print $1}') ${DISK}
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ZFS pool expanded successfully."
        else
            echo -e "${RED}${RESET} Failed to expand ZFS pool. Aborting."
            exit 1
        fi
    elif [ "$CURRENT_FS" == "ext4" ]; then
        # Expand ext4 filesystem
        echo -e "${GREEN}${RESET} Expanding ext4 filesystem..."
        parted $DISK resizepart 1 100%
        resize2fs ${PARTITION}
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ext4 filesystem expanded successfully."
        else
            echo -e "${RED}${RESET} Failed to expand ext4 filesystem. Aborting."
            exit 1
        fi
    elif [ "$CURRENT_FS" == "ntfs" ]; then
        # Expand NTFS filesystem
        echo -e "${GREEN}${RESET} Expanding NTFS filesystem..."
        parted $DISK resizepart 1 100%
        ntfsresize ${PARTITION}
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} NTFS filesystem expanded successfully."
        else
            echo -e "${RED}${RESET} Failed to expand NTFS filesystem. Aborting."
            exit 1
        fi
    elif [ "$CURRENT_FS" == "exfat" ]; then
        # Expand exFAT filesystem
        echo -e "${GREEN}${RESET} Expanding exFAT filesystem..."
        parted $DISK resizepart 1 100%
        exfatresize ${PARTITION}
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} exFAT filesystem expanded successfully."
        else
            echo -e "${RED}${RESET} Failed to expand exFAT filesystem. Aborting."
            exit 1
        fi
    else
        echo -e "${RED}${RESET} Unsupported filesystem type for expansion: $CURRENT_FS"
        exit 1
    fi
    
    exit 0
fi

# Step 5: Ask the user for the format type
echo -e "${RESET}Select the file system type to format the disk:"
echo -e "1) ZFS"
echo -e "2) ext4"
echo -e "3) fat32"
echo -e "4) ntfs"
echo -e "5) exfat"
read -p "Enter the number of your choice: " fs_choice

# Step 6: Handle formatting based on the selected file system type
case $fs_choice in
    1)  # ZFS
        echo -e "${GREEN}${RESET} Installing ZFS utilities..."
        install_package_if_missing "zfsutils-linux"

        # Check if the disk is already part of a ZFS pool
        if zpool list | grep -q "${DISK}"; then
            echo -e "${RED}${RESET} The disk ${DISK} is part of an existing ZFS pool."
            read -p "Do you want to remove it from the current pool and create a new pool (WARNING: data will be lost)? (y/n): " remove_choice
            if [[ "$remove_choice" == "y" ]]; then
                # Forcefully destroy the existing ZFS pool
                zpool destroy $(zpool list -v | grep "${DISK}" | awk '{print $1}')
                echo -e "${GREEN}${RESET} Existing ZFS pool destroyed."
            else
                echo -e "${RED}${RESET} Aborting. Disk will not be used."
                exit 1
            fi
        fi

        # Ensure we create a different pool name to avoid conflicts
        read -p "Enter the name for the new ZFS pool: " pool_name
        echo -e "${GREEN}${RESET} Creating ZFS pool ${pool_name}..."
        zpool create -f $pool_name $DISK
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ZFS pool ${pool_name} created successfully."
        else
            echo -e "${RED}${RESET} Failed to create ZFS pool. Aborting."
            exit 1
        fi
        
        # Check if the pool is already in the Proxmox storage config
        if ! grep -q "pool ${pool_name}" /etc/pve/storage.cfg; then
            echo "Adding ZFS pool ${pool_name} to Proxmox storage configuration..."
            echo -e "zfspool: ${pool_name}" >> /etc/pve/storage.cfg
            echo -e "\tpool ${pool_name}" >> /etc/pve/storage.cfg
            echo -e "\tcontent iso,images" >> /etc/pve/storage.cfg
        else
            echo "ZFS pool ${pool_name} already exists in the Proxmox storage configuration."
        fi
        ;;
    2)  # ext4
        echo -e "${GREEN}${RESET} Formatting the disk ${DISK} with ext4..."
        # Unmount and wipe the drive if it is already mounted/formatted
        umount ${DISK}p1 2>/dev/null
        wipefs --all $DISK
        parted $DISK mklabel gpt
        parted $DISK mkpart primary 0% 100%
        mkfs.ext4 ${DISK}p1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ext4 file system created successfully."
        else
            echo -e "${RED}${RESET} Failed to create ext4 file system. Aborting."
            exit 1
        fi
        ;;
    3)  # fat32
        echo -e "${GREEN}${RESET} Formatting the disk ${DISK} with FAT32..."
        # Unmount and wipe the drive if it is already mounted/formatted
        umount ${DISK}p1 2>/dev/null
        wipefs --all $DISK
        parted $DISK mklabel gpt
        parted $DISK mkpart primary 0% 100%
        mkfs.fat -F 32 ${DISK}p1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} FAT32 file system created successfully."
        else
            echo -e "${RED}${RESET} Failed to create FAT32 file system. Aborting."
            exit 1
        fi
        ;;
    4)  # ntfs
        echo -e "${GREEN}${RESET} Formatting the disk ${DISK} with NTFS..."
        # Unmount and wipe the drive if it is already mounted/formatted
        umount ${DISK}p1 2>/dev/null
        wipefs --all $DISK
        parted $DISK mklabel gpt
        parted $DISK mkpart primary 0% 100%
        mkfs.ntfs ${DISK}p1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} NTFS file system created successfully."
        else
            echo -e "${RED}${RESET} Failed to create NTFS file system. Aborting."
            exit 1
        fi
        ;;
    5)  # exfat
        echo -e "${GREEN}${RESET} Formatting the disk ${DISK} with exFAT..."
        # Unmount and wipe the drive if it is already mounted/formatted
        umount ${DISK}p1 2>/dev/null
        wipefs --all $DISK
        parted $DISK mklabel gpt
        parted $DISK mkpart primary 0% 100%
        mkfs.exfat ${DISK}p1
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} exFAT file system created successfully."
        else
            echo -e "${RED}${RESET} Failed to create exFAT file system. Aborting."
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}${RESET} Invalid choice. Aborting."
        exit 1
        ;;
esac

# Step 7: Mount the partition or ZFS pool
if [ "$fs_choice" -ne 1 ]; then  # Only mount for non-ZFS file systems
    MOUNT_POINT="/mnt/$(basename $DISK)"
    echo -e "${GREEN}${RESET} Creating mount point ${MOUNT_POINT}..."
    mkdir -p $MOUNT_POINT
    mount ${DISK}p1 $MOUNT_POINT
    echo -e "${GREEN}${RESET} Partition mounted at ${MOUNT_POINT}."
else
    echo -e "${GREEN}${RESET} ZFS pool is automatically mounted."
fi

# Step 8: Add to /etc/fstab for auto-mount (if not ZFS)
if [ "$fs_choice" -ne 1 ]; then
    echo -e "${GREEN}${RESET} Adding ${DISK} to /etc/fstab for auto-mount on boot..."
    UUID=$(blkid -s UUID -o value ${DISK}p1)
    echo "UUID=$UUID $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
    mount -a
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${RESET} Partition added to /etc/fstab and verified successfully."
    else
        echo -e "${RED}${RESET} Failed to add partition to /etc/fstab or verify mount."
        exit 1
    fi
fi

# Step 9: Verify the changes
echo -e "${GREEN}${RESET} The disk has been successfully formatted and mounted."
df -h