#!/bin/bash

# Define status colors for messaging
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to install missing packages
install_package_if_missing() {
    local package=$1
    if ! dpkg -l | grep -q "$package"; then
        echo -e "${RED}${RESET} $package not found. Installing..."
        apt update -y
        apt install -y $package
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

# Ensure necessary tools are installed
install_package_if_missing "parted"
install_package_if_missing "zfsutils-linux"

# List available disks
echo -e "Available disks:"
lsblk -d -o NAME,SIZE | grep -v "NAME" | nl

# Prompt user for disk selection
read -p "Select a disk by entering its number: " disk_choice

# Correctly map user input to the disk
DISK=$(lsblk -d -o NAME | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')

# Debugging step to confirm selection
echo "Selected disk: $DISK"

# Validate the selected disk
if [ ! -e "$DISK" ]; then
    echo -e "${RED}${RESET} Error: Selected disk does not exist."
    exit 1
fi

# Confirm wiping the disk
echo -e "The selected disk (${DISK}) will be wiped and reformatted. All data will be lost."
read -p "Do you want to proceed? (y/n): " confirm_wipe

if [[ "$confirm_wipe" != "y" ]]; then
    echo -e "${RED}${RESET} Operation aborted."
    exit 0
fi

# Check if the disk is part of a ZFS pool
pool_name=$(zpool status | grep -B1 $DISK | head -n1 | awk '{print $1}')

if [[ -n "$pool_name" ]]; then
    echo -e "${GREEN}${RESET} Disk is part of ZFS pool $pool_name. Exporting the pool..."
    zpool export $pool_name
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${RESET} ZFS pool $pool_name exported successfully."
    else
        echo -e "${RED}${RESET} Failed to export ZFS pool $pool_name."
        exit 1
    fi
fi

# Wipe the disk
echo -e "${GREEN}${RESET} Wiping the disk ${DISK}..."
wipefs --all $DISK
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} Disk wiped successfully."
else
    echo -e "${RED}${RESET} Failed to wipe the disk."
    exit 1
fi

# Action selection
echo -e "Choose an action:\n1) Expand the disk\n2) Format the disk"
read -p "Enter your choice (1/2): " action_choice

if [ "$action_choice" == "1" ]; then
    echo -e "${GREEN}${RESET} Expanding the disk..."
    parted $DISK resizepart 1 100%
    resize2fs ${DISK}1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${RESET} Disk expanded successfully."
    else
        echo -e "${RED}${RESET} Failed to expand the disk."
        exit 1
    fi
    exit 0
elif [ "$action_choice" != "2" ]; then
    echo -e "${RED}${RESET} Invalid choice."
    exit 1
fi

# Format selection
echo -e "Select file system:\n1) ZFS\n2) ext4"
read -p "Enter your choice (1/2): " fs_choice

if [ "$fs_choice" == "1" ]; then
    read -p "Enter the ZFS pool name: " pool_name
    echo -e "${GREEN}${RESET} Creating ZFS pool $pool_name..."
    zpool create -f $pool_name $DISK
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${RESET} ZFS pool $pool_name created successfully."
        
        # Remove existing ZFS pool configuration if present
        if grep -q "zfspool: $pool_name" /etc/pve/storage.cfg; then
            echo -e "${GREEN}${RESET} Removing existing ZFS pool $pool_name from Proxmox configuration..."
            sed -i "/zfspool: $pool_name/,/^$/d" /etc/pve/storage.cfg
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${RESET} Existing ZFS pool configuration removed successfully."
            else
                echo -e "${RED}${RESET} Failed to remove existing ZFS pool configuration."
                exit 1
            fi
        fi

        # Add the new ZFS pool configuration
        echo -e "${GREEN}${RESET} Adding ZFS pool $pool_name to Proxmox storage configuration..."
        {
            echo "zfspool: $pool_name"
            echo "    pool $pool_name"
            echo "    content images,iso"
        } >> /etc/pve/storage.cfg
        systemctl reload pvedaemon
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ZFS pool $pool_name successfully added to Proxmox storage."
        else
            echo -e "${RED}${RESET} Failed to reload Proxmox configuration."
        fi
    else
        echo -e "${RED}${RESET} Failed to create ZFS pool."
        exit 1
    fi
elif [ "$fs_choice" == "2" ]; then
    echo -e "${GREEN}${RESET} Formatting disk with ext4..."
    parted $DISK mklabel gpt
    parted $DISK mkpart primary ext4 0% 100%
    mkfs.ext4 ${DISK}1
    MOUNT_POINT="/mnt/$(basename $DISK)"
    mkdir -p $MOUNT_POINT
    mount ${DISK}1 $MOUNT_POINT
    echo "UUID=$(blkid -s UUID -o value ${DISK}1) $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
    echo -e "${GREEN}${RESET} ext4 filesystem formatted and mounted at $MOUNT_POINT."
else
    echo -e "${RED}${RESET} Invalid choice."
    exit 1
fi

exit 0
