#!/bin/bash

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

# Step 0: Select the storage pool
echo "Available storage pools:"
pvesm status | awk 'NR > 1 {print $1}' | nl

read -p "Enter the number corresponding to the storage pool to use: " STORAGE_POOL_INDEX

STORAGE_POOL=$(pvesm status | awk 'NR > 1 {print $1}' | sed -n "${STORAGE_POOL_INDEX}p")
if [ -z "$STORAGE_POOL" ]; then
    echo -e "${RED}Invalid selection. Exiting.${RESET}"
    exit 1
fi
echo "Selected storage pool: $STORAGE_POOL"

# Step 1: Dynamically determine the next available VMID
echo "Determining the next available VMID..."
VMID=$(pvesh get /cluster/nextid)
if [ -z "$VMID" ]; then
    echo -e "${RED}Failed to get the next available VMID. Exiting.${RESET}"
    exit 1
fi
echo "Next available VMID: $VMID"

# Step 2: Verify or create the storage pool
echo "Checking if storage pool '$STORAGE_POOL' exists..."
pvesm list $STORAGE_POOL > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Storage pool '$STORAGE_POOL' does not exist. Creating '$STORAGE_POOL'..."
    pvesm create dir $STORAGE_POOL --path /mnt/pve/$STORAGE_POOL
    [ $? -eq 0 ] && echo -e "${GREEN}Storage pool created successfully.${RESET}" || exit 1
else
    echo -e "${GREEN}Storage pool exists.${RESET}"
fi

# Step 3: Download the Cloud-Init Image if it doesn't exist
CLOUD_IMAGE="ubuntu-22.04-cloudimg.img"
echo "Checking for the cloud-init image..."
if [ ! -f /var/lib/vz/template/iso/$CLOUD_IMAGE ]; then
    echo "Cloud-init image not found. Downloading..."
    wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img -O /var/lib/vz/template/iso/$CLOUD_IMAGE
    status_message $? "Cloud-init image downloaded"
else
    echo "Cloud-init image already exists."
fi

# Step 4: Create the VM
VM_NAME="docker-vm"
BRIDGE="vmbr0"
echo "Creating VM with ID $VMID..."
qm create $VMID --name $VM_NAME --memory 4096 --cores 4 --net0 virtio,bridge=$BRIDGE --ostype l26 --machine q35 --bios ovmf
status_message $? "VM created"

# Step 5: Configure EFI vars disk and attach storage
qm set $VMID --efidisk0 $STORAGE_POOL:128K,efitype=4m,size=128K
qm importdisk $VMID /var/lib/vz/template/iso/$CLOUD_IMAGE $STORAGE_POOL
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-$VMID-disk-0 --boot c --bootdisk scsi0
qm set $VMID --ide2 $STORAGE_POOL:cloudinit
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --cipassword "root" --ciuser "root"
status_message $? "Disk and cloud-init configured"

echo -e "${GREEN}Docker environment setup complete.${RESET}"
