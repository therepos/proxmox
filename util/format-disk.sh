
#!/bin/bash

# Define disk and partition details
DISK="/dev/nvme0n1"
PARTITION="${DISK}p1"
MOUNT_POINT="/mnt/4tb"

# Warning message before proceeding
echo "Warning: This script will erase all data on the disk ${DISK} and create a new partition table."
read -p "Do you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Aborting the process."
    exit 1
fi

# Step 1: Create GPT partition table on the disk
echo "Creating GPT partition table on ${DISK}..."
sudo parted $DISK mklabel gpt

# Step 2: Create a single EXT4 partition on the disk
echo "Creating primary partition on ${DISK}..."
sudo parted $DISK mkpart primary ext4 0% 100%

# Step 3: Format the new partition with EXT4 filesystem
echo "Formatting the partition ${PARTITION} with EXT4..."
sudo mkfs.ext4 $PARTITION

# Step 4: Create a mount point and mount the partition
echo "Creating mount point ${MOUNT_POINT}..."
sudo mkdir -p $MOUNT_POINT

echo "Mounting ${PARTITION} to ${MOUNT_POINT}..."
sudo mount $PARTITION $MOUNT_POINT

# Step 5: Add the partition to /etc/fstab for auto-mount on boot
UUID=$(sudo blkid -s UUID -o value $PARTITION)
echo "Adding ${PARTITION} to /etc/fstab for auto-mount on boot..."

echo "UUID=$UUID $MOUNT_POINT ext4 defaults 0 2" | sudo tee -a /etc/fstab > /dev/null

# Step 6: Verify the changes
echo "The disk has been successfully partitioned, formatted, and mounted."
echo "You can verify the mounted disk with 'df -h'."

df -h
