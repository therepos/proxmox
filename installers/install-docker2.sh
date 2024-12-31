#!/bin/bash

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

echo "Ver1"

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
apt-get update -y && apt-get upgrade -y
status_message success "System updated successfully."

# Step 2: Blacklist Nouveau Driver
echo "Blacklisting Nouveau driver..."
echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist-nouveau.conf
status_message success "Nouveau driver blacklisted."

echo "Updating initramfs..."
update-initramfs -u
if lsmod | grep -q nouveau; then
    status_message failure "Nouveau is still loaded. Reboot required."
    reboot
fi
status_message success "Nouveau is disabled."

# Step 3: Install Kernel Headers
echo "Installing kernel headers..."
apt-get install -y build-essential linux-headers-$(uname -r)
status_message success "Kernel headers installed."

# Step 4: Install NVIDIA Driver
NVIDIA_VERSION=${1:-"550.135"}
NVIDIA_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
echo "Downloading NVIDIA driver version ${NVIDIA_VERSION}..."
wget -O /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run "$NVIDIA_URL"
status_message success "NVIDIA driver downloaded."

echo "Installing NVIDIA driver..."
bash /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run --accept-license --install-compat32-libs --silent
status_message success "NVIDIA driver installed."

# Step: Add CUDA Repository for Bullseye
echo "Adding CUDA repository for Debian Bullseye..."

# Remove any conflicting repository entries
rm -f /etc/apt/sources.list.d/cuda-debian12-x86_64.list /etc/apt/sources.list.d/cuda.list

# Add the Bullseye repository (works for Bookworm in most cases)
KEY_URL_PRIMARY="https://developer.download.nvidia.com/compute/cuda/repos/bullseye/x86_64/3bf863cc.pub"

curl -fsSL $KEY_URL_PRIMARY | gpg --dearmor -o /usr/share/keyrings/nvidia-cuda-keyring.gpg
if [ $? -ne 0 ]; then
    echo "Failed to fetch the NVIDIA CUDA key. Exiting."
    exit 1
fi

echo "deb [signed-by=/usr/share/keyrings/nvidia-cuda-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/bullseye/x86_64/ /" > /etc/apt/sources.list.d/cuda.list

# Update repositories and install the CUDA keyring
apt-get update && apt-get install -y cuda-keyring
if [ $? -ne 0 ]; then
    echo "Failed to add CUDA repository or install CUDA keyring. Exiting."
    exit 1
fi

echo "CUDA repository for Bullseye added successfully."

# Step 6: Install Docker
echo "Installing Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
status_message success "Docker installed successfully."

# Step 7: Install NVIDIA Docker Runtime
echo "Installing NVIDIA Docker runtime..."
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-docker-keyring.gpg
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list > /etc/apt/sources.list.d/nvidia-docker.list
apt-get update
apt-get install -y nvidia-container-toolkit nvidia-container-runtime
systemctl restart docker
status_message success "NVIDIA Docker runtime installed successfully."

# Step 8: Verify NVIDIA and Docker GPU Integration
echo "Verifying NVIDIA installation..."
nvidia-smi
status_message success "NVIDIA driver verification successful."

echo "Verifying Docker GPU integration..."
docker run --rm --gpus all nvidia/cuda:12.2.1-base-ubuntu20.04 nvidia-smi
status_message success "Docker GPU integration verified."

# Cleanup
echo "Cleaning up temporary files..."
rm -f /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run
status_message success "Temporary files removed."

echo -e "${GREEN}All installations and verifications completed successfully.${RESET}"
