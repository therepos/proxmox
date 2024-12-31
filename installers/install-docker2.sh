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

# Step 1: Update the System
echo "Updating system..."
apt-get update -y && apt-get upgrade -y
status_message success "System updated successfully."

# Step 2: Install Prerequisites
echo "Installing prerequisites..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    gnupg lsb-release
status_message success "Prerequisites installed successfully."

# Step 3: Add Docker GPG Key and Repository
echo "Adding Docker GPG key and repository..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
status_message success "Docker GPG key and repository added."

# Step 4: Install Docker
echo "Installing Docker..."
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
status_message success "Docker installed and started successfully."

# Step 5: Add NVIDIA GPG Key and Repository
echo "Adding NVIDIA Container Toolkit GPG key and repository..."
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-docker-keyring.gpg
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list > /etc/apt/sources.list.d/nvidia-docker.list
apt-get update
status_message success "NVIDIA Container Toolkit repository added."

# Step 6: Install NVIDIA Container Toolkit
echo "Installing NVIDIA Container Toolkit..."
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
status_message success "NVIDIA Container Toolkit installed and configured successfully."

# Step 7: Verify Installation
echo "Verifying NVIDIA Docker integration..."
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu20.04 nvidia-smi
if [ $? -eq 0 ]; then
    status_message success "Docker NVIDIA GPU integration verified successfully."
else
    status_message failure "Docker NVIDIA GPU integration failed. Check logs for details."
fi

echo -e "${GREEN}Docker and NVIDIA integration setup completed successfully.${RESET}"
