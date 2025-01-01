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
        echo "zfspool: $pool_name" >> /etc/pve/storage.cfg
        echo "\tpool $pool_name" >> /etc/pve/storage.cfg
        echo "\tcontent iso,images" >> /etc/pve/storage.cfg
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
