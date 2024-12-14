#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash

# Function to print status with green or red check marks
print_status() {
    if [ "$1" == "success" ]; then
        echo -e "\033[0;32m✔\033[0m $2"  # Green check mark
    else
        echo -e "\033[0;31m✘\033[0m $2"  # Red cross mark
    fi
}

# Update system packages
print_status "success" "Updating system packages"
apt-get update -y

# Install necessary dependencies for Docker and ZFS
print_status "success" "Installing dependencies for Docker and ZFS"
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release zfsutils-linux

# Add Docker’s official GPG key
print_status "success" "Adding Docker GPG key"
curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -

# Set up the Docker stable repository
print_status "success" "Setting up Docker repository"
echo "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index again after adding Docker repository
print_status "success" "Updating package index"
apt-get update -y

# Install Docker CE (Community Edition)
print_status "success" "Installing Docker"
apt-get install -y docker-ce docker-ce-cli containerd.io

# Verify Docker installation
docker --version && print_status "success" "Docker installed successfully"

# Configure Docker to use ZFS as the storage driver
print_status "success" "Configuring Docker to use ZFS as storage driver"
echo '{
  "storage-driver": "zfs"
}' > /etc/docker/daemon.json

# Restart Docker service
print_status "success" "Restarting Docker service"
systemctl restart docker

# Verify Docker is using ZFS storage driver
if docker info | grep -q "Storage Driver: zfs"; then
    print_status "success" "Docker is using ZFS storage driver"
else
    print_status "failure" "Docker is not using ZFS storage driver"
fi

# Final completion message
print_status "success" "Docker and ZFS setup complete!"
