#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/installers/install-nvidiact.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/installers/install-nvidiact.sh | bash

# Error detection: script halts execution as soon as it encounters a failure.
set -e

# Detect architecture
# ARCH=$(dpkg --print-architecture)

# Remove redundant file
if [ -f /etc/apt/sources.list.d/cuda-debian12-x86_64.list ]; then
    rm /etc/apt/sources.list.d/cuda-debian12-x86_64.list
fi

# Add NVIDIA GPG key
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# Manually download public key
# curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/3bf863cc.pub | gpg --dearmor -o /usr/share/keyrings/cuda-archive-keyring.gpg

# Update the repository configuration
echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64 /" > /etc/apt/sources.list.d/cuda.list

# Update and install NVIDIA Container Toolkit
apt update
apt install -y nvidia-container-toolkit

# References: https://medium.com/@u.mele.coding/a-beginners-guide-to-nvidia-container-toolkit-on-docker-92b645f92006
