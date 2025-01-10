#!/bin/bash

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

# List Docker containers
CONTAINERS=$(docker ps -a --format "{{.Names}}")
if [[ -z "$CONTAINERS" ]]; then
    status_message "error" "No Docker containers found."
fi

echo "Available Docker containers:"
select CONTAINER_NAME in $CONTAINERS; do
    if [[ -n "$CONTAINER_NAME" ]]; then
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Confirm uninstallation
read -p "Are you sure you want to uninstall the container '$CONTAINER_NAME'? (y/n): " CONFIRM
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

status_message "success" "Uninstallation of container '$CONTAINER_NAME' completed successfully."
