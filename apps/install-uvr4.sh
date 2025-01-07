#!/bin/bash

# Update and upgrade the system
sudo apt update && sudo apt upgrade -y

# Define paths
APP_PATH="/mnt/nvme0n1/apps/uvr"
DOCKER_IMAGE_NAME="ultimatevocalremovergui"
DOWNLOAD_FILE="master.zip"
DOWNLOAD_URL="https://github.com/Anjok07/ultimatevocalremovergui/archive/refs/heads/master.zip"

# Check if APP_PATH exists, if not create it
if [ ! -d "$APP_PATH" ]; then
  mkdir -p "$APP_PATH"
fi

# Download and prepare the Ultimate Vocal Remover GUI
cd "$APP_PATH"
if [ ! -f "$DOWNLOAD_FILE" ]; then
  wget -O "$DOWNLOAD_FILE" "$DOWNLOAD_URL"
fi
unzip -o "$DOWNLOAD_FILE"
rm "$DOWNLOAD_FILE"
mv ultimatevocalremovergui-master ultimatevocalremovergui

# Navigate to the application directory
cd "$APP_PATH/ultimatevocalremovergui"

# Create a Dockerfile in the application directory
cat <<EOF > Dockerfile
# Use an official Python image as a base
FROM python:3.9-slim

# Set the working directory
WORKDIR /app

# Copy the application files into the container
COPY . .

# Install system dependencies
RUN apt-get update && apt-get install -y ffmpeg python3-tk && rm -rf /var/lib/apt/lists/*

# Upgrade pip to the latest version
RUN pip install --upgrade pip

# Allow debugging of dependency installation errors
RUN pip install --no-cache-dir -r requirements.txt || true

# Expose any ports required by the application (if applicable)
EXPOSE 5000

# Define the command to run the application
CMD ["python3", "UVR.py"]
EOF

# Create a docker-compose.yml file
cat <<EOF > docker-compose.yml
version: '3.8'

services:
  uvr:
    build:
      context: .
    image: $DOCKER_IMAGE_NAME
    ports:
      - "5000:5000" # Replace with dynamic port if required
    volumes:
      - "$APP_PATH/ultimatevocalremovergui/models:/app/models"
    deploy:
      resources:
        reservations:
          devices:
          - capabilities: ["gpu"]
    stdin_open: true
    tty: true
EOF

# Build the application using Docker Compose
docker-compose build

# Run an interactive shell in the container to debug dependencies
docker run -it --entrypoint /bin/bash "$DOCKER_IMAGE_NAME"
