#!/bin/bash

# GitHub URL for the repository where your files are stored
REPO_URL="https://raw.githubusercontent.com/your-username/ollama-webui-setup/main"

# Update system
echo "Updating system..."
sudo apt update -y
sudo apt upgrade -y

# Install Node.js and npm (for web server)
echo "Installing Node.js and npm..."
curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash -
sudo apt install -y nodejs

# Install Docker (if not already installed)
echo "Installing Docker..."
sudo apt install -y docker.io

# Check Docker installation
docker --version

# Install git (if not already installed)
echo "Installing Git..."
sudo apt install -y git

# Create directory for the project
echo "Creating directory for Ollama Web UI..."
mkdir -p ~/ollama-webui
cd ~/ollama-webui

# Download Dockerfile and server.js from GitHub
echo "Downloading Dockerfile and server.js..."
curl -O ${REPO_URL}/Dockerfile
curl -O ${REPO_URL}/server.js

# Initialize Node.js project
echo "Initializing Node.js project..."
npm init -y

# Install necessary Node.js dependencies (express and child_process)
echo "Installing dependencies..."
npm install express child_process

# Create the server.js file (which has already been downloaded)
# The file is already downloaded, no need to create it here

# Build the Docker image for Web UI
echo "Building Docker image for Web UI..."
sudo docker build -t ollama-webui .

# Run the Web UI Docker container, exposing port 8082
echo "Running Web UI Docker container..."
sudo docker run -d -p 8082:8082 --name ollama-webui --link ollama-container:ollama ollama-webui

# Test the Web UI
echo "Testing Web UI..."
curl http://localhost:8082

# Display success message
echo "Ollama Web UI should now be accessible at http://localhost:8082"
