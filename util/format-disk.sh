#!/bin/bash

# wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/util/format-disk.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/util/format-disk.sh | bash

# Step 1: List available disks and prompt the user to select one
echo "Listing available disks:"
lsblk -d -o NAME,SIZE | grep -v "NAME" | nl

# Prompt the user to select a disk by number
read -p "Enter the number of the disk you want to partition: " disk_choice

# Get the selected disk based on the user's input
DISK=$(lsblk -d -o NAME,SIZE | grep -v "NAME" | sed -n "${disk_choice}p" | awk '{print "/dev/" $1}')

# Validate the selected disk
if [ ! -e "$DISK" ]; then
    echo "Error: The selected disk does not exist."
    exit 1
fi

echo "You selected $DISK."

# Step 2: Warning message before proceeding
echo "Warning: This script will erase all data on the disk ${DISK} and create a new partition table."
read -p "Do you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Aborting the process."
    exit 1
fi

# Step 3: Create GPT partition table on the selected disk
echo "Creating GPT partition table on ${DISK}..."
sudo parted $DISK mklabel gpt

# Step 4: Create a single EXT4 partition on the disk
echo "Creating primary partition on ${DISK}..."
sudo parted $DISK mkpart primary ext4 0% 100%

# Step 5: Format the new partition with EXT4 filesystem
PARTITION="${DISK}p1"
echo "Formatting the partition ${PARTITION} with EXT4..."
sudo mkfs.ext4 $PARTITION

# Step 6: Create a mount point and mount the partition
MOUNT_POINT="/mnt/4tb"
echo "Creating mount point ${MOUNT_POINT}..."
sudo mkdir -p $MOUNT_POINT

echo "Mounting ${PARTITION} to ${MOUNT_POINT}..."
sudo mount $PARTITION $MOUNT_POINT

# Step 7: Add the partition to /etc/fstab for auto-mount on boot
UUID=$(sudo blkid -s UUID -o value $PARTITION)
echo "Adding ${PARTITION} to /etc/fstab for auto-mount on boot..."

echo "UUID=$UUID $MOUNT_POINT ext4 defaults 0 2" | sudo tee -a /etc/fstab > /dev/null

# Step 8: Verify the changes
echo "The disk has been successfully partitioned, formatted, and mounted."
echo "You can verify the mounted disk with 'df -h'."

df -h
