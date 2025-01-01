#!/bin/bash

# Variables
STORAGE_POOL="local-zfs"  # Adjust as per your storage configuration
ISO_STORAGE="local"       # Storage where the ISO is stored
ISO_DIR="/var/lib/vz/template/iso"  # Directory for ISO storage
CPU_CORES=2
MEMORY=2048               # Memory in MB
DISK_SIZE=20G             # Disk size in GB
BRIDGE="vmbr0"            # Network bridge

# Function to detect or download the latest ISO
find_or_download_iso() {
    echo "Searching for a local Debian ISO file..."
    local_iso=$(find "$ISO_DIR" -type f -name "debian-*.iso" -size +0c | sort | tail -n 1)

    if [ -z "$local_iso" ]; then
        echo "No valid local Debian ISO file found. Downloading the latest ISO..."
        local latest_iso_url
        latest_iso_url=$(curl -s https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | \
            grep -oP 'href="debian-\d+\.\d+\.\d+-amd64-netinst\.iso"' | cut -d'"' -f2 | sort -V | tail -n 1)
        curl -o "$ISO_DIR/$latest_iso_url" "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$latest_iso_url"
        local_iso="$ISO_DIR/$latest_iso_url"
    fi

    echo "Using local Debian ISO: $local_iso"
    echo "$local_iso"
}

# Detect or download ISO
ISO_FILE=$(find_or_download_iso)

# Detect next available VM ID
NEXT_ID=$(pvesh get /cluster/nextid)

# Create VM
echo "Creating VM with ID $NEXT_ID..."
qm create $NEXT_ID \
    --name vm-$NEXT_ID \
    --memory $MEMORY \
    --cores $CPU_CORES \
    --net0 virtio,bridge=$BRIDGE \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --sockets 1

# Add disk to the VM (skip waiting for Zvol device)
echo "Adding disk to VM $NEXT_ID..."
qm set $NEXT_ID \
    --scsi0 $STORAGE_POOL:vm-$NEXT_ID-disk-0,size=$DISK_SIZE

# Attach ISO file for installation
echo "Attaching ISO $ISO_FILE to VM $NEXT_ID..."
ISO_FILENAME=$(basename "$ISO_FILE")
qm set $NEXT_ID \
    --cdrom "$ISO_STORAGE:iso/$ISO_FILENAME"

# Set boot order
echo "Configuring boot order..."
qm set $NEXT_ID \
    --boot c --bootdisk scsi0

# Start the VM
echo "Starting VM $NEXT_ID..."
qm start $NEXT_ID

echo "VM $NEXT_ID has been created and started successfully."
