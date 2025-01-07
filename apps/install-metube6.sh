#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-metube.sh)"

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
PORT="3010"
APP_DIR="/mnt/sec/apps/metube"

# Dynamically retrieve the host IP
HOST_IP=$(hostname -I | awk '{print $1}')
ADVERTISE_IP="http://$HOST_IP:$PORT/"

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &>/dev/null; then
    status_message "error" "Docker Compose is not installed. Please install Docker Compose first."
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
version: "3.8"
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
      - "$PORT:8081"
EOL
status_message "success" "Docker Compose file created at $COMPOSE_FILE_PATH."

# Pull the latest MeTube Docker image (suppress output)
docker pull "$IMAGE" &>/dev/null
status_message "success" "Pulled the latest MeTube Docker image."

# Start MeTube using Docker Compose (suppress output)
cd "$(dirname "$COMPOSE_FILE_PATH")" && docker-compose up -d &>/dev/null
status_message "success" "MeTube is up and running!"
echo "Access it at: $ADVERTISE_IP"
