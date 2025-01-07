#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-navidrome.sh)"

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

# Variables
TZ="Asia/Singapore"
CONFIG_DIR="/mnt/nvme0n1/apps/navidrome/config"
DATA_DIR="/mnt/nvme0n1/apps/navidrome/data"
MUSIC_DIR="/mnt/nvme0n1/media/music"
CONTAINER_NAME="navidrome"
IMAGE="deluan/navidrome:latest"

# Dynamically retrieve the host IP
HOST_IP=$(hostname -I | awk '{print $1}')
ADVERTISE_IP="http://$HOST_IP:4533/"

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
fi

# Check if Navidrome is already running or installed
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "Navidrome is already installed."
    read -p "Do you want to uninstall it? (y/n): " UNINSTALL
    if [[ "$UNINSTALL" == "y" || "$UNINSTALL" == "Y" ]]; then
        echo "Stopping and removing existing Navidrome container..."
        docker stop "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Stopped existing Navidrome container."
        docker rm "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Removed existing Navidrome container."
        exit 0
    else
        status_message "error" "Installation aborted as Navidrome is already installed."
    fi
fi

# Check if directories exist
for dir in "$CONFIG_DIR" "$DATA_DIR" "$MUSIC_DIR"; do
    if [[ ! -d "$dir" ]]; then
        status_message "error" "Directory $dir does not exist. Please create it and try again."
    fi
    status_message "success" "Directory $dir exists."
done

# Pull the latest Navidrome Docker image
echo "Pulling the latest Navidrome Docker image..."
docker pull "$IMAGE" && status_message "success" "Pulled the latest Navidrome image."

# Run the Navidrome container
echo "Starting Navidrome..."
docker run -d \
  --name="$CONTAINER_NAME" \
  --restart=unless-stopped \
  -e TZ="$TZ" \
  -v "$CONFIG_DIR:/config" \
  -v "$DATA_DIR:/data" \
  -v "$MUSIC_DIR:/music" \
  -p 4533:4533 \
  "$IMAGE"

if [ $? -eq 0 ]; then
    status_message "success" "Navidrome is up and running!"
    echo "Access it at: $ADVERTISE_IP"
else
    status_message "error" "Failed to start Navidrome. Check the logs for details."
fi
