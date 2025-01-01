#!/bin/bash

# Variables
STORAGE_POOL="local-zfs"  # Adjust as per your storage configuration
ISO_STORAGE="local"       # Storage where the ISO is stored
ISO_DIR="/var/lib/vz/template/iso"  # Directory for ISO storage
CPU_CORES=2
MEMORY=2048               # Memory in MB
DISK_SIZE=20G             # Disk size in GB
BRIDGE="vmbr0"            # Network bridge

# Retry mechanism for Zvol creation
retry_zvol() {
    local vmid=$1
    local disk_path
    local retries=10

    while [ $retries -gt 0 ]; do
        disk_path=$(find /dev/zvol/$STORAGE_POOL -name "vm-$vmid-disk-0")
        if [ -n "$disk_path" ]; then
            return 0
        fi
        sleep 1
        retries=$((retries - 1))
    done
    echo "Error: Timeout waiting for Zvol device link."
    return 1
}

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

# Add disk to the VM
echo "Adding disk to VM $NEXT_ID..."
qm set $NEXT_ID \
    --scsi0 $STORAGE_POOL:vm-$NEXT_ID-disk-0,size=$DISK_SIZE

# Wait for Zvol device link
retry_zvol $NEXT_ID || exit 1

# Attach ISO file for installation
echo "Attaching ISO $ISO_FILE to VM $NEXT_ID..."
qm set $NEXT_ID \
    --cdrom "$ISO_STORAGE:iso/$(basename $ISO_FILE)"

# Set boot order
echo "Configuring boot order..."
qm set $NEXT_ID \
    --boot c --bootdisk scsi0

# Start the VM
echo "Starting VM $NEXT_ID..."
qm start $NEXT_ID

echo "VM $NEXT_ID has been created and started successfully."
