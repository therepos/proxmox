#!/bin/bash

# Function to display status indicators
display_status() {
    local status=$1
    local message=$2

    if [ "$status" -eq 0 ]; then
        echo -e "\e[32m\u2714 $message\e[0m" # Green checkmark
    else
        echo -e "\e[31m\u274C $message\e[0m" # Red cross
        exit 1
    fi
}

# Detect Proxmox host
PROXMOX_HOST=$(hostname -I | awk '{print $1}')
if [ -z "$PROXMOX_HOST" ]; then
    display_status 1 "Failed to detect Proxmox host IP. Ensure the script is running on a Proxmox server."
else
    display_status 0 "Proxmox host detected: $PROXMOX_HOST"
fi

# Fetch the next available VM ID
VM_ID=$(pvesh get /cluster/nextid)
if [ -z "$VM_ID" ]; then
    display_status 1 "Failed to fetch the next available VM ID."
else
    display_status 0 "Next available VM ID: $VM_ID"
fi

# Configuration variables
VM_NAME="docker-vm"
STORAGE="local-lvm"
ISO_NAME="debian.iso" # ISO name to search for
ISO_PATH=$(pvesm list local --content iso | awk -v iso="$ISO_NAME" '$2 == iso {print "local:"$2}')
MEMORY="2048"                 # RAM in MB
CORES="2"                     # Number of CPU cores
DISK_SIZE="32G"               # Disk size
BRIDGE="vmbr0"                # Network bridge

# Check if ISO path exists
if [ -z "$ISO_PATH" ]; then
    echo -e "\nISO file $ISO_NAME does not exist in storage. Downloading..."
    wget -O /var/lib/vz/template/iso/$ISO_NAME https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$ISO_NAME
    if [ $? -eq 0 ]; then
        display_status 0 "ISO file downloaded successfully: $ISO_NAME"
        ISO_PATH="local:iso/$ISO_NAME"
    else
        display_status 1 "Failed to download the ISO file."
    fi
else
    display_status 0 "ISO file found: $ISO_PATH"
fi

# Step 1: Create the VM in Proxmox
echo -e "\nCreating VM in Proxmox..."
qm create $VM_ID --name $VM_NAME --memory $MEMORY --cores $CORES --net0 virtio,bridge=$BRIDGE
status=$?
display_status $status "VM configuration created"

qm set $VM_ID --ide2 $ISO_PATH,media=cdrom
status=$?
display_status $status "ISO attached"

qm set $VM_ID --scsihw virtio-scsi-pci --scsi0 $STORAGE:$DISK_SIZE
status=$?
display_status $status "Disk configured"

qm set $VM_ID --boot c --bootdisk scsi0 --agent enabled=1
status=$?
display_status $status "Boot and agent settings configured"

qm start $VM_ID
status=$?
display_status $status "VM started"

# Step 2: Wait for VM initialization
echo -e "\nWaiting for VM initialization..."
sleep 60 # Adjust based on expected VM boot time

# Step 3: SSH into the VM and install Docker
echo -e "\nInstalling Docker inside the VM..."
ssh root@$VM_NAME << 'EOF'
# Inside the VM
# Function to display status inside the VM
status_indicator() {
    if [ $1 -eq 0 ]; then
        echo -e "\e[32m\u2714 $2\e[0m" # Green checkmark
    else
        echo -e "\e[31m\u274C $3\e[0m" # Red cross
        exit 1
    fi
}

# Remove conflicting packages
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do 
    apt-get remove -y $pkg
    status_indicator $? "Removed $pkg" "Failed to remove $pkg"
done

# Update system and install prerequisites
apt-get update
status_indicator $? "System updated" "Failed to update system"

apt-get install -y ca-certificates curl
status_indicator $? "Installed prerequisites" "Failed to install prerequisites"

# Add Docker GPG key and repository
install -m 0755 -d /etc/apt/keyrings
status_indicator $? "Directory for keyrings created" "Failed to create keyrings directory"

curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
status_indicator $? "GPG key downloaded" "Failed to download GPG key"

chmod a+r /etc/apt/keyrings/docker.asc
status_indicator $? "GPG key permissions set" "Failed to set GPG key permissions"

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null
status_indicator $? "Docker repository added" "Failed to add Docker repository"

apt-get update
status_indicator $? "Package index updated" "Failed to update package index"

apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
status_indicator $? "Docker installed" "Failed to install Docker"

# Test Docker installation
docker run hello-world
status_indicator $? "Docker is running successfully" "Docker test failed"
EOF
status=$?
display_status $status "Docker installed and tested inside VM"

echo -e "\nScript completed!"
