#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/mediacms-uploadfiles-local.sh)"
# purpose: this script runs mediacms-uploadfiles.py inside the mediacms docker container
# note: authorise access to api at http://yourip:3025/swagger

# Define variables
GITHUB_REPO="https://github.com/therepos/proxmox/raw/main/tools"
CONTAINER_NAME="mediacms-web-1"  # Replace with your actual container name
SCRIPT_NAME="mediacms-uploadfiles-local.py"
SCRIPT_PATH="/opt/$SCRIPT_NAME"

echo "Checking for MediaCMS upload script inside Docker container..."

# Step 1: Check if the script already exists inside the container
if docker exec -it $CONTAINER_NAME test -f $SCRIPT_PATH; then
    echo "Script already exists. Running it now..."
else
    echo "Script not found. Installing it..."

    # Install Python and dependencies if missing
    echo "Installing Python and requests inside the container..."
    docker exec -it $CONTAINER_NAME apt update
    docker exec -it $CONTAINER_NAME apt install -y python3 python3-pip
    docker exec -it $CONTAINER_NAME pip3 install requests

    # Download the script from GitHub
    echo "Downloading upload script from GitHub..."
    wget -O $SCRIPT_NAME "$GITHUB_REPO/$SCRIPT_NAME"

    # Copy it into the container
    echo "Copying upload script to container..."
    docker cp $SCRIPT_NAME $CONTAINER_NAME:$SCRIPT_PATH
fi

# Step 2: Run the script inside the container
echo "Executing upload script inside the container..."
docker exec -it $CONTAINER_NAME python3 $SCRIPT_PATH

echo "Process complete."
