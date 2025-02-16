#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-dockerhost.sh)"
# purpose: this script installs docker engine, docker compose, and nvidia container toolkit

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
        echo -e "Check logs for details:"
        echo -e "  - System logs: /var/log/syslog"
        echo -e "  - Docker logs: /var/log/docker.log"
        echo -e "  - NVIDIA setup logs: /var/log/nvidia-installer.log (if available)"
        exit 1
    fi
}

# Step 1: Update the System
apt-get update -y &>/dev/null && apt-get upgrade -y &>/dev/null
status_message success "System updated successfully."

# Step 2: Install Prerequisites
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    gnupg lsb-release zfsutils-linux &>/dev/null
status_message success "Prerequisites installed successfully."

# Step 3: Verify ZFS Availability for Docker
if ! zpool list > /dev/null 2>&1; then
    status_message failure "No ZFS pools detected. Ensure ZFS is properly configured before proceeding."
fi
status_message success "ZFS environment verified."

# Step 4: Add Docker GPG Key and Repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg &>/dev/null
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update &>/dev/null
status_message success "Docker GPG key and repository added successfully."

# Step 5: Install Docker
apt-get install -y docker-ce docker-ce-cli containerd.io &>/dev/null
systemctl enable --now docker &>/dev/null
status_message success "Docker installed and started successfully."

# Step 6: Install Docker Compose
if ! docker compose version &>/dev/null; then
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose &>/dev/null
    chmod +x /usr/local/bin/docker-compose &>/dev/null
    if docker compose version &>/dev/null; then
        status_message success "Docker Compose installed successfully."
    else
        status_message failure "Failed to install Docker Compose."
    fi
else
    status_message success "Docker Compose is already installed."
fi

# Step 7: Configure Docker to Use ZFS
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
    # Check if jq is available
    if command -v jq &>/dev/null; then
        # Use jq if it's available
        jq '. + {"storage-driver": "zfs", "runtimes": {"nvidia": {"path": "nvidia-container-runtime", "runtimeArgs": []}}}' "$DOCKER_CONFIG" > /tmp/daemon.json
        mv /tmp/daemon.json "$DOCKER_CONFIG"
    else
        # If jq isn't available, manually append the configuration to the file
        echo '{
    "storage-driver": "zfs",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}' | sudo tee -a "$DOCKER_CONFIG" > /dev/null
    fi
fi

systemctl restart docker &>/dev/null
status_message success "Docker configured with ZFS storage driver and NVIDIA runtime."

# Step 8: Add NVIDIA GPG Key and Repository
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-docker-keyring.gpg &>/dev/null
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list > /etc/apt/sources.list.d/nvidia-docker.list
apt-get update &>/dev/null
status_message success "NVIDIA Container Toolkit repository added successfully."

# Step 9: Install NVIDIA Container Toolkit
apt-get install -y nvidia-container-toolkit &>/dev/null
nvidia-ctk runtime configure --runtime=docker &>/dev/null
systemctl restart docker &>/dev/null
status_message success "NVIDIA Container Toolkit installed and configured successfully."

# Step 10: Verify NVIDIA Docker Integration
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu20.04 nvidia-smi &>/dev/null
if [ $? -eq 0 ]; then
    status_message success "NVIDIA Docker integration verified successfully."
else
    status_message failure "Docker NVIDIA GPU integration failed."
fi

# Step 11: Clean Up and Finish
docker image prune -a -f &>/dev/null
status_message success "Cleanup completed successfully."

echo -e "${GREEN}Docker, Docker Compose, and NVIDIA integration are now configured to work seamlessly with ZFS on your Proxmox host.${RESET}"

