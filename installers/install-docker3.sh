#!/bin/bash

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

echo "v6"

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

function check_success() {
    if [ $? -ne 0 ]; then
        echo -e "${RED}$1 failed. Exiting.${RESET}"
        exit 1
    else
        echo -e "${GREEN}$1 completed successfully.${RESET}"
    fi
}

# Step 0: Select the storage pool
while true; do
    echo "Available storage pools:"
    pvesm status | awk 'NR > 1 {print NR-1 ") " $1}' | nl

    read -p "Enter the number corresponding to the storage pool to use: " STORAGE_POOL_INDEX

    STORAGE_POOL=$(pvesm status | awk 'NR > 1 {print $1}' | sed -n "${STORAGE_POOL_INDEX}p")
    if [ -n "$STORAGE_POOL" ]; then
        echo "Selected storage pool: $STORAGE_POOL"
        break
    else
        echo -e "${RED}Invalid selection. Please try again.${RESET}"
    fi
done

# Step 1: Verify IOMMU is enabled
echo "Verifying IOMMU is enabled..."
if ! dmesg | grep -e DMAR -e IOMMU; then
    echo "IOMMU is not enabled. Checking GRUB configuration..."
    if ! grep -q "intel_iommu=on" /etc/default/grub && ! grep -q "amd_iommu=on" /etc/default/grub; then
        echo "Adding IOMMU settings to GRUB..."
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&intel_iommu=on amd_iommu=on /' /etc/default/grub
        update-grub
        echo -e "${RED}IOMMU settings updated. Please reboot the system to apply changes.${RESET}"
        exit 0
    else
        echo -e "${GREEN}IOMMU settings already present in GRUB.${RESET}"
    fi
else
    echo -e "${GREEN}IOMMU is already enabled.${RESET}"
fi

# Step 2: Bind GPU to VFIO
echo "Binding GPU to VFIO..."

# Ensure VFIO kernel modules are loaded at boot
if ! grep -q "vfio" /etc/modules; then
    echo "Adding VFIO modules to /etc/modules..."
    echo -e "vfio\nvfio_pci\nvfio_iommu_type1" >> /etc/modules
    update-initramfs -u
    echo -e "${GREEN}VFIO kernel modules configured to load at boot.${RESET}"
else
    echo -e "${GREEN}VFIO kernel modules already configured.${RESET}"
fi

# Configure VFIO binding for GPU
if ! grep -q "options vfio-pci ids=10de:2571,10de:228e" /etc/modprobe.d/vfio.conf; then
    echo "Adding VFIO binding to /etc/modprobe.d/vfio.conf..."
    echo "options vfio-pci ids=10de:2571,10de:228e" > /etc/modprobe.d/vfio.conf
    update-initramfs -u
    echo -e "${GREEN}VFIO binding configuration updated.${RESET}"
else
    echo -e "${GREEN}VFIO binding configuration already exists.${RESET}"
fi

# Create systemd service for GPU driver override
VFIO_SERVICE="/etc/systemd/system/vfio-bind.service"
if [ ! -f "$VFIO_SERVICE" ]; then
    echo "Creating vfio-bind.service for GPU driver override..."
    cat <<EOF > "$VFIO_SERVICE"
[Unit]
Description=Bind GPU to vfio-pci
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo "vfio-pci" > /sys/bus/pci/devices/0000:01:00.0/driver_override && echo "vfio-pci" > /sys/bus/pci/devices/0000:01:00.1/driver_override && modprobe -i vfio-pci'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Enable the service
    systemctl daemon-reload
    systemctl enable vfio-bind.service
    echo -e "${GREEN}vfio-bind.service created and enabled.${RESET}"
else
    echo -e "${GREEN}vfio-bind.service already exists.${RESET}"
fi

# Verify GPU binding
if ! lspci -k | grep -A 2 "10de:2571" | grep -q "vfio-pci"; then
    echo -e "${RED}GPU is not yet bound to VFIO. Please reboot to apply changes.${RESET}"
    exit 0
else
    echo -e "${GREEN}GPU is successfully bound to VFIO.${RESET}"
fi

# Step 3: Dynamically determine the next available VMID
echo "Determining the next available VMID..."
VMID=$(pvesh get /cluster/nextid)
if [ -z "$VMID" ]; then
    echo -e "${RED}Failed to get the next available VMID. Exiting.${RESET}"
    exit 1
fi
echo "Next available VMID: $VMID"

# Step 4: Verify or create the storage pool
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

# Step 5: Download the Cloud-Init Image if it doesn't exist
CLOUD_IMAGE="ubuntu-22.04-cloudimg.img"
CLOUD_IMAGE_PATH="/var/lib/vz/template/iso/$CLOUD_IMAGE"
echo "Checking for the cloud-init image..."
if [ ! -f $CLOUD_IMAGE_PATH ]; then
    echo "Cloud-init image not found. Downloading the image..."
    wget --tries=3 --timeout=30 https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img -O $CLOUD_IMAGE_PATH
    check_success "Cloud-init image download"
else
    echo "Cloud-init image already exists."
fi

# Step 6: Create the VM
VM_NAME="docker-vm"
BRIDGE="vmbr0"
GPU_PCI="01:00.0"
echo "Creating VM with ID $VMID..."
qm create $VMID --name $VM_NAME --memory 4096 --cores 4 --net0 virtio,bridge=$BRIDGE --ostype l26 --machine q35 --bios ovmf
check_success "VM creation"

# Step 7: Configure EFI vars disk
echo "Configuring EFI vars disk..."
qm set $VMID --efidisk0 $STORAGE_POOL:128K,efitype=4m,size=128K
check_success "EFI vars disk configuration"

# Step 8: Import the cloud-init image
echo "Importing cloud-init image..."
qm importdisk $VMID /var/lib/vz/template/iso/$CLOUD_IMAGE $STORAGE_POOL
check_success "Cloud-init image import"

# Step 9: Attach the disk to the VM
echo "Attaching disk to VM..."
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-$VMID-disk-0 --boot c --bootdisk scsi0
check_success "Disk attachment"

# Step 10: Configure Cloud-Init
echo "Configuring cloud-init..."
qm set $VMID --ide2 $STORAGE_POOL:cloudinit
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --cipassword "root" --ciuser "root"
check_success "Cloud-init configuration"

# Step 11: Add GPU Passthrough
echo "Configuring GPU passthrough..."
qm set $VMID --hostpci0 $GPU_PCI,pcie=1
check_success "GPU passthrough configuration"

# Verify GPU passthrough inside the VM
echo "Validating GPU passthrough..."
if ! qm config $VMID | grep -q "hostpci0"; then
    echo -e "${RED}GPU passthrough configuration failed. Exiting.${RESET}"
    exit 1
fi

# Step 12: Start the VM
echo "Starting VM $VMID..."
qm start $VMID
check_success "VM start"

echo -e "${GREEN}VM created and configured successfully with GPU passthrough and Docker support.${RESET}"
