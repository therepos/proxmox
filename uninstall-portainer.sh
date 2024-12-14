#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-portainer.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-portainer.sh | bash

# Function to print status with green or red check marks
print_status() {
    if [ "$1" == "success" ]; then
        echo -e "\033[0;32m✔\033[0m $2"  # Green check mark
    else
        echo -e "\033[0;31m✘\033[0m $2"  # Red cross mark
    fi
}

# Function to run commands silently, suppressing output
run_silent() {
    "$@" > /dev/null 2>&1
}

# Automatically detect the Docker host IP address
DOCKER_HOST_IP=$(hostname -I | awk '{print $1}')

# Check if Portainer container exists
if docker ps -a | grep -q portainer; then
    print_status "success" "Stopping Portainer container"
    run_silent docker stop portainer
    print_status "success" "Removing Portainer container"
    run_silent docker rm portainer
else
    print_status "failure" "Portainer container not found"
fi

# Check if Portainer image exists
if docker images | grep -q portainer/portainer-ce; then
    print_status "success" "Removing Portainer image"
    run_silent docker rmi portainer/portainer-ce
else
    print_status "failure" "Portainer image not found"
fi

# Check if Portainer data volume exists
if docker volume ls | grep -q portainer_data; then
    print_status "success" "Removing Portainer data volume"
    run_silent docker volume rm portainer_data
else
    print_status "failure" "Portainer data volume not found"
fi

# Clean up any orphaned Docker volumes and networks
print_status "success" "Cleaning up orphaned Docker volumes and networks"
run_silent docker system prune -af

# Remove any remaining Portainer configuration files and directories
print_status "success" "Removing any remaining Portainer configuration files and directories"
run_silent rm -rf /var/lib/docker/volumes/portainer_data

# Clean up Docker-related files (optional)
print_status "success" "Cleaning up any remaining Docker-related files"
run_silent rm -rf /var/lib/docker/containers/* /var/lib/docker/images/* /var/lib/docker/volumes/*

# Final completion message
print_status "success" "Portainer uninstallation complete!"
