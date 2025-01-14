#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/purge-dockerct.sh)"
# purpose: this script removes user-specified docker container

# Define colors and status symbols
GREEN="\e[32m\u2713\e[0m"
RED="\e[31m\u2717\e[0m"
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

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
fi

# List Docker containers with ID and Name
CONTAINERS=$(docker ps -a --format "{{.ID}}:{{.Names}}")
if [[ -z "$CONTAINERS" ]]; then
    status_message "error" "No Docker containers found."
fi

# Display container list for selection
echo "Available Docker containers (ID: Name):"
PS3="#? "
select CONTAINER_ENTRY in $CONTAINERS; do
    if [[ -n "$CONTAINER_ENTRY" ]]; then
        CONTAINER_ID=$(echo "$CONTAINER_ENTRY" | awk -F':' '{print $1}')
        CONTAINER_NAME=$(echo "$CONTAINER_ENTRY" | awk -F':' '{print $2}')
        echo "You selected container: $CONTAINER_NAME (ID: $CONTAINER_ID)"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Confirm uninstallation
read -p "Are you sure you want to uninstall the container '$CONTAINER_NAME' (ID: $CONTAINER_ID)? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    status_message "error" "Uninstallation aborted."
fi

# Ask if related resources should be removed
read -p "Do you want to remove associated volumes, images, networks, and other resources? (y/n): " REMOVE_RESOURCES

# Stop and remove the container
docker stop "$CONTAINER_NAME" &>/dev/null 
status_message "success" "Stopped container '$CONTAINER_NAME'."

docker rm "$CONTAINER_NAME" &>/dev/null 
status_message "success" "Removed container '$CONTAINER_NAME'."

# Remove related resources if confirmed
if [[ "$REMOVE_RESOURCES" == "y" || "$REMOVE_RESOURCES" == "Y" ]]; then
    # Get associated image
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
    if [[ -n "$IMAGE" ]]; then
        docker rmi "$IMAGE" &>/dev/null
        status_message "success" "Removed image '$IMAGE'."
    fi

    # Remove dangling volumes and networks
    docker volume prune -f &>/dev/null
    status_message "success" "Cleaned up Docker volumes."

    docker network prune -f &>/dev/null
    status_message "success" "Cleaned up Docker networks."

    # Clean up unused Docker resources
    docker system prune -f &>/dev/null
    status_message "success" "Cleaned up unused Docker resources."
fi

# Check and remove Docker's container storage directory (specific to the container)
DOCKER_CONTAINER_DIR="/mnt/sec/apps/$CONTAINER_NAME"
if [[ -d "$DOCKER_CONTAINER_DIR" ]]; then
    read -p "The storage directory for container '$CONTAINER_NAME' exists at '$DOCKER_CONTAINER_DIR'. Do you want to remove it? (y/n): " REMOVE_DOCKER_FILES
    if [[ "$REMOVE_DOCKER_FILES" == "y" || "$REMOVE_DOCKER_FILES" == "Y" ]]; then
        rm -rf "$DOCKER_CONTAINER_DIR"
        status_message "success" "Removed Docker container storage directory '$DOCKER_CONTAINER_DIR'."
    fi
else
    status_message "info" "Directory '$DOCKER_CONTAINER_DIR' does not exist, skipping removal."
fi

status_message "success" "Uninstallation of container '$CONTAINER_NAME' completed successfully."
