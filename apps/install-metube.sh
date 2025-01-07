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
CONFIG_DIR="/mnt/sec/apps/metube/config"
DATA_DIR="/mnt/sec/apps/metube/data"
DOWNLOAD_DIR="/mnt/sec/media/videos"
CONTAINER_NAME="metube"
IMAGE="alexta69/metube:latest"
COMPOSE_FILE_PATH="/mnt/sec/apps/metube/docker-compose.yml"

# Dynamically retrieve the host IP
HOST_IP=$(hostname -I | awk '{print $1}')
ADVERTISE_IP="http://$HOST_IP:3010/"

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &>/dev/null; then
    status_message "error" "Docker Compose is not installed. Please install Docker Compose first."
fi

# Check if MeTube is already running or installed
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "MeTube is already installed."
    read -p "Do you want to uninstall it? (y/n): " UNINSTALL
    if [[ "$UNINSTALL" == "y" || "$UNINSTALL" == "Y" ]]; then
        echo "Stopping and removing existing MeTube container..."
        docker stop "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Stopped existing MeTube container."
        docker rm "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Removed existing MeTube container."
        exit 0
    else
        status_message "error" "Installation aborted as MeTube is already installed."
    fi
fi

# Check if directories exist, and create them if not
for dir in "$CONFIG_DIR" "$DATA_DIR" "$DOWNLOAD_DIR"; do
    if [[ ! -d "$dir" ]]; then
        echo "Directory $dir does not exist. Creating it now..."
        mkdir -p "$dir" && status_message "success" "Created directory $dir."
    else
        status_message "success" "Directory $dir exists."
    fi
done

# Generate Docker Compose file
cat <<EOL > "$COMPOSE_FILE_PATH"
services:
  metube:
    image: $IMAGE
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    environment:
      - TZ=$TZ
    volumes:
      - $CONFIG_DIR:/config
      - $DATA_DIR:/data
      - $DOWNLOAD_DIR:/downloads
    ports:
      - "3010:3010"
EOL
status_message "success" "Docker Compose file created at $COMPOSE_FILE_PATH."

# Start MeTube using Docker Compose
echo "Starting MeTube using Docker Compose..."
cd "$(dirname "$COMPOSE_FILE_PATH")" && docker-compose up -d

if [ $? -eq 0 ]; then
    status_message "success" "MeTube is up and running!"
    echo "Access it at: $ADVERTISE_IP"
else
    status_message "error" "Failed to start MeTube. Check the logs for details."
fi
