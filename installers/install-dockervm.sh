#!/bin/bash

# Script to create a Docker VM on Proxmox with GPU passthrough compatibility

# Exit on error
set -e

# Variables
ISO_STORAGE="local"       # Storage where the ISO is stored
ISO_DIR="/var/lib/vz/template/iso"  # Directory for ISO storage

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

# Function to get the next available VMID
get_next_vmid() {
  local current_max=$(pvesh get /cluster/resources --type vm | jq -r '.[] | .vmid' | sort -n | tail -1)
  echo $((current_max + 1))
}

# Detect or download ISO
ISO_FILE=$(find_or_download_iso)

# Variables
VMID=$(get_next_vmid)
NAME="docker-vm"  # Set a name for the VM
MEMORY=4096  # 4GB of RAM
CORES=4  # 4 CPU cores
DISK_SIZE=32G  # Disk size for the VM
BRIDGE="vmbr0"  # Network bridge name

# Create the VM
qm create $VMID \
  --name $NAME \
  --memory $MEMORY \
  --cores $CORES \
  --net0 virtio,bridge=$BRIDGE \
  --ostype l26 \
  --scsihw virtio-scsi-pci \
  --scsi0 $ISO_STORAGE:$VMID,format=qcow2,size=$DISK_SIZE \
  --ide2 $ISO_STORAGE:iso/$(basename $ISO_FILE),media=cdrom \
  --boot c \
  --bootdisk scsi0 \
  --machine q35 \
  --cpu host

# Configure for GPU passthrough
qm set $VMID --hostpci0 0000:00:00.0,pcie=1  # Placeholder for GPU passthrough

# Add additional configurations for Docker compatibility
qm set $VMID --numa 1
qm set $VMID --balloon 0  # Disable memory ballooning for consistent performance

# Print completion message
echo "VM $NAME with VMID $VMID created successfully."
echo "You can start the VM with: qm start $VMID"
