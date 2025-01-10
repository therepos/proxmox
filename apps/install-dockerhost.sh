#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-dockerhost.sh)"
# source: https://docs.docker.com/engine/install/debian/#install-using-the-repository

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
    gnupg lsb-release zfsutils-linux
status_message success "Prerequisites installed successfully."

# Step 3: Verify ZFS Availability for Docker
echo "Verifying ZFS configuration for Docker..."
if ! zpool list > /dev/null 2>&1; then
    status_message failure "No ZFS pools detected. Ensure ZFS is properly configured before proceeding."
fi
status_message success "ZFS environment verified."

# Step 4: Add Docker GPG Key and Repository
echo "Adding Docker GPG key and repository..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
status_message success "Docker GPG key and repository added."

# Step 5: Install Docker
echo "Installing Docker..."
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
status_message success "Docker installed and started successfully."

# Step 6: Configure Docker to Use ZFS
echo "Configuring Docker to use the ZFS storage driver..."
DOCKER_CONFIG="/etc/docker/daemon.json"
if [ ! -f "$DOCKER_CONFIG" ]; then
    tee "$DOCKER_CONFIG" > /dev/null <<EOF
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
    echo "Updating existing Docker configuration for ZFS and NVIDIA..."
    jq '. + {"storage-driver": "zfs", "runtimes": {"nvidia": {"path": "nvidia-container-runtime", "runtimeArgs": []}}}' "$DOCKER_CONFIG" > /tmp/daemon.json
    mv /tmp/daemon.json "$DOCKER_CONFIG"
fi

systemctl restart docker
status_message success "Docker configured to use ZFS storage driver and NVIDIA runtime."

# Step 7: Add NVIDIA GPG Key and Repository
echo "Adding NVIDIA Container Toolkit GPG key and repository..."
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-docker-keyring.gpg
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list > /etc/apt/sources.list.d/nvidia-docker.list
apt-get update
status_message success "NVIDIA Container Toolkit repository added."

# Step 8: Install NVIDIA Container Toolkit
echo "Installing NVIDIA Container Toolkit..."
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
status_message success "NVIDIA Container Toolkit installed and configured successfully."

# Step 9: Verify NVIDIA Docker Integration
echo "Verifying NVIDIA Docker integration..."
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu20.04 nvidia-smi
if [ $? -eq 0 ]; then
    status_message success "Docker NVIDIA GPU integration verified successfully."
else
    status_message failure "Docker NVIDIA GPU integration failed. Check logs for details."
fi

# Step 10: Clean Up and Finish
echo "Docker setup completed successfully. Cleaning up unnecessary files..."
docker image prune -a -f
status_message success "Cleanup completed. Docker setup is ready."

echo -e "${GREEN}Docker and NVIDIA integration is now configured to work seamlessly with ZFS on your Proxmox host.${RESET}"
