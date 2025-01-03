#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/installers/install-plex.sh)"

#!/bin/bash

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
CONFIG_DIR="/mnt/nvme0n1/apps/plex/config"
TRANSCODE_DIR="/mnt/nvme0n1/apps/plex/transcode"
MEDIA_DIR="/mnt/nvme0n1/media"
CONTAINER_NAME="plex"
IMAGE="plexinc/pms-docker:latest"

# Dynamically retrieve the host IP
HOST_IP=$(hostname -I | awk '{print $1}')
ADVERTISE_IP="http://$HOST_IP:32400/"

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

# Stop and remove existing container if it exists
echo "Stopping existing Plex container (if any)..."
docker stop "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Stopped existing Plex container." || status_message "success" "No existing Plex container running."

echo "Removing existing Plex container (if any)..."
docker rm "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Removed existing Plex container." || status_message "success" "No existing Plex container to remove."

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
