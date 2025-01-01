#!/bin/bash

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# Enable debugging to show all executed commands
set -x

# Step 1: Select the storage pool
echo "Available storage pools:"
pvesm status | awk 'NR > 1 {print $1}' | nl

read -p "Enter the number corresponding to the storage pool to use: " STORAGE_POOL_INDEX

STORAGE_POOL=$(pvesm status | awk 'NR > 1 {print $1}' | sed -n "${STORAGE_POOL_INDEX}p")
if [ -z "$STORAGE_POOL" ]; then
    echo -e "${RED}Invalid selection. Exiting.${RESET}"
    exit 1
fi
echo "Selected storage pool: $STORAGE_POOL"

# Step 2: Dynamically determine the next available VMID
echo "Determining the next available VMID..."
VMID=$(pvesh get /cluster/nextid)
if [ -z "$VMID" ]; then
    echo -e "${RED}Failed to get the next available VMID. Exiting.${RESET}"
    exit 1
fi
echo "Next available VMID: $VMID"

# Step 3: Verify or create the storage pool
echo "Checking if storage pool '$STORAGE_POOL' exists..."
pvesm list $STORAGE_POOL
if [ $? -ne 0 ]; then
    echo "Storage pool '$STORAGE_POOL' does not exist. Creating '$STORAGE_POOL'..."
    pvesm create dir $STORAGE_POOL --path /mnt/pve/$STORAGE_POOL
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to create storage pool '$STORAGE_POOL'. Exiting.${RESET}"
        exit 1
    fi
    echo -e "${GREEN}Storage pool '$STORAGE_POOL' created successfully.${RESET}"
else
    echo -e "${GREEN}Storage pool '$STORAGE_POOL' exists.${RESET}"
fi

# Step 4: Download the Cloud-Init Image if it doesn't exist
CLOUD_IMAGE="/var/lib/vz/template/iso/ubuntu-22.04-cloudimg.img"
echo "Checking for the cloud-init image..."
if [ ! -f "$CLOUD_IMAGE" ]; then
    echo "Cloud-init image not found. Downloading the image..."
    wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img -O "$CLOUD_IMAGE"
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to download the cloud-init image. Exiting.${RESET}"
        exit 1
    fi
    echo -e "${GREEN}Cloud-init image downloaded successfully.${RESET}"
else
    echo -e "${GREEN}Cloud-init image already exists.${RESET}"
fi

# Step 5: Create the VM
echo "Creating VM with ID $VMID..."
qm create $VMID --name docker-vm --memory 4096 --cores 4 --net0 virtio,bridge=vmbr0 --ostype l26 --machine q35 --bios ovmf
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to create VM $VMID. Exiting.${RESET}"
    exit 1
else
    echo -e "${GREEN}VM $VMID successfully created.${RESET}"
fi

# Step 6: Configure EFI vars disk and attach storage
echo "Configuring EFI vars disk and cloud-init settings for VM $VMID..."

# Step 6.1: Configure EFI vars disk
echo "Configuring EFI vars disk..."
qm set $VMID --efidisk0 "$STORAGE_POOL:128K,efitype=4m,size=128K"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to configure EFI vars disk. Exiting.${RESET}"
    exit 1
else
    echo -e "${GREEN}EFI vars disk configured.${RESET}"
fi

# Step 6.2: Import Cloud-Init Image
echo "Importing Cloud-Init Image..."
qm importdisk $VMID "$CLOUD_IMAGE" $STORAGE_POOL
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to import cloud-init image. Exiting.${RESET}"
    exit 1
else
    echo -e "${GREEN}Cloud-init image imported successfully.${RESET}"
fi

# Step 6.3: Attach the disk to VM
echo "Attaching the disk to VM..."
qm set $VMID --scsihw virtio-scsi-pci --scsi0 "$STORAGE_POOL:vm-$VMID-disk-0" --boot c --bootdisk scsi0
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to attach disk to VM. Exiting.${RESET}"
    exit 1
else
    echo -e "${GREEN}Disk attached to VM.${RESET}"
fi

# Step 6.4: Configure Cloud-Init
echo "Configuring Cloud-Init..."
qm set $VMID --ide2 "$STORAGE_POOL:cloudinit" --serial0 socket --vga serial0 --cipassword "root" --ciuser "root"
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to configure cloud-init. Exiting.${RESET}"
    exit 1
else
    echo -e "${GREEN}Cloud-init configured successfully.${RESET}"
fi

# Step 7: Start the VM
echo "Starting VM $VMID..."
qm start $VMID
if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to start VM $VMID. Exiting.${RESET}"
    exit 1
else
    echo -e "${GREEN}VM $VMID started successfully.${RESET}"
fi

echo -e "${GREEN}VM created and configured successfully with cloud-init and Docker support.${RESET}"

# Disable debugging after execution
set +x
