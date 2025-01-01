#!/bin/bash

# Variables
STORAGE_POOL="local-zfs"  # Adjust as per your storage configuration
ISO_STORAGE="local"      # Storage where the ISO is stored
ISO_FILE="debian.iso" # Replace with your actual ISO file name
CPU_CORES=2
MEMORY=2048 # Memory in MB
DISK_SIZE=20G # Disk size in GB
BRIDGE="vmbr0" # Network bridge

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
    --cdrom $ISO_STORAGE:iso/$ISO_FILE

# Set boot order to CD-ROM
echo "Configuring boot order..."
qm set $NEXT_ID --boot order=cdrom

# Start the VM
echo "Starting VM $NEXT_ID..."
qm start $NEXT_ID

echo "VM $NEXT_ID has been created and started successfully."
