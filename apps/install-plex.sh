#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-plex.sh)"

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
CONFIG_DIR="/mnt/sec/apps/plex/config"
TRANSCODE_DIR="/mnt/sec/apps/plex/transcode"
MEDIA_DIR="/mnt/sec/media"
CONTAINER_NAME="plex"
IMAGE="plexinc/pms-docker:latest"

# Dynamically retrieve the host IP
HOST_IP=$(hostname -I | awk '{print $1}')
ADVERTISE_IP="http://$HOST_IP:32400/"

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
fi

# Check if Plex is already running or installed
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "Plex is already installed."
    read -p "Do you want to uninstall it? (y/n): " UNINSTALL
    if [[ "$UNINSTALL" == "y" || "$UNINSTALL" == "Y" ]]; then
        echo "Stopping and removing existing Plex container..."
        docker stop "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Stopped existing Plex container."
        docker rm "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Removed existing Plex container."
        exit 0
    else
        status_message "error" "Installation aborted as Plex is already installed."
    fi
fi

# Prompt user for Plex claim token
echo "Please obtain your Plex claim token from: https://www.plex.tv/claim"
read -p "Enter your Plex claim token: " PLEX_CLAIM
if [[ -z "$PLEX_CLAIM" ]]; then
    status_message "error" "Plex claim token is required. Exiting."
fi

# Check if directories exist
for dir in "$CONFIG_DIR" "$TRANSCODE_DIR" "$MEDIA_DIR"; do
    if [[ ! -d "$dir" ]]; then
        status_message "error" "Directory $dir does not exist. Please create it and try again."
    fi
    status_message "success" "Directory $dir exists."
done

# Pull the latest Plex Docker image
echo "Pulling the latest Plex Docker image..."
docker pull "$IMAGE" && status_message "success" "Pulled the latest Plex image."

# Run the Plex container with NVIDIA GPU support
echo "Starting Plex Media Server with NVIDIA GPU support..."
docker run -d \
  --name="$CONTAINER_NAME" \
  --runtime=nvidia \
  --network=host \
  -e TZ="$TZ" \
  -e PLEX_CLAIM="$PLEX_CLAIM" \
  -e ADVERTISE_IP="$ADVERTISE_IP" \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e NVIDIA_DRIVER_CAPABILITIES=video,compute,utility \
  -v "$CONFIG_DIR:/config" \
  -v "$TRANSCODE_DIR:/transcode" \
  -v "$MEDIA_DIR:/data/media" \
  "$IMAGE"

if [ $? -eq 0 ]; then
    status_message "success" "Plex Media Server with NVIDIA GPU support is up and running!"
    echo "Access it at: $ADVERTISE_IP/web"
else
    status_message "error" "Failed to start Plex Media Server with NVIDIA GPU support. Check the logs for details."
fi
