#!/bin/bash
# purpose: this script installs ollama docker ct

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
APP_DIR="/mnt/sec/apps/ollama"
DOCKER_COMPOSE_FILE="$APP_DIR/docker-compose.yml"
CONTAINER_NAME="ollama"
IMAGE_NAME="ollama/ollama:latest"

# Check if Ollama is already installed (i.e., if the container exists)
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "Ollama is already installed."
    read -p "Do you want to uninstall it? (y/n): " UNINSTALL
    if [[ "$UNINSTALL" == "y" || "$UNINSTALL" == "Y" ]]; then
        echo "Stopping and removing existing Ollama container, images, volumes, networks, and associated files..."

        # Stop and remove the container
        docker stop "$CONTAINER_NAME" &>/dev/null
        status_message "success" "Stopped existing Ollama container."

        docker rm "$CONTAINER_NAME" &>/dev/null
        status_message "success" "Removed existing Ollama container."

        # Remove the image
        docker rmi "$IMAGE_NAME" &>/dev/null
        status_message "success" "Removed Ollama image."

        # Clean up Docker volumes and networks
        docker volume prune -f &>/dev/null
        status_message "success" "Cleaned up Docker volumes."
        
        docker network prune -f &>/dev/null
        status_message "success" "Cleaned up Docker networks."

        # Clean up unused Docker resources (optional)
        docker system prune -f &>/dev/null
        status_message "success" "Cleaned up unused Docker resources."

        # Remove the directories related to Ollama
        rm -rf "$APP_DIR"
        status_message "success" "Removed the Ollama app directory ($APP_DIR)."

        # Remove the Docker Compose file
        rm -f "$DOCKER_COMPOSE_FILE"
        status_message "success" "Removed Docker Compose file."
    else
        echo "Ollama installation remains intact."
    fi
else
    echo "Ollama is not installed."
fi

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &>/dev/null; then
    status_message "error" "Docker Compose is not installed. Please install Docker Compose first."
fi

# Create the application directory if it does not exist
if [ ! -d "$APP_DIR" ]; then
    mkdir -p "$APP_DIR"
    if [ $? -eq 0 ]; then
        status_message "success" "Created application directory at $APP_DIR"
    else
        status_message "error" "Failed to create application directory at $APP_DIR"
    fi
fi

# Ask the user if they want to use GPU
read -p "Do you wish to use GPU? (y/n): " use_gpu

# Generate Docker Compose file
cat > "$DOCKER_COMPOSE_FILE" <<EOL
services:
  ollama-server:
    image: ollama/ollama:latest
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - ./ollama_data:/root/.ollama
    restart: unless-stopped
EOL

# Conditionally add GPU block if user wants to use GPU
if [[ "$use_gpu" == "y" || "$use_gpu" == "Y" ]]; then
    cat >> "$DOCKER_COMPOSE_FILE" <<EOL
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
EOL
    status_message "success" "GPU support enabled."
else
    status_message "success" "GPU support disabled."
fi

cat >> "$DOCKER_COMPOSE_FILE" <<EOL
  ollama-webui:
    image: ghcr.io/ollama-webui/ollama-webui:main
    container_name: ollama-webui
    restart: unless-stopped
    environment:
      - 'OLLAMA_BASE_URL=http://ollama:11434'
    volumes:
      - ./webui:/app/backend/data
    ports:
      - "3014:8080"
    extra_hosts:
      - host.docker.internal:host-gateway
EOL

if [ $? -eq 0 ]; then
    status_message "success" "Docker Compose file created at $DOCKER_COMPOSE_FILE"
else
    status_message "error" "Failed to create Docker Compose file at $DOCKER_COMPOSE_FILE"
fi

# Start using Docker Compose
cd "$APP_DIR" || status_message "error" "Failed to navigate to $APP_DIR"
docker-compose up -d

if [ $? -eq 0 ]; then
    status_message "success" "Ollama services are up and running!"
    echo "Access the services at the following ports:"
    echo " - Ollama Server: 11434"
    echo " - Open WebUI: 3014"
    echo " - Anything-LLM: 3015"
else
    status_message "error" "Failed to start Ollama services. Check the logs for details."
fi
