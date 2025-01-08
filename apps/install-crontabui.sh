#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-crontabui.sh)"

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
CONFIG_DIR="/mnt/sec/apps/crontab-ui/config"
DATA_DIR="/mnt/sec/apps/crontab-ui/data"
CONTAINER_NAME="crontab-ui"
IMAGE="alseambusher/crontab-ui:latest"
COMPOSE_FILE_PATH="/mnt/sec/apps/crontab-ui/docker-compose.yml"
PORT="9090"
APP_DIR="/mnt/sec/apps/crontab-ui"
ADMIN_USER="admin"   # default admin username
ADMIN_PASSWORD="password"  # default admin password

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

# Check if Crontab-UI is already running or installed
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "Crontab-UI is already installed."
    read -p "Do you want to uninstall it? (y/n): " UNINSTALL
    if [[ "$UNINSTALL" == "y" || "$UNINSTALL" == "Y" ]]; then
        echo "Stopping and removing existing Crontab-UI container, images, volumes, networks, and associated files..."

        # Stop and remove the container (suppress verbose output)
        docker stop "$CONTAINER_NAME" &>/dev/null
        status_message "success" "Stopped existing Crontab-UI container."
        
        docker rm "$CONTAINER_NAME" &>/dev/null
        status_message "success" "Removed existing Crontab-UI container."

        # Remove the image (suppress verbose output)
        docker rmi "$IMAGE" &>/dev/null
        status_message "success" "Removed Crontab-UI image."

        # Clean up Docker volumes and networks (suppress verbose output)
        docker volume prune -f &>/dev/null
        status_message "success" "Cleaned up Docker volumes."
        
        docker network prune -f &>/dev/null
        status_message "success" "Cleaned up Docker networks."

        # Clean up unused Docker resources (suppress verbose output)
        docker system prune -f &>/dev/null
        status_message "success" "Cleaned up unused Docker resources."

        # Remove the directories related to Crontab-UI
        rm -rf "$CONFIG_DIR" "$DATA_DIR"
        status_message "success" "Removed Crontab-UI associated directories."

        # Remove the app directory itself
        rm -rf "$APP_DIR"
        status_message "success" "Removed the Crontab-UI app directory ($APP_DIR)."

        # Remove the Docker Compose file
        rm -f "$COMPOSE_FILE_PATH"
        status_message "success" "Removed Docker Compose file."

        exit 0
    else
        status_message "error" "Installation aborted as Crontab-UI is already installed."
    fi
fi

# Check if directories exist, and create them if not
for dir in "$CONFIG_DIR" "$DATA_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" && status_message "success" "Created directory $dir."
    else
        status_message "success" "Directory $dir exists."
    fi
done

# Generate Docker Compose file
cat <<EOL > "$COMPOSE_FILE_PATH"
version: "3.8"
services:
  crontab-ui:
    image: $IMAGE
    container_name: $CONTAINER_NAME
    network_mode: bridge
    restart: unless-stopped
    environment:
      - TZ=$TZ
      - ADMIN_USER=$ADMIN_USER
      - ADMIN_PASSWORD=$ADMIN_PASSWORD
    volumes:
      - $CONFIG_DIR:/config
      - $DATA_DIR:/data
    ports:
      - "$PORT:8080"
EOL
status_message "success" "Docker Compose file created at $COMPOSE_FILE_PATH."

# Pull the latest Crontab-UI Docker image (suppress output)
docker pull "$IMAGE" &>/dev/null
status_message "success" "Pulled the latest Crontab-UI Docker image."

# Start Crontab-UI using Docker Compose (suppress output)
cd "$(dirname "$COMPOSE_FILE_PATH")" && docker-compose up -d &>/dev/null
status_message "success" "Crontab-UI is up and running!"
echo "Access it at: $ADVERTISE_IP"
