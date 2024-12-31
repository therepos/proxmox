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

# Step 0: Verify or create the storage pool
echo "Checking if storage pool 'dpool' exists..."
pvesm list dpool > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Storage pool 'dpool' does not exist. Creating 'dpool'..."
    pvesm create dir dpool --path /mnt/pve/dpool
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to create storage pool 'dpool'. Exiting.${RESET}"
        exit 1
    fi
    echo -e "${GREEN}Storage pool 'dpool' created successfully.${RESET}"
else
    echo -e "${GREEN}Storage pool 'dpool' exists.${RESET}"
fi

# Step 1: Dynamically determine the next available VMID
echo "Determining the next available VMID..."
VMID=$(pvesh get /cluster/nextid)
if [ -z "$VMID" ]; then
    echo "Failed to get the next available VMID. Exiting."
    exit 1
fi
echo "Next available VMID: $VMID"

# Define VM Name, Cloud-init Image, and other variables
VM_NAME="docker-vm"
STORAGE_POOL="dpool"    # Using dpool as the storage pool (ensure dpool exists)
CLOUD_IMAGE="ubuntu-22.04-cloudimg.img"  # Cloud-init image filename
BRIDGE="vmbr0"          # Network bridge
GPU_PCI="01:00.0"       # GPU PCI ID for passthrough (adjust accordingly)

# Function to check for errors
function check_success() {
    if [ $? -ne 0 ]; then
        echo -e "\e[31m✘ $1 failed. Exiting.\e[0m"
        exit 1
    else
        echo -e "\e[32m✔ $1 successful.\e[0m"
    fi
}

# Step 2: Download the Cloud-Init Image if it doesn't exist
echo "Checking for the cloud-init image..."
if [ ! -f /var/lib/vz/template/iso/$CLOUD_IMAGE ]; then
    echo "Cloud-init image not found. Downloading the image..."
    wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img -O /var/lib/vz/template/iso/$CLOUD_IMAGE
    check_success "Cloud-init image download"
else
    echo "Cloud-init image already exists."
fi

# Step 3: Create the VM
echo "Creating VM with ID $VMID..."
qm create $VMID --name $VM_NAME --memory 4096 --cores 4 --net0 virtio,bridge=$BRIDGE --ostype l26
check_success "VM creation"

# Step 4: Import the cloud-init image
echo "Importing cloud-init image..."
qm importdisk $VMID /var/lib/vz/template/iso/$CLOUD_IMAGE $STORAGE_POOL
check_success "Cloud-init image import"

# Step 5: Attach the disk to the VM
echo "Attaching disk to VM..."
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STORAGE_POOL:vm-$VMID-disk-0
qm set $VMID --boot c --bootdisk scsi0
check_success "Disk attachment"

# Step 6: Configure Cloud-Init
echo "Configuring cloud-init..."
qm set $VMID --ide2 $STORAGE_POOL:cloudinit
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --cipassword "root" --ciuser "root"
check_success "Cloud-init configuration"

# Step 7: Add GPU Passthrough
echo "Configuring GPU passthrough..."
qm set $VMID --hostpci0 $GPU_PCI,pcie=1
check_success "GPU passthrough configuration"

# Step 8: Start the VM
echo "Starting VM $VMID..."
qm start $VMID
check_success "VM start"

# Step 9: Install Docker and NVIDIA Toolkit inside the VM
echo "Installing Docker and NVIDIA Toolkit inside the VM..."
ssh -o "StrictHostKeyChecking=no" youruser@<VM_IP> << 'EOF'
    # Update system
    apt-get update -y && apt-get upgrade -y

    # Install Docker prerequisites
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

    # Add Docker GPG key and repository
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list

    # Install Docker
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable --now docker

    # Add NVIDIA Container Toolkit repository
    distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-docker-keyring.gpg
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
    apt-get update -y

    # Install NVIDIA Container Toolkit
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker

    # Verify GPU access in Docker
    docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu20.04 nvidia-smi
EOF
check_success "Docker and NVIDIA Toolkit installation"

echo -e "\e[32m✔ VM created and configured successfully with Docker and NVIDIA GPU integration.\e[0m"
