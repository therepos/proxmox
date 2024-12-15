#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash

LOG_FILE="install-docker.log"
exec > >(tee -a "$LOG_FILE") 2>&1

print_status() {
    if [ "$1" == "success" ]; then
        echo -e "\033[0;32m✔\033[0m $2"
    else
        echo -e "\033[0;31m✘\033[0m $2"
    fi
}

run_command() {
    echo "Running: $*"
    "$@"
    if [ $? -ne 0 ]; then
        print_status "failure" "Command failed: $*"
        exit 1
    fi
}

echo "========== Starting Docker and ZFS Installation =========="
date

# Update system packages
print_status "success" "Updating system packages"
run_command apt-get update -y

# Install necessary dependencies for Docker and ZFS
print_status "success" "Installing dependencies for Docker and ZFS"
run_command apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release zfsutils-linux

# Add Docker’s official GPG key and set up repository
print_status "success" "Adding Docker GPG key"
run_command curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

print_status "success" "Setting up Docker repository"
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index after adding Docker repository
print_status "success" "Updating package index"
run_command apt-get update -y

# Install Docker CE (Community Edition)
print_status "success" "Installing Docker"
run_command apt-get install -y docker-ce docker-ce-cli containerd.io

# Verify Docker installation
if command -v docker > /dev/null; then
    print_status "success" "Docker installed successfully"
else
    print_status "failure" "Docker installation failed"
    exit 1
fi

# Create /etc/docker directory if it doesn't exist
print_status "success" "Ensuring /etc/docker directory exists"
run_command mkdir -p /etc/docker

# Configure Docker to use ZFS as the storage driver
print_status "success" "Configuring Docker to use ZFS as storage driver"
echo '{
  "storage-driver": "zfs"
}' > /etc/docker/daemon.json

# Restart Docker service
print_status "success" "Restarting Docker service"
run_command systemctl restart docker

# Verify Docker is using ZFS storage driver
if docker info | grep -q "Storage Driver: zfs"; then
    print_status "success" "Docker is using ZFS storage driver"
else
    print_status "failure" "Docker is not using ZFS storage driver"
fi

print_status "success" "Docker and ZFS setup complete!"
echo "========== Installation Complete =========="
date
