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
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common zfsutils-linux

# Add Docker GPG key
print_status "Adding Docker GPG key"
if curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
    print_status "Docker GPG key added successfully"
else
    print_error "Failed to add Docker GPG key"
    exit 1
fi

# Add Docker repository (use Bullseye for compatibility with Debian Bookworm)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bullseye stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists and install Docker
print_status "Updating package lists and installing Docker"
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# Configure Docker for NVIDIA and ZFS compatibility
print_status "Configuring Docker for NVIDIA and ZFS compatibility"

# Create Docker daemon configuration file if it doesn't exist
DOCKER_CONFIG="/etc/docker/daemon.json"
if [ ! -f "$DOCKER_CONFIG" ]; then
    sudo tee "$DOCKER_CONFIG" > /dev/null <<EOF
{
    "storage-driver": "zfs",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF
else
    print_status "Updating existing Docker configuration"
    sudo jq '. + {"storage-driver": "zfs", "runtimes": {"nvidia": {"path": "nvidia-container-runtime", "runtimeArgs": []}}}' "$DOCKER_CONFIG" > /tmp/daemon.json
    sudo mv /tmp/daemon.json "$DOCKER_CONFIG"
fi

# Restart Docker
print_status "Restarting Docker"
sudo systemctl restart docker

# Verify installation
print_status "Verifying Docker installation"
if docker --version && docker info | grep -q "Storage Driver: zfs"; then
    print_status "Docker installed and configured successfully"
else
    print_error "Docker installation or configuration failed"
    exit 1
fi

# Optional: Test NVIDIA runtime
print_status "Testing NVIDIA runtime with Docker"
if docker run --rm --runtime=nvidia nvidia/cuda:11.0-base nvidia-smi; then
    print_status "NVIDIA runtime test passed"
else
    print_error "NVIDIA runtime test failed"
    exit 1
fi

print_status "Docker setup complete"
