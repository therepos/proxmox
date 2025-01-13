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
APP_DIR="/mnt/sec/apps/ollama"
DOCKER_COMPOSE_FILE="$APP_DIR/docker-compose.yml"

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
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  open-webui:
    image: ghcr.io/ollama-webui/ollama-webui:main
    container_name: open-webui
    restart: unless-stopped
    environment:
      - 'OLLAMA_BASE_URL=http://ollama:11434'
    volumes:
      - ./webui:/app/backend/data
    ports:
      - "3014:8080"
    extra_hosts:
      - host.docker.internal:host-gateway

  anything-LLM:
    image: mintplexlabs/anythingllm:latest
    container_name: anything-llm
    cap_add:
      - SYS_ADMIN
    restart: unless-stopped
    environment:
      - SERVER_PORT=3001
      - UID='1000'
      - GID='1000'
      - STORAGE_DIR=/app/server/storage
      - LLM_PROVIDER=ollama
      - OLLAMA_BASE_PATH=http://ollama-server:11434
      - OLLAMA_MODEL_PREF='phi3'
      - OLLAMA_MODEL_TOKEN_LIMIT=4096
      - EMBEDDING_ENGINE=ollama
      - EMBEDDING_BASE_PATH=http://ollama-server:11434
      - EMBEDDING_MODEL_PREF=nomic-embed-text:latest
      - EMBEDDING_MODEL_MAX_CHUNK_LENGTH=8192
      - VECTOR_DB=lancedb
      - WHISPER_PROVIDER=local
      - TTS_PROVIDER=native
      - PASSWORDMINCHAR=8
    volumes:
      - ./anythingllm_data/storage:/app/server/storage
      - ./anythingllm_data/collector/hotdir/:/app/collector/hotdir
      - ./anythingllm_data/collector/outputs/:/app/collector/outputs
    ports:
      - "3015:3001"
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
