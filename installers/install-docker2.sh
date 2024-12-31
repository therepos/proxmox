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

# Step 1: Update the system
echo "Updating system..."
apt-get update -y
status_message success "System updated successfully."

# Step 2: Install prerequisites
echo "Installing prerequisites..."
apt-get install -y \
    build-essential \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    lsb-release \
    gnupg
status_message success "Prerequisites installed successfully."

# Step 3: Install NVIDIA drivers
echo "Installing NVIDIA drivers..."
rm -f /usr/share/keyrings/nvidia-archive-keyring.gpg
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/$(lsb_release -cs)/x86_64/3bf863cc.pub | gpg --dearmor -o /usr/share/keyrings/nvidia-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nvidia-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/$(lsb_release -cs)/x86_64/ /" | tee /etc/apt/sources.list.d/cuda.list
apt-get update -y
apt-get install -y nvidia-driver-525
status_message success "NVIDIA drivers installed successfully."

# Step 4: Verify NVIDIA installation
echo "Verifying NVIDIA installation..."
nvidia-smi
status_message success "NVIDIA drivers verified successfully."

# Step 5: Install Docker
echo "Installing Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
usermod -aG docker $USER
status_message success "Docker installed successfully."

# Step 6: Install NVIDIA Docker
echo "Installing NVIDIA Docker..."
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-docker-keyring.gpg
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
apt-get update -y
apt-get install -y nvidia-container-toolkit nvidia-container-runtime
systemctl restart docker
status_message success "NVIDIA Docker runtime installed successfully."

# Step 7: Verify Docker with GPU
echo "Verifying Docker GPU integration..."
docker run --rm --gpus all nvidia/cuda:12.2.1-base-ubuntu20.04 nvidia-smi
status_message success "Docker GPU integration verified successfully."

# Final Message
echo -e "${GREEN}All installations and verifications completed successfully. Log out and back in to use Docker without sudo.${RESET}"
