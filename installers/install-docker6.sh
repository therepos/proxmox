#!/bin/bash

# Variables
STORAGE_POOL="local-zfs"  # Adjust as per your storage configuration
ISO_STORAGE="local"       # Storage where the ISO is stored
ISO_DIR="/var/lib/vz/template/iso"  # Directory for ISO storage
CPU_CORES=2
MEMORY=2048               # Memory in MB
DISK_SIZE=20G             # Disk size in GB
BRIDGE="vmbr0"            # Network bridge
BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

# Function to download the latest Debian ISO
download_latest_iso() {
    echo "Fetching the latest Debian ISO file..."
    LATEST_ISO=$(curl -s $BASE_URL/ | grep -oP 'href="debian-\d+\.\d+\.\d+-amd64-netinst\.iso"' | cut -d'"' -f2 | sort -V | tail -n 1)

    if [ -z "$LATEST_ISO" ]; then
        echo "Error: Unable to fetch the latest Debian ISO file."
        exit 1
    fi

    ISO_URL="$BASE_URL/$LATEST_ISO"
    OUTPUT_FILE="$ISO_DIR/$LATEST_ISO"

    echo "Downloading $ISO_URL to $OUTPUT_FILE..."
    curl -o "$OUTPUT_FILE" "$ISO_URL"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to download the Debian ISO."
        exit 1
    fi

    echo "Debian ISO downloaded successfully."
}

# Function to detect the latest local Debian ISO
find_local_iso() {
    echo "Searching for a local Debian ISO file..."
    LOCAL_ISO=$(find "$ISO_DIR" -type f -name "debian-*.iso" -size +0c | sort | tail -n 1)

    if [ -z "$LOCAL_ISO" ]; then
        echo "No valid local Debian ISO file found."
        download_latest_iso
        LOCAL_ISO=$(find "$ISO_DIR" -type f -name "debian-*.iso" -size +0c | sort | tail -n 1)
    fi

    if [ -z "$LOCAL_ISO" ]; then
        echo "Error: Unable to find or download a valid Debian ISO file."
        exit 1
    fi

    echo "Using local Debian ISO: $LOCAL_ISO"
}

# Detect the latest local ISO
find_local_iso

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
qm set $NEXT_ID \
    --scsi0 $STORAGE_POOL:vm-$NEXT_ID-disk-0,size=$DISK_SIZE

# Attach ISO file for installation
qm set $NEXT_ID \
    --cdrom "local:iso/$(basename $LOCAL_ISO)"

# Set boot order to CD-ROM
echo "Configuring boot order..."
qm set $NEXT_ID --boot order=cdrom

# Start the VM
echo "Starting VM $NEXT_ID..."
qm start $NEXT_ID

echo "VM $NEXT_ID has been created and started successfully."
