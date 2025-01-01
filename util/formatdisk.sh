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
lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME" | nl
read -p "Select a disk by entering its number: " disk_choice

# Correctly map user input to the disk
DISK=$(lsblk -d -o NAME | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')
SIZE=$(lsblk -d -o NAME,SIZE | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print $2}')

# Confirm disk details with the user
echo -e "You selected the disk ${DISK} with size ${SIZE}. Confirm it is correct before proceeding."
read -p "Is this correct? (y/n): " confirm_disk
if [[ "$confirm_disk" != "y" ]]; then
    echo -e "${RED}${RESET} Operation aborted."
    exit 0
fi

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

# Check if its ZFS pool, if yes remove the config
# Find the pool name associated with the identifier
    # Get the WWN of the selected disk
    disk_wwn=$(lsblk -o NAME,WWN | grep $(basename $DISK) | awk '{print $2}')
    echo "Disk WWN: $disk_wwn"
    
    # Find the pool name associated with the WWN
    old_pool_name=$(zpool list -v | grep -B1 "$disk_wwn" | head -n1 | awk '{print $1}')
    echo "Old Pool Name: $old_pool_name"
    
    # Check if a pool name was found
    if [[ -n "$old_pool_name" ]]; then
        echo "Detected pool: $old_pool_name associated with $DISK."
        # Remove old pool configuration from /etc/pve/storage.cfg
        if grep -q "zfspool: $old_pool_name" /etc/pve/storage.cfg; then
            echo -e "${GREEN}${RESET} Removing ZFS pool $old_pool_name from Proxmox configuration..."
            sed -i "/zfspool: $old_pool_name/,/^$/d" /etc/pve/storage.cfg
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${RESET} Successfully removed ZFS pool configuration for $old_pool_name."
            else
                echo -e "${RED}${RESET} Failed to remove ZFS pool configuration for $old_pool_name."
                exit 1
            fi
        fi
        # Export the pool
        echo -e "${GREEN}${RESET} Exporting ZFS pool $old_pool_name..."
        zpool export "$old_pool_name"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ZFS pool $old_pool_name exported successfully."
        else
            echo -e "${RED}${RESET} Failed to export ZFS pool $old_pool_name. Ensure the pool is not in use."
            exit 1
        fi
    else
        echo "No pool detected for $DISK."
        echo -e "${GREEN}${RESET} No ZFS pool detected for the selected disk. Proceeding with wipe."
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

        # Add the new ZFS pool configuration
        echo -e "${GREEN}${RESET} Adding ZFS pool $pool_name to Proxmox storage configuration..."
        {
            echo
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
