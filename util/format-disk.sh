#!/bin/bash

# wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/util/format-disk.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/util/format-disk.sh | bash

echo $(date)

#!/bin/bash

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

# Step 2: User selection for disk
read -r -p "Please select a disk by entering the corresponding number (e.g., 1, 2, 3): " disk_choice

# Validate user input
if [[ "$disk_choice" =~ ^[0-9]+$ ]]; then
    # Get the selected disk based on the user's input
    DISK=$(lsblk -d -o NAME,SIZE | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')
    
    # Check if the disk exists
    if [ -e "$DISK" ]; then
        echo -e "${GREEN}${RESET} You selected $DISK."
    else
        echo -e "${RED}${RESET} Invalid disk selection. Please choose a valid disk."
        exit 1
    fi
else
    echo -e "${RED}${RESET} Invalid input. Please enter a valid disk number."
    exit 1
fi

# Step 3: Warning message before proceeding
echo -e "${RED}${RESET} Warning: This script will erase all data on the disk ${DISK} and create a new partition table."
read -r -p "Do you want to continue? <y/N>: " confirm
if [[ ${confirm,,} != "y" && ${confirm,,} != "yes" ]]; then
    echo -e "${RED}${RESET} Aborting the process."
    exit 1
fi

# Step 4: Create GPT partition table on the selected disk
echo -e "${GREEN}${RESET} Creating GPT partition table on ${DISK}..."
sudo parted $DISK mklabel gpt > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} GPT partition table created."
else
    echo -e "${RED}${RESET} Failed to create GPT partition table."
    exit 1
fi

# Step 5: Create a single partition on the disk
echo -e "${GREEN}${RESET} Creating primary partition on ${DISK}..."
sudo parted $DISK mkpart primary 0% 100% > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} Primary partition created."
else
    echo -e "${RED}${RESET} Failed to create primary partition."
    exit 1
fi

# Step 6: Prompt user to select a file system type
echo -e "${RESET}Select a file system to format the partition:"
echo -e "1) ext4"
echo -e "2) zfs"
echo -e "3) fat32"
echo -e "4) ntfs"
echo -e "5) exfat"
read -r -p "Enter the number of your choice: " fs_choice

# Step 7: Format the new partition with the selected file system
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
        install_package_if_missi



