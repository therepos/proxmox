#!/bin/bash

# Set VM name
VMNAME="docker-vm"

# Set disk size (adjust as needed)
DISK_SIZE=32G

# Automatically determine the next available VMID
NEXT_VMID=$(qm list | awk '{print $1}' | sort -n | tail -1)
VMID=$((NEXT_VMID+1))

# Create VM
qm create $VMID \
  --name $VMNAME \
  --ostype l26 \
  --memory 4096 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --onboot 1 \
  --disk0 tank:vm-$VMID-disk-0,size=$DISK_SIZE

# Install cloud-init
qm set $VMID --ide2 tank:cloudinit,media=cdrom

# Start VM
qm start $VMID

# Wait for VM to boot
sleep 30

# Get VM IP address
VMIP=$(qm agent $VMID get-status | grep -oE '"ip-address": "[0-9.]+"' | cut -d '"' -f 4)

# SSH into VM and install Docker
ssh root@$VMIP << EOF
apt-get update
apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo \
  "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

# Add user to docker group (optional)
usermod -aG docker \$USER

# Verify Docker installation
docker run hello-world
EOF

# Remove cloud-init drive
qm set $VMID --ide2 none

echo "VM created with ID: $VMID"
echo "Docker installed on VM with IP: $VMIP"
