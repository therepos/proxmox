#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/formatdisk.sh)"

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
    echo -e "Do you want to mount the drive instead? (y/n): "
    read -p "Enter your choice: " mount_choice
    if [[ "$mount_choice" != "y" ]]; then
        echo -e "${RED}${RESET} Operation aborted."
        exit 0
    else
        # Detect file system and mount the drive
        FS_TYPE=$(lsblk -f | grep "$(basename $DISK)" | awk '{print $2}')
        if [ -z "$FS_TYPE" ]; then
            echo -e "${RED}${RESET} No file system detected. Cannot mount the drive."
            exit 1
        fi

        MOUNT_POINT="/mnt/${DISK##*/}"
        mkdir -p $MOUNT_POINT

        mount -t $FS_TYPE $DISK $MOUNT_POINT
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}${RESET} Drive mounted successfully at $MOUNT_POINT."
            exit 0
        else
            echo -e "${RED}${RESET} Failed to mount the drive."
            exit 1
        fi
    fi
fi

# Rest of the script proceeds here for wiping and formatting...
