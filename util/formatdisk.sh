#!/bin/bash

# bash -c "$(wget --no-cache -qLO- https://github.com/therepos/proxmox/raw/main/util/formatdisk.sh)"

# Function to check and install required dependencies
install_dependencies() {
    echo "Checking for required dependencies..."
    required_packages=(parted cloud-guest-utils)

    for pkg in "${required_packages[@]}"; do
        if ! dpkg -l | grep -qw $pkg; then
            echo "$pkg is not installed. Installing..."
            apt-get update && apt-get install -y $pkg || { echo "Failed to install $pkg."; exit 1; }
        else
            echo "$pkg is already installed."
        fi
    done
}

# Function to check disk usage and report unallocated space
disk_status() {
    echo "Checking disk usage and capacity..."
    lsblk -o NAME,FSTYPE,SIZE,USED,AVAIL,MOUNTPOINT
    echo ""
}

# Function to expand an ext4 partition if needed
expand_ext4_partition() {
    local disk=$1
    echo "Expanding ext4 partition on $disk..."

    # Get the partition and its size
    part=$(lsblk -np -o NAME,SIZE -x SIZE | grep "${disk}" | awk '{print $1}' | tail -n 1)

    if [ -z "$part" ]; then
        echo "No partition found on $disk. Skipping expansion."
        return
    fi

    # Resize partition
    growpart $disk ${part: -1} || { echo "Failed to grow partition."; return; }

    # Resize filesystem
    resize2fs $part || { echo "Failed to resize filesystem."; return; }

    echo "Partition on $disk expanded successfully."
}

# Function to check and mount disks if not mounted
check_and_mount() {
    local disk=$1
    local part=$(lsblk -np -o NAME -x SIZE | grep "${disk}" | tail -n 1)
    local mount_point=$(lsblk -no MOUNTPOINT "$part")

    if [ -z "$mount_point" ]; then
        echo "Mount point not found for $part. Attempting to mount..."
        mkdir -p /mnt/$disk
        mount $part /mnt/$disk || { echo "Failed to mount $part."; return; }
        echo "$part mounted at /mnt/$disk."
    else
        echo "$part is already mounted at $mount_point."
    fi
}

# Main script

echo "Starting disk check..."

# Ensure dependencies are installed
install_dependencies

# Show current disk status
disk_status

# Find all drives
for disk in $(lsblk -nd -o NAME); do
    # Get disk size
    size=$(lsblk -b -dn -o SIZE "/dev/$disk")

    # Get partition size
    part_size=$(lsblk -b -dn -o SIZE "/dev/${disk}1" 2>/dev/null || echo 0)

    # Check if the disk is under-utilized
    if [ "$part_size" -lt "$size" ]; then
        echo "Disk /dev/$disk is under-utilized. Expanding..."
        fstype=$(lsblk -no FSTYPE "/dev/${disk}1" 2>/dev/null)

        if [ "$fstype" == "ext4" ]; then
            expand_ext4_partition "/dev/$disk"
        else
            echo "Unsupported filesystem ($fstype) on /dev/$disk. Skipping..."
        fi
    else
        echo "Disk /dev/$disk is fully utilized. No action needed."
    fi

    # Check and mount the disk
    check_and_mount "/dev/$disk"
done

# Final status check
echo "Final disk status:"
disk_status

echo "Disk check completed."
