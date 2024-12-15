#!/bin/bash

# wget --no-cache -qO- - https://raw.githubusercontent.com/therepos/proxmox/main/setup_openwebui.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/setup_openwebui.sh | bash

# Define default port
DEFAULT_PORT=32768
PORT=${1:-$DEFAULT_PORT} # Use user-defined port if provided, otherwise use default

# Function to check command availability
check_command() {
  command -v "$1" >/dev/null 2>&1
}

# Ensure the script runs with root privileges
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root or with sudo."
  exit 1
fi

# Update package list
echo "Updating package list..."
apt update -y

# Install Docker if not installed
if ! check_command docker; then
  echo "Docker not found. Installing Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
else
  echo "Docker is already installed."
fi

# Install NVIDIA Container Toolkit if not installed
if ! check_command nvidia-container-runtime; then
  echo "Installing NVIDIA Container Toolkit..."
  distribution=$(. /etc/os-release; echo $ID$VERSION_ID) && \
  curl -s -L https://nvidia.github.io/nvidia-container-runtime/gpgkey | sudo apt-key add - && \
  curl -s -L https://nvidia.github.io/nvidia-container-runtime/$distribution/nvidia-container-runtime.list | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-runtime.list
  apt update && apt install -y nvidia-container-toolkit
  systemctl restart docker
else
  echo "NVIDIA Container Toolkit is already installed."
fi

# Verify NVIDIA drivers and toolkit
if ! docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi > /dev/null 2>&1; then
  echo "NVIDIA drivers or container toolkit is not properly configured. Please check your setup."
  exit 1
fi

# Pull Open WebUI Docker image
echo "Pulling Open WebUI Docker image..."
docker pull openwebui/openwebui:latest

# Stop and remove any existing container
if docker ps -a --filter "name=openwebui" --format '{{.Names}}' | grep -w openwebui > /dev/null; then
  echo "Stopping and removing existing Open WebUI container..."
  docker stop openwebui && docker rm openwebui
fi

# Run Open WebUI container
echo "Starting Open WebUI container on port $PORT..."
docker run --rm -d \
  --name openwebui \
  --gpus all \
  -p "$PORT":3000 \
  openwebui/openwebui:latest

# Output success message
echo "Open WebUI is now running!"
echo "Access it at: http://$(hostname -I | awk '{print $1}'):$PORT"
