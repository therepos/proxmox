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
    elif [[ "$status" == "info" ]]; then
        echo -e "${RESET} ${message}"  # Use blue ℹ for info
    else
        echo -e "${RED} ${message}"
    fi
}

# Check if Docker is installed
if ! command -v docker &>/dev/null; then
    status_message "error" "Docker is not installed. Please install Docker first."
    exit 1
fi

# Get all running container names
CONTAINER_NAMES=$(docker ps -a --format "{{.Names}}")

if [[ -z "$CONTAINER_NAMES" ]]; then
    status_message "error" "No Docker containers found."
    exit 1
fi

# Group containers based on their base name
declare -A CONTAINER_GROUPS
declare -A CONTAINER_FULL_NAMES

for NAME in $CONTAINER_NAMES; do
    BASE_NAME=$(echo "$NAME" | cut -d'-' -f1)
    CONTAINER_GROUPS["$BASE_NAME"]+="$NAME "
    CONTAINER_FULL_NAMES["$NAME"]="$NAME"
done

# Adjust grouping: If a base name has only one service, use the full name instead
declare -A FINAL_GROUPS
for BASE_NAME in "${!CONTAINER_GROUPS[@]}"; do
    CONTAINERS=(${CONTAINER_GROUPS["$BASE_NAME"]})  # Convert to array
    if [[ ${#CONTAINERS[@]} -eq 1 ]]; then
        FINAL_GROUPS["${CONTAINERS[0]}"]="${CONTAINERS[0]}"
    else
        FINAL_GROUPS["$BASE_NAME"]="${CONTAINER_GROUPS["$BASE_NAME"]}"
    fi
done

# Display grouped container options
echo "Available container groups for removal:"
OPTIONS=("${!FINAL_GROUPS[@]}")
PS3="#? "
select SELECTED_GROUP in "${OPTIONS[@]}"; do
    if [[ -n "$SELECTED_GROUP" ]]; then
        SELECTED_CONTAINERS=${FINAL_GROUPS["$SELECTED_GROUP"]}
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
    exit 1
fi

# Stop and remove all containers in the selected group
for CONTAINER in $SELECTED_CONTAINERS; do
    docker stop "$CONTAINER" &>/dev/null
    status_message "success" "Stopped container '$CONTAINER'."

    docker rm "$CONTAINER" &>/dev/null
    status_message "success" "Removed container '$CONTAINER'."
done

# Automatically remove related resources (no prompt)
status_message "info" "Removing related resources..."

# Identify and remove only images linked to the selected containers
IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E "$(echo "$SELECTED_GROUP" | sed 's/-/|/g')")
if [[ -n "$IMAGES" ]]; then
    for IMAGE in $IMAGES; do
        if [[ -z "$(docker ps -a --filter "ancestor=$IMAGE" --format "{{.ID}}")" ]]; then
            docker rmi "$IMAGE" &>/dev/null
            status_message "success" "Removed image '$IMAGE'."
        else
            status_message "info" "Skipping image '$IMAGE' as it is still in use."
        fi
    done
else
    status_message "info" "No related images found."
fi

# Remove only networks related to the selected containers
NETWORKS=$(docker network ls --format "{{.Name}}" | grep -E "$(echo "$SELECTED_GROUP" | sed 's/-/|/g')")
if [[ -n "$NETWORKS" ]]; then
    for NETWORK in $NETWORKS; do
        docker network rm "$NETWORK" &>/dev/null
        status_message "success" "Removed network '$NETWORK'."
    done
else
    status_message "info" "No related networks found."
fi

# Remove only volumes linked to the selected containers
VOLUME_FOUND=false
for CONTAINER in $SELECTED_CONTAINERS; do
    VOLUMES=$(docker inspect -f '{{ range .Mounts }}{{ .Name }} {{ end }}' "$CONTAINER" 2>/dev/null)
    if [[ -n "$VOLUMES" ]]; then
        VOLUME_FOUND=true
        for VOLUME in $VOLUMES; do
            docker volume rm "$VOLUME" &>/dev/null
            status_message "success" "Removed volume '$VOLUME'."
        done
    fi
done
if [[ "$VOLUME_FOUND" == false ]]; then
    status_message "info" "No related volumes found."
fi

# Ensure all images related to the selected group are removed
IMAGES=$(docker ps -a --filter "name=$SELECTED_GROUP" --format "{{.Image}}")
if [[ -n "$IMAGES" ]]; then
    echo "$IMAGES" | xargs -r docker rmi -f &>/dev/null
    status_message "success" "Removed all images related to '$SELECTED_GROUP'."
else
    status_message "info" "No images found for '$SELECTED_GROUP'."
fi

# Remove untagged (dangling) images
DANGLING_IMAGES=$(docker images -f "dangling=true" -q)
if [[ -n "$DANGLING_IMAGES" ]]; then
    echo "$DANGLING_IMAGES" | xargs -r docker rmi -f &>/dev/null
    status_message "success" "Removed all dangling images."
else
    status_message "info" "No dangling images found."
fi

# Force remove all networks related to the selected group
NETWORKS=$(docker network ls --format "{{.ID}} {{.Name}}" | grep "$SELECTED_GROUP" | awk '{print $1}')
if [[ -n "$NETWORKS" ]]; then
    echo "$NETWORKS" | xargs -r docker network rm &>/dev/null
    status_message "success" "Removed all networks related to '$SELECTED_GROUP'."
else
    status_message "info" "No networks found for '$SELECTED_GROUP'."
fi

# Ensure orphaned volumes are removed
VOLUMES=$(docker volume ls --quiet)
if [[ -n "$VOLUMES" ]]; then
    echo "$VOLUMES" | xargs -r docker volume rm &>/dev/null
    status_message "success" "Removed all orphaned volumes."
else
    status_message "info" "No orphaned volumes found."
fi

# Clean up unused build cache
docker builder prune --all --force &>/dev/null
status_message "success" "Removed all unused build cache."

# Perform a final forced prune to remove anything leftover
docker system prune -a --volumes --force &>/dev/null
status_message "success" "Final system prune completed. No related resources should remain."

# Ensure storage check happens at the end
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
