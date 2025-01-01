#!/bin/bash

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

function status_message() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN} $1 succeeded.${RESET}"
    else
        echo -e "${RED} $1 failed. Exiting.${RESET}"
        exit 1
    fi
}

# Step 1: Verify Storage Pool
STORAGE_POOL="local"
echo "Checking if storage pool '$STORAGE_POOL' exists..."
pvesm list $STORAGE_POOL > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${RED}Storage pool '$STORAGE_POOL' does not exist. Exiting.${RESET}"
    exit 1
else
    echo -e "${GREEN}Storage pool '$STORAGE_POOL' verified.${RESET}"
fi

# Step 2: Dynamically Determine VM ID
echo "Determining the next available VM ID..."
VMID=$(pvesh get /cluster/nextid)
if [ -z "$VMID" ]; then
    echo -e "${RED}Failed to get the next available VM ID. Exiting.${RESET}"
    exit 1
fi
echo "Next available VM ID: $VMID"

# Step 3: Download Cloud-Init Image
CLOUD_IMAGE="/var/lib/vz/template/iso/ubuntu-22.04-cloudimg.img"
if [ ! -f "$CLOUD_IMAGE" ]; then
    echo "Cloud-init image not found. Downloading..."
    wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img -O "$CLOUD_IMAGE"
    status_message "Cloud-init image download"
else
    echo -e "${GREEN}Cloud-init image already exists.${RESET}"
fi

# Step 4: Create the VM
echo "Creating Docker VM with ID $VMID..."
qm create $VMID --name docker-vm --memory 4096 --cores 4 --net0 virtio,bridge=vmbr0 --ostype l26 --scsihw virtio-scsi-pci --bios ovmf
status_message "VM creation"

# Step 5: Import Cloud-Init Disk
echo "Importing Cloud-Init disk..."
qm importdisk $VMID "$CLOUD_IMAGE" $STORAGE_POOL
status_message "Cloud-init disk import"

# Step 6: Configure VM Disk and Cloud-Init
echo "Configuring VM disks and cloud-init..."
qm set $VMID --efidisk0 $STORAGE_POOL:vm-$VMID-efi,size=128K --scsi0 $STORAGE_POOL:vm-$VMID-disk-0,boot=1 --boot c
qm set $VMID --ide2 $STORAGE_POOL:cloudinit --serial0 socket --vga serial0 --cipassword "root" --ciuser "root"
status_message "VM configuration"

# Step 7: Start the VM
echo "Starting Docker VM with ID $VMID..."
qm start $VMID
status_message "VM start"

# Step 8: Install Docker Inside the VM
echo "To install Docker in the VM, follow these steps:"
echo "1. SSH into the VM using the IP address set during the cloud-init configuration."
echo "2. Run the following commands to install Docker:"
echo "
# Uninstall any conflicting packages
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove -y \$pkg; done

# Add Docker's official GPG key
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
echo 'deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable' | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Install Docker
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Verify Docker installation
sudo docker run hello-world
"
echo -e "${GREEN}Docker VM setup completed. Follow the instructions above to install Docker inside the VM.${RESET}"
