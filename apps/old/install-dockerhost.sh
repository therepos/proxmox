#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-dockerhost.sh?$(date +%s))"
# purpose: installs docker engine, docker compose, and optional nvidia container toolkit for pve8

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

# Step 0: Prompt NVIDIA GPU or not
echo -e "\nDoes this system have an NVIDIA GPU?"
echo "1) Yes - install NVIDIA runtime"
echo "2) No  - skip NVIDIA setup"
read -rp "Select option [1-2]: " GPU_OPTION

# Step 1: Update the System
apt-get update -y &>/dev/null && apt-get upgrade -y &>/dev/null
status_message success "System updated successfully."

# Step 2: Install prerequisites
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    gnupg \
    lsb-release \
    zfsutils-linux \
    jq &>/dev/null
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
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) \
        -o /usr/local/bin/docker-compose &>/dev/null
    chmod +x /usr/local/bin/docker-compose
    docker compose version &>/dev/null && \
        status_message success "Docker Compose installed." || \
        status_message failure "Docker Compose install failed."
else
    status_message success "Docker Compose already installed."
fi

# Step 7: Configure Docker for ZFS (and optionally NVIDIA)
DOCKER_CONFIG="/etc/docker/daemon.json"
ZFS_CONFIG='{"storage-driver": "zfs"}'

if [[ "$GPU_OPTION" == "1" ]]; then
    ZFS_CONFIG=$(jq -n '{
      "storage-driver": "zfs",
      "runtimes": {
        "nvidia": {
          "path": "nvidia-container-runtime",
          "runtimeArgs": []
        }
      }
    }')
fi

echo "$ZFS_CONFIG" > "$DOCKER_CONFIG"
status_message success "Docker configured with ZFS${GPU_OPTION:+ and NVIDIA runtime}."

# Step 8: NVIDIA Setup (optional)
if [[ "$GPU_OPTION" == "1" ]]; then
    distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/nvidia-docker/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-docker-keyring.gpg &>/dev/null
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list > /etc/apt/sources.list.d/nvidia-docker.list
    apt-get update &>/dev/null
    status_message success "NVIDIA repository added."

    apt-get install -y nvidia-container-toolkit &>/dev/null
    nvidia-ctk runtime configure --runtime=docker &>/dev/null
    status_message success "NVIDIA Container Toolkit installed and configured."

    # Step 9: Test NVIDIA integration
    docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu20.04 nvidia-smi &>/dev/null
    [[ $? -eq 0 ]] && \
        status_message success "NVIDIA GPU detected and verified in Docker." || \
        status_message failure "NVIDIA GPU not functioning correctly in Docker."
fi

# Step 9: Clean Up and Finish
systemctl restart docker &>/dev/null
docker image prune -a -f &>/dev/null
status_message success "Cleanup completed."

echo -e "${GREEN}Docker and Docker Compose are now installed and configured${GPU_OPTION:+ with NVIDIA runtime} using ZFS on your Proxmox host.${RESET}"