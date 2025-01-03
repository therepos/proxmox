#!/bin/bash

# Use the following command to shutdown Immich: docker compose down -v
# Define status symbols for messaging
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Exit immediately if a command exits with a non-zero status
set -e

# Define the application directory
APP_DIR="/mnt/nvme0n1/apps/immich-app"

# Function to check command success
check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN} $1 completed successfully.${RESET}"
    else
        echo -e "${RED} $1 failed.${RESET}"
        exit 1
    fi
}

# Create app folder
echo "Creating application directory at $APP_DIR..."
mkdir -p "$APP_DIR"
check_success "Creating application directory"

# Navigate to app folder
cd "$APP_DIR"
echo "Navigated to $APP_DIR."

# Download installation files
echo "Downloading docker-compose.yml..."
wget -O docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
check_success "Downloading docker-compose.yml"

echo "Downloading .env file..."
wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env
check_success "Downloading .env file"

# Download optional hardware acceleration files
echo "Downloading hardware acceleration files..."
wget -O hwaccel.transcoding.yml https://github.com/immich-app/immich/releases/latest/download/hwaccel.transcoding.yml
check_success "Downloading hwaccel.transcoding.yml"

wget -O hwaccel.ml.yml https://github.com/immich-app/immich/releases/latest/download/hwaccel.ml.yml
check_success "Downloading hwaccel.ml.yml"

# Update Docker to the latest version
echo "Updating Docker to the latest version..."
sudo apt-get update
check_success "Updating apt repositories"

sudo apt-get install -y docker-ce docker-ce-cli containerd.io
check_success "Installing Docker"

# Start Immich
echo "Starting Immich using Docker Compose..."
docker compose up -d
check_success "Starting Immich"

echo -e "${GREEN} Immich setup complete!${RESET}"
