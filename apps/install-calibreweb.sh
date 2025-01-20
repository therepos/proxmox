#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-calibreweb.sh)"
# purpose: this script installs calibre-web docker

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
CONTAINER_NAME="calibre-web"
IMAGE="lscr.io/linuxserver/calibre-web:latest"
COMPOSE_FILE_PATH="/mnt/sec/apps/calibreweb/docker-compose.yml"
APP_DIR="/mnt/sec/apps/calibreweb"
CONFIG_DIR="$APP_DIR/config"
BOOKS_DIR="$APP_DIR/books"
PORT="3015"

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

# Check if Calibre-Web is already running or installed
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "Calibre-Web is already installed."
    read -p "Do you want to uninstall it? (y/n): " UNINSTALL
    if [[ "$UNINSTALL" == "y" || "$UNINSTALL" == "Y" ]]; then
        echo "Stopping and removing existing Calibre-Web container, images, volumes, networks, and associated files..."

        # Stop and remove the container (suppress verbose output)
        docker stop "$CONTAINER_NAME" &>/dev/null
        status_message "success" "Stopped existing Calibre-Web container."
        
        docker rm "$CONTAINER_NAME" &>/dev/null
        status_message "success" "Removed existing Calibre-Web container."

        # Remove the image (suppress verbose output)
        docker rmi "$IMAGE" &>/dev/null
        status_message "success" "Removed Calibre-Web image."

        # Clean up Docker volumes and networks (suppress verbose output)
        docker volume prune -f &>/dev/null
        status_message "success" "Cleaned up Docker volumes."
        
        docker network prune -f &>/dev/null
        status_message "success" "Cleaned up Docker networks."

        # Clean up unused Docker resources (suppress verbose output)
        docker system prune -f &>/dev/null
        status_message "success" "Cleaned up unused Docker resources."

        # Remove the directories related to Calibre-Web
        rm -rf "$APP_DIR"
        status_message "success" "Removed Calibre-Web app directory ($APP_DIR)."

        exit 0
    else
        status_message "error" "Installation aborted as Calibre-Web is already installed."
    fi
fi

# Check if directories exist, and create them if not
for dir in "$CONFIG_DIR" "$BOOKS_DIR"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" && status_message "success" "Created directory $dir."
    else
        status_message "success" "Directory $dir exists."
    fi
done

# Download metadata file
METADATA_URL="https://github.com/janeczku/raw/main/calibre-web/library/metadata.db"
wget -qO "$BOOKS_DIR/metadata.db" "$METADATA_URL"
status_message "success" "Downloaded metadata.db to $BOOKS_DIR."

# Set permissions
chown -R 1000:1000 "$BOOKS_DIR"
chmod -R 775 "$BOOKS_DIR"
status_message "success" "Set ownership and permissions for $BOOKS_DIR."

# Generate Docker Compose file
cat <<EOL > "$COMPOSE_FILE_PATH"
version: "3.8"
services:
  calibre-web:
    image: $IMAGE
    container_name: $CONTAINER_NAME
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=$TZ
      - DOCKER_MODS=linuxserver/mods:universal-calibre #optional
      - OAUTHLIB_RELAX_TOKEN_SCOPE=1 #optional
    volumes:
      - $CONFIG_DIR:/config
      - $BOOKS_DIR:/books
    ports:
      - "$PORT:8083"
    restart: unless-stopped
EOL
status_message "success" "Docker Compose file created at $COMPOSE_FILE_PATH."

# Pull the latest Calibre-Web Docker image (suppress output)
docker pull "$IMAGE" &>/dev/null
status_message "success" "Pulled the latest Calibre-Web Docker image."

# Start Calibre-Web using Docker Compose (suppress output)
cd "$(dirname "$COMPOSE_FILE_PATH")" && docker-compose up -d &>/dev/null
status_message "success" "Calibre-Web is up and running!"
echo "Access it at: $ADVERTISE_IP"
