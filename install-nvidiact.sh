#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiact.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiact.sh | bash

# Error detection: script halts execution as soon as it encounters a failure.
set -e

# Detect architecture
ARCH=$(dpkg --print-architecture)

# Add NVIDIA GPG key
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Add NVIDIA repository
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Update and install NVIDIA Container Toolkit
sudo apt update
sudo apt install -y nvidia-container-toolkit

# References: https://medium.com/@u.mele.coding/a-beginners-guide-to-nvidia-container-toolkit-on-docker-92b645f92006
