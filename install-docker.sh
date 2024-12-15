#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash

# Error detection: halt script on any error
set -e

# Function to print status messages
print_status() {
    echo -e "\033[0;32m✔\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m✘\033[0m $1"
}

# Update system and install prerequisites
print_status "Updating system and installing prerequisites"
sudo apt update
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common zfsutils-linux gnupg lsb-release

# Add Docker's official GPG key (overwrite if it exists)
print_status "Adding Docker GPG key"
if curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg; then
    print_status "Docker GPG key added successfully"
else
    print_error "Failed to add Docker GPG key"
    exit 1
fi

# Add Docker repository (use Bullseye for Debian Bookworm compatibility)
print_status "Adding Docker repository"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bullseye stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists and install Docker
print_status "Updating package lists and installing Docker"
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# Fix networking warnings (enable bridge-nf-call-iptables and bridge-nf-call-ip6tables)
print_status "Fixing networking warnings for Docker"
sudo modprobe br_netfilter
echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf > /dev/null
sudo tee /etc/sysctl.d/99-docker.conf > /dev/null <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sudo sysctl --system

# Configure Docker for ZFS storage driver
print_status "Configuring Docker for ZFS storage driver"
DOCKER_CONFIG="/etc/docker/daemon.json"
if [ ! -f "$DOCKER_CONFIG" ]; then
    sudo tee "$DOCKER_CONFIG" > /dev/null <<EOF
{
    "storage-driver": "zfs"
}
EOF
else
    print_status "Updating existing Docker configuration for ZFS"
    sudo jq '. + {"storage-driver": "zfs"}' "$DOCKER_CONFIG" > /tmp/daemon.json
    sudo mv /tmp/daemon.json "$DOCKER_CONFIG"
fi

# Restart Docker
print_status "Restarting Docker service"
sudo systemctl restart docker

# Verify Docker installation
print_status "Verifying Docker installation"
if docker --version && docker info | grep -q "Storage Driver: zfs"; then
    print_status "Docker installed and configured successfully"
else
    print_error "Docker installation or configuration failed"
    exit 1
fi

# Optional: Test Docker with a sample container
print_status "Testing Docker with a simple container"
if docker run --rm hello-world; then
    print_status "Docker test container ran successfully"
else
    print_error "Docker test container failed to run"
    exit 1
fi

print_status "Docker installation and configuration completed successfully"
