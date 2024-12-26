#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/installers/install-docker.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/installers/install-docker.sh | bash

# Error detection: halt script on any error
set -e

# Function to print status messages
print_status() {
    echo -e "\033[0;32m✔\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m✘\033[0m $1"
}

# Function to run commands silently
run_silent() {
    "$@" > /dev/null 2>&1
}

# Update system and install prerequisites
print_status "Updating system and installing prerequisites"
run_silent apt update
run_silent apt install -y apt-transport-https ca-certificates curl software-properties-common zfsutils-linux gnupg lsb-release

# Remove existing Docker GPG key if it exists
if [ -f /usr/share/keyrings/docker-archive-keyring.gpg ]; then
    print_status "Removing existing Docker GPG key"
    rm /usr/share/keyrings/docker-archive-keyring.gpg
fi

# Add Docker GPG key
print_status "Adding Docker GPG key"
if curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
    print_status "Docker GPG key added successfully"
else
    print_error "Failed to add Docker GPG key"
    exit 1
fi

# Check if Docker repository exists, if not, add it
if ! grep -q "docker.com" /etc/apt/sources.list.d/docker.list; then
    print_status "Adding Docker repository"
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bullseye stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
else
    print_status "Docker repository already exists, skipping"
fi

# Add Docker repository (use Bullseye for Debian Bookworm compatibility)
print_status "Adding Docker repository"
run_silent echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bullseye stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package lists and install Docker
print_status "Updating package lists and installing Docker"
run_silent apt update
run_silent apt install -y docker-ce docker-ce-cli containerd.io

# Install NVIDIA Container Toolkit for GPU support
print_status "Installing NVIDIA Container Toolkit (runtime)"
run_silent apt install -y nvidia-container-runtime

# Configure Docker for ZFS storage driver and NVIDIA runtime
print_status "Configuring Docker for ZFS storage driver and NVIDIA runtime"
DOCKER_CONFIG="/etc/docker/daemon.json"
if [ ! -f "$DOCKER_CONFIG" ]; then
    run_silent tee "$DOCKER_CONFIG" > /dev/null <<EOF
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
    run_silent jq '. + {"storage-driver": "zfs", "runtimes": {"nvidia": {"path": "nvidia-container-runtime", "runtimeArgs": []}}}' "$DOCKER_CONFIG" > /tmp/daemon.json
    run_silent mv /tmp/daemon.json "$DOCKER_CONFIG"
fi

# Restart Docker
print_status "Restarting Docker service"
run_silent systemctl restart docker

# Verify Docker installation
print_status "Verifying Docker installation"
if docker --version > /dev/null && docker info | grep -q "Storage Driver: zfs"; then
    print_status "Docker installed and configured successfully"
else
    print_error "Docker installation or configuration failed"
    exit 1
fi

# Test NVIDIA Container Toolkit
print_status "Testing NVIDIA runtime with Docker"
if run_silent docker run --rm --runtime=nvidia nvidia/cuda:11.2-base nvidia-smi; then
    print_status "NVIDIA runtime test passed successfully"
else
    print_error "NVIDIA runtime test failed. Ensure NVIDIA drivers and Container Toolkit are installed."
    exit 1
fi

# Test Docker with a simple container
print_status "Testing Docker with a simple container"
if run_silent docker run --rm hello-world; then
    print_status "Docker test container ran successfully"
else
    print_error "Docker test container failed to run"
    exit 1
fi

print_status "Docker installation and configuration completed successfully"
