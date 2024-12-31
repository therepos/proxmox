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

# Step 0: Verify IOMMU is enabled
echo "Verifying IOMMU is enabled..."
if ! dmesg | grep -e DMAR -e IOMMU; then
    echo "IOMMU is not enabled. Adding to GRUB config..."
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&intel_iommu=on amd_iommu=on /' /etc/default/grub
    update-grub
    echo -e "${GREEN}IOMMU enabled. Reboot is required to apply settings.${RESET}"
    exit 0
fi
echo -e "${GREEN}IOMMU is already enabled.${RESET}"

# Step 1: Bind GPU to VFIO
echo "Binding GPU to VFIO..."
echo "options vfio-pci ids=10de:2571,10de:228e" > /etc/modprobe.d/vfio.conf
update-initramfs -u
echo -e "${GREEN}GPU bound to VFIO. Reboot is required to apply settings.${RESET}"

# Step 2: Dynamically determine the next available VMID
echo "Determining the next available VMID..."
VMID=$(pvesh get /cluster/nextid)
if [ -z "$VMID" ]; then
    echo "Failed to get the next available VMID. Exiting."
    exit 1
fi
echo "Next available VMID: $VMID"

# Define VM Name, Cloud-init Image, and other variables
VM_NAME="docker-vm"
STORAGE_POOL="dpool"
CLOUD_IMAGE="ubuntu-22.04-cloudimg.img"
BRIDGE="vmbr0"
GPU_PCI="01:00.0"

# Step 3: Verify or create the storage pool
echo "Checking if storage pool '$STORAGE_POOL' exists..."
pvesm list $STORAGE_POOL > /dev/null 2>&1
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
echo "Checking for the cloud-init image..."
if [ ! -f /var/lib/vz/template/iso/$CLOUD_IMAGE ]; then
    echo "Cloud-init image not found. Downloading the image..."
    wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img -O /var/lib/vz/template/iso/$CLOUD_IMAGE
    check_success "Cloud-init image download"
else
    echo "Cloud-init image already exists."
fi

# Step 5: Create the VM
echo "Creating VM with ID $VMID..."
qm create $VMID --name $VM_NAME --memory 4096 --cores 4 --net0 virtio,bridge=$BRIDGE --ostype l26 --machine q35 --bios ovmf
check_success "VM creation"

# Step 6: Configure EFI vars disk
echo "Configuring EFI vars disk..."
qm set $VMID --efidisk0 $STORAGE_POOL:128K,efitype=4m,size=128K
check_success "EFI vars disk configuration"

# Step 7: Import the cloud-init image
echo "Importing cloud-init image..."
qm importdisk $VMID /var/lib/vz/template/iso/$CLOUD_IMAGE $STORAGE_POOL
check_success "Cloud-init image import"

# Step 8: Attach the disk to the VM
echo "Attaching disk to VM..."
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-$VMID-disk-0 --boot c --bootdisk scsi0
check_success "Disk attachment"

# Step 9: Configure Cloud-Init
echo "Configuring cloud-init..."
qm set $VMID --ide2 $STORAGE_POOL:cloudinit
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --cipassword "root" --ciuser "root"
check_success "Cloud-init configuration"

# Step 10: Add GPU Passthrough
echo "Configuring GPU passthrough..."
qm set $VMID --hostpci0 $GPU_PCI,pcie=1
check_success "GPU passthrough configuration"

# Step 11: Start the VM
echo "Starting VM $VMID..."
qm start $VMID
check_success "VM start"

echo -e "${GREEN}VM created and configured successfully with GPU passthrough and Docker support.${RESET}"
