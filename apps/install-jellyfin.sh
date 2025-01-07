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
CONFIG_DIR="/mnt/sec/apps/jellyfin/config"
CACHE_DIR="/mnt/sec/apps/jellyfin/cache"
MEDIA_DIR="/mnt/sec/media"
CONTAINER_NAME="jellyfin"
IMAGE="jellyfin/jellyfin:latest"
COMPOSE_FILE_PATH="/mnt/sec/apps/jellyfin/docker-compose.yml"
PORT="3012"
APP_DIR="/mnt/sec/apps/jellyfin"

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &>/dev/null; then
    status_message "error" "Docker Compose is not installed. Please install Docker Compose first."
fi

# Check if Jellyfin is already running or installed
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "Jellyfin is already installed."
    read -p "Do you want to uninstall it? (y/n): " UNINSTALL
    if [[ "$UNINSTALL" == "y" || "$UNINSTALL" == "Y" ]]; then
        echo "Stopping and removing existing Jellyfin container, images, volumes, networks, and associated files..."

        # Stop and remove the container
        docker stop "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Stopped existing Jellyfin container."
        docker rm "$CONTAINER_NAME" 2>/dev/null && status_message "success" "Removed existing Jellyfin container."

        # Remove the image
        docker rmi "$IMAGE" 2>/dev/null && status_message "success" "Removed Jellyfin image."

        # Clean up Docker volumes and networks
        docker volume prune -f 2>/dev/null && status_message "success" "Cleaned up Docker volumes."
        docker network prune -f 2>/dev/null && status_message "success" "Cleaned up Docker networks."

        # Clean up unused Docker resources (optional)
        docker system prune -f 2>/dev/null && status_message "success" "Cleaned up unused Docker resources."

        # Remove the directories related to Jellyfin
        rm -rf "$CONFIG_DIR" "$CACHE_DIR" && status_message "success" "Removed Jellyfin associated directories."

        # Remove the app directory itself
        rm -rf "$APP_DIR" && status_message "success" "Removed the Jellyfin app directory ($APP_DIR)."

        # Remove the Docker Compose file
        rm -f "$COMPOSE_FILE_PATH" && status_message "success" "Removed Docker Compose file."

        exit 0
    else
        status_message "error" "Installation aborted as Jellyfin is already installed."
    fi
fi

# Check if directories exist, and create them if not
for dir in "$CONFIG_DIR" "$CACHE_DIR" "$MEDIA_DIR"; do
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
  jellyfin:
    image: $IMAGE
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    environment:
      - TZ=$TZ
    volumes:
      - $CONFIG_DIR:/config
      - $CACHE_DIR:/cache
      - $MEDIA_DIR:/media
    ports:
      - "$PORT:8096"
EOL
status_message "success" "Docker Compose file created at $COMPOSE_FILE_PATH."

# Start Jellyfin using Docker Compose
echo "Starting Jellyfin using Docker Compose..."
cd "$(dirname "$COMPOSE_FILE_PATH")" && docker-compose up -d

if [ $? -eq 0 ]; then
    status_message "success" "Jellyfin is up and running!"
    echo "Access it at: http://$(hostname -I | awk '{print $1}'):$PORT"
else
    status_message "error" "Failed to start Jellyfin. Check the logs for details."
fi
