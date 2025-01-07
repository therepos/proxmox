#!/bin/bash

# Update and upgrade the system
sudo apt update && sudo apt upgrade -y

# Install required dependencies (only ffmpeg needed on host for Docker setup)
sudo apt-get install -y ffmpeg

# Define paths
APP_PATH="/mnt/nvme0n1/apps/uvr/ultimatevocalremovergui"
DOCKER_IMAGE_NAME="ultimatevocalremovergui"

# Navigate to the application directory
cd "$APP_PATH"

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

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

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
      - "$APP_PATH/models:/app/models"
    deploy:
      resources:
        reservations:
          devices:
          - capabilities: ["gpu"]
    stdin_open: true
    tty: true
EOF

# Build and run the application using Docker Compose
docker-compose up --build
