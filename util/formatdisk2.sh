#!/bin/bash

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
        echo -e "${GREEN}${RESET} Expanding the ZFS pool..."
        zpool online -e $(zpool list -v | grep "${DISK}" | awk '{print $1}') ${DISK}
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ZFS pool expanded successfully."
        else
            echo -e "${RED}${RESET} Failed to expand ZFS pool. Aborting."
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
read -p "Enter the number of your choice: " fs_choice

# Step 6: Handle formatting based on the selected file system type
case $fs_choice in
    1)  # ZFS
        echo -e "${GREEN}${RESET} Installing ZFS utilities..."
        install_package_if_missing "zfsutils-linux"

        echo -e "${GREEN}${RESET} Ensuring all partitions on $DISK are unmounted..."
        umount ${DISK}* 2>/dev/null || echo "Partitions are not mounted."

        echo -e "${GREEN}${RESET} Checking for existing ZFS pools..."
        if zpool list | grep -q "${DISK}"; then
            zpool export $(zpool list -v | grep "${DISK}" | awk '{print $1}')
            echo -e "${GREEN}${RESET} ZFS pool exported."
        fi

        echo -e "${GREEN}${RESET} Wiping the disk and creating a new GPT partition table..."
        wipefs --all $DISK
        partprobe $DISK
        parted $DISK mklabel gpt
        if [ $? -ne 0 ]; then
            echo -e "${RED}${RESET} Failed to wipe the disk or create GPT label. Aborting."
            exit 1
        fi

        read -p "Enter the name for the new ZFS pool: " pool_name
        echo -e "${GREEN}${RESET} Creating ZFS pool ${pool_name}..."
        zpool create -f $pool_name $DISK
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} ZFS pool ${pool_name} created successfully."
        else
            echo -e "${RED}${RESET} Failed to create ZFS pool. Aborting."
            exit 1
        fi

        if ! grep -q "pool ${pool_name}" /etc/pve/storage.cfg; then
            echo -e "${GREEN}${RESET} Adding ZFS pool ${pool_name} to Proxmox storage configuration..."
            echo -e "zfspool: ${pool_name}" >> /etc/pve/storage.cfg
            echo -e "\tpool ${pool_name}" >> /etc/pve/storage.cfg
            echo -e "\tcontent iso,images" >> /etc/pve/storage.cfg
        else
            echo "ZFS pool ${pool_name} already exists in the Proxmox storage configuration."
        fi
        ;;
    2)  # ext4
        echo -e "${GREEN}${RESET} Formatting the disk ${DISK} with ext4..."
        umount ${DISK}* 2>/dev/null
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
    *)
        echo -e "${RED}${RESET} Invalid choice. Aborting."
        exit 1
        ;;
esac

echo -e "${GREEN}${RESET} Disk operation completed successfully."
