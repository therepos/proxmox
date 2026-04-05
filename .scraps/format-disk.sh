#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/format-disk.sh?$(date +%s))"
# purpose: formats disk per user specification

GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

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

setup_zfs_pool() {
    local disk=$1
    read -p "Enter the ZFS pool name: " pool_name
    echo -e "${GREEN}${RESET} Creating ZFS pool $pool_name..."
    zpool create -f $pool_name $disk
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${RESET} ZFS pool $pool_name created successfully."
        {
            echo
            echo "zfspool: data-zfs"
            echo "    pool $pool_name"
            echo "    content rootdir,images,backup,vztmpl,iso"
            echo "    sparse 1"
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
}

setup_ext4_partition() {
    local disk=$1
    echo -e "${GREEN}${RESET} Formatting disk with ext4..."
    parted $disk mklabel gpt
    parted $disk mkpart primary ext4 0% 100%
    PARTITION="${disk}"
    mkfs.ext4 $PARTITION
    MOUNT_POINT="/mnt/sec"
    mkdir -p $MOUNT_POINT
    mount $PARTITION $MOUNT_POINT
    echo "UUID=$(blkid -s UUID -o value $PARTITION) $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
    systemctl daemon-reload
    echo -e "${GREEN}${RESET} ext4 filesystem formatted and mounted at $MOUNT_POINT."
}

install_package_if_missing "parted"
install_package_if_missing "zfsutils-linux"

echo -e "Available disks:"
lsblk -d -o NAME,SIZE,MODEL | grep -v "NAME" | nl
read -p "Select a disk by entering its number: " disk_choice

DISK=$(lsblk -d -o NAME | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')
SIZE=$(lsblk -d -o NAME,SIZE | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print $2}')

echo -e "You selected the disk ${DISK} with size ${SIZE}. Confirm it is correct before proceeding."
read -p "Is this correct? (y/n): " confirm_disk
if [[ "$confirm_disk" != "y" ]]; then
    echo -e "${RED}${RESET} Operation aborted."
    exit 0
fi

if [ ! -e "$DISK" ]; then
    echo -e "${RED}${RESET} Error: Selected disk does not exist."
    exit 1
fi

echo -e "The selected disk (${DISK}) will be wiped and reformatted. All data will be lost."
read -p "Do you want to proceed with wiping the disk? (y/n): " confirm_wipe

if [[ "$confirm_wipe" != "y" ]]; then
    echo -e "Do you want to mount the drive without wiping it? (y/n): "
    read -p "Enter your choice: " mount_choice
    if [[ "$mount_choice" != "y" ]]; then
        echo -e "${RED}${RESET} Operation aborted."
        exit 0
    else
        FS_TYPE=$(lsblk -f | grep "$(basename $DISK)" | awk '{print $2}')
        if [ -z "$FS_TYPE" ]; then
            echo -e "${RED}${RESET} No file system detected. Cannot mount the drive."
            exit 1
        fi

        if [ "$FS_TYPE" == "zfs" ]; then
            echo -e "${GREEN}${RESET} Detected ZFS file system. Attempting to import ZFS pool..."
            POOL_NAME=$(zpool list | grep $(basename $DISK) | awk '{print $1}')
            if [ -z "$POOL_NAME" ]; then
                echo -e "${RED}${RESET} No ZFS pool found. Unable to mount ZFS drive."
                exit 1
            fi

            zpool import $POOL_NAME
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${RESET} ZFS pool $POOL_NAME imported successfully."
            else
                echo -e "${RED}${RESET} Failed to import ZFS pool."
                exit 1
            fi
        elif [ "$FS_TYPE" == "ext4" ]; then
            echo -e "${GREEN}${RESET} Detected ext4 file system. Mounting..."
            MOUNT_POINT="/mnt/sec"
            mkdir -p $MOUNT_POINT
            mount $DISK $MOUNT_POINT
            echo "UUID=$(blkid -s UUID -o value $DISK) $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
            systemctl daemon-reload
            echo -e "${GREEN}${RESET} ext4 filesystem mounted at $MOUNT_POINT."
        else
            echo -e "${RED}${RESET} Unsupported file system type: $FS_TYPE"
            exit 1
        fi
        exit 0
    fi
fi

echo -e "${GREEN}${RESET} Wiping the disk ${DISK}..."
wipefs --all $DISK
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${RESET} Disk wiped successfully."
else
    echo -e "${RED}${RESET} Failed to wipe the disk."
    exit 1
fi

echo -e "Choose an action:\n1) Expand the disk\n2) Format the disk"
read -p "Enter your choice (1/2): " action_choice

if [ "$action_choice" == "1" ]; then
    echo -e "${GREEN}${RESET} Expanding the disk..."
    parted $DISK resizepart 1 100%
    resize2fs ${DISK}
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

echo -e "Select file system:\n1) ZFS\n2) ext4"
read -p "Enter your choice (1/2): " fs_choice

if [ "$fs_choice" == "1" ]; then
    setup_zfs_pool $DISK
elif [ "$fs_choice" == "2" ]; then
    setup_ext4_partition $DISK
else
    echo -e "${RED}${RESET} Invalid choice."
    exit 1
fi

exit 0
