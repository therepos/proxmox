#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-ollama.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-ollama.sh | bash

# Function to check if NVIDIA drivers are installed
check_nvidia_driver() {
    if command -v nvidia-smi &> /dev/null; then
        echo "NVIDIA drivers are already installed."
        return 0
    else
        echo "NVIDIA drivers are not installed."
        return 1
    fi
}

# Function to check if NVIDIA Docker is installed
check_nvidia_docker() {
    if command -v nvidia-docker &> /dev/null; then
        echo "NVIDIA Docker is already installed."
        return 0
    else
        echo "NVIDIA Docker is not installed."
        return 1
    fi
}

# Update package list
echo "Updating package list..."
sudo apt update

# Check if NVIDIA drivers are installed
check_nvidia_driver
if [ $? -eq 1 ]; then
    echo "Installing NVIDIA drivers..."
    sudo apt install -y nvidia-driver nvidia-utils
else
    echo "Skipping NVIDIA driver installation."
fi

# Check if NVIDIA Docker is installed
check_nvidia_docker
if [ $? -eq 1 ]; then
    echo "Installing NVIDIA Docker..."
    # Add NVIDIA package repository for the container toolkit
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
    sudo apt update
    sudo apt install -y nvidia-docker2
else
    echo "Skipping NVIDIA Docker installation."
fi

# Enable Docker to use NVIDIA runtime
echo "Restarting Docker service to enable NVIDIA runtime..."
sudo systemctl restart docker

# Verify NVIDIA Docker installation by running a test container
echo "Verifying NVIDIA Docker installation..."
sudo docker run --rm nvidia/cuda:11.0-base nvidia-smi

echo "Installation complete."
