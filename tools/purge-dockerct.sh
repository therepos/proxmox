#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/purge-dockerct.sh)"
# purpose: this script removes user-specified docker container(s) cleanly
# interactive: yes

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

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
fi

# Get all running container names
CONTAINER_NAMES=$(docker ps -a --format "{{.Names}}")

if [[ -z "$CONTAINER_NAMES" ]]; then
    status_message "error" "No Docker containers found."
fi

# Group containers by base name (before first hyphen)
declare -A CONTAINER_GROUPS
for NAME in $CONTAINER_NAMES; do
    BASE_NAME=$(echo "$NAME" | cut -d'-' -f1)
    CONTAINER_GROUPS["$BASE_NAME"]+="$NAME "
done

# Display grouped container options
echo "Available container groups for removal:"
OPTIONS=("${!CONTAINER_GROUPS[@]}")
PS3="#? "
select SELECTED_GROUP in "${OPTIONS[@]}"; do
    if [[ -n "$SELECTED_GROUP" ]]; then
        SELECTED_CONTAINERS=${CONTAINER_GROUPS["$SELECTED_GROUP"]}
        echo "You selected: $SELECTED_GROUP (Removing: $SELECTED_CONTAINERS)"
        break
    else
        echo "Invalid selection. Please try again."
    fi
done

# Confirm uninstallation
read -p "Are you sure you want to uninstall '$SELECTED_GROUP' (Containers: $SELECTED_CONTAINERS)? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    status_message "error" "Uninstallation aborted."
fi

# Stop and remove all containers in the selected group
for CONTAINER in $SELECTED_CONTAINERS; do
    docker stop "$CONTAINER" &>/dev/null
    status_message "success" "Stopped container '$CONTAINER'."

    docker rm "$CONTAINER" &>/dev/null
    status_message "success" "Removed container '$CONTAINER'."
done

# Ask if related resources should be removed
read -p "Do you want to remove associated volumes, images, networks, and other resources? (y/n): " REMOVE_RESOURCES

if [[ "$REMOVE_RESOURCES" == "y" || "$REMOVE_RESOURCES" == "Y" ]]; then
    # Identify and remove only unused images
    IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "$(echo "$SELECTED_GROUP" | sed 's/-/|/g')")
    for IMAGE in $IMAGES; do
        if [[ -n "$(docker ps -a --filter "ancestor=$IMAGE" --format "{{.ID}}")" ]]; then
            status_message "info" "Skipping image '$IMAGE' as it is still in use."
        else
            docker rmi "$IMAGE" &>/dev/null
            status_message "success" "Removed image '$IMAGE'."
        fi
    done

    # Remove only networks related to the selected containers
    NETWORKS=$(docker network ls --format "{{.Name}}" | grep -E "$(echo "$SELECTED_GROUP" | sed 's/-/|/g')")
    for NETWORK in $NETWORKS; do
        docker network rm "$NETWORK" &>/dev/null
        status_message "success" "Removed network '$NETWORK'."
    done

    # Remove only orphaned volumes
    docker volume prune -f &>/dev/null
    status_message "success" "Removed unused Docker volumes."

    # Clean up unused Docker resources
    docker system prune -a -f &>/dev/null
    status_message "success" "Cleaned up unused Docker resources."
fi

# Check and remove Docker's container storage directory (specific to the container group)
DOCKER_CONTAINER_DIR="/mnt/sec/apps/$SELECTED_GROUP"
if [[ -d "$DOCKER_CONTAINER_DIR" ]]; then
    read -p "The storage directory for '$SELECTED_GROUP' exists at '$DOCKER_CONTAINER_DIR'. Do you want to remove it? (y/n): " REMOVE_DOCKER_FILES
    if [[ "$REMOVE_DOCKER_FILES" == "y" || "$REMOVE_DOCKER_FILES" == "Y" ]]; then
        rm -rf "$DOCKER_CONTAINER_DIR"
        status_message "success" "Removed storage directory '$DOCKER_CONTAINER_DIR'."
    fi
else
    status_message "info" "Directory '$DOCKER_CONTAINER_DIR' does not exist, skipping removal."
fi

status_message "success" "Uninstallation of '$SELECTED_GROUP' (Containers: $SELECTED_CONTAINERS) completed successfully."