#!/bin/bash

# Set VM name
VMNAME="docker-vm"

# Set disk size (adjust as needed)
DISK_SIZE=32G

# Automatically determine the next available VMID
NEXT_VMID=$(qm list | awk -F',' '{print $1}' | sort -n | tail -1)
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
# Uninstall conflicting packages
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  apt-get remove -y \$pkg
done

# Update package lists
apt-get update

# Install necessary packages
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  \$(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists again
apt-get update

# Install Docker CE
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Verify Docker installation
docker run hello-world
EOF

# Remove cloud-init drive
qm set $VMID --ide2 none

echo "VM created with ID: $VMID"
echo "Docker installed on VM with IP: $VMIP"
