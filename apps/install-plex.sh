#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-plex.sh)"
# purpose: this script installs plex docker

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
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 && docker rm "$CONTAINER_NAME" >/dev/null 2>&1
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

# Create directories if they do not exist
for dir in "$CONFIG_DIR" "$TRANSCODE_DIR" "$MEDIA_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" && status_message "success" "Created directory $dir."
    fi
done

# Pull the latest Plex Docker image
docker pull "$IMAGE" >/dev/null 2>&1 && status_message "success" "Pulled the latest Plex image."

# Run the Plex container with NVIDIA GPU support
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
  "$IMAGE" >/dev/null 2>&1

if [ $? -eq 0 ]; then
    status_message "success" "Plex Media Server with NVIDIA GPU support is up and running!"
    echo "Access it at: $ADVERTISE_IP/web"
else
    status_message "error" "Failed to start Plex Media Server with NVIDIA GPU support."
fi
