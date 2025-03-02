#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/mediacms-scanfiles.sh)"
# purpose: this script 

# Define variables
GITHUB_REPO="https://github.com/therepos/proxmox/raw/main/tools"
CONTAINER_NAME="mediacms-web-1"  # Replace with your actual container name
MEDIA_FOLDER="/mnt/sec/media/temp"  # Change this if needed
SCRIPT_NAME="mediacms-uploadfiles.py"
SCRIPT_PATH="/opt/$SCRIPT_NAME"

echo "Setting up MediaCMS auto-upload inside Docker container..."

# Step 1: Install Python and dependencies inside the container
echo "Installing Python and requests inside the container..."
docker exec -it $CONTAINER_NAME apt update
docker exec -it $CONTAINER_NAME apt install -y python3 python3-pip inotify-tools
docker exec -it $CONTAINER_NAME pip3 install requests

# Step 2: Download the Python upload script from GitHub and copy it into the container
echo "Downloading upload script from GitHub..."
wget -O $SCRIPT_NAME "$GITHUB_REPO/$SCRIPT_NAME"

echo "Copying upload script to container..."
docker cp $SCRIPT_NAME $CONTAINER_NAME:$SCRIPT_PATH

echo "Setup complete. New media files in $MEDIA_FOLDER will be uploaded automatically!"
