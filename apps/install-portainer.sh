#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-portainer.sh?$(date +%s))"
# purpose: this script installs portainer docker
# updating:
#  docker stop portainer
#  docker rm portainer
#  <rerun the script to get the latest version>
#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-portainer.sh)"
# purpose: this script installs or updates Portainer Docker

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
BLUE="\e[34mℹ\e[0m"

# Function to print status with green or red check marks
function status_message() { 
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    elif [[ "$status" == "info" ]]; then
        echo -e "${BLUE} ${message}"
    else
        echo -e "${RED} ${message}"
    fi
}

# Function to run commands silently
run_silent() {
    "$@" > /dev/null 2>&1
}

# Function to uninstall Portainer
uninstall_portainer() {
    status_message "success" "Stopping and removing Portainer container"
    run_silent docker stop portainer
    run_silent docker rm portainer
    run_silent docker volume rm portainer_data
    status_message "success" "Portainer has been successfully uninstalled"
}

# Check if Portainer is already installed
if docker ps -a | grep -q "portainer"; then
    echo "Portainer is already installed."
    echo "Choose an action:"
    echo "1) Keep existing installation"
    echo "2) Uninstall Portainer"
    echo "3) Update Portainer"
    read -p "#? " action_choice

    case "$action_choice" in
        2)
            uninstall_portainer
            exit 0
            ;;
        3)
            status_message "success" "Stopping and removing old Portainer container"
            run_silent docker stop portainer
            run_silent docker rm portainer
            status_message "success" "Pulling latest Portainer image"
            run_silent docker pull portainer/portainer-ce:lts
            ;;
        *)
            status_message "success" "Keeping existing Portainer installation."
            exit 0
            ;;
    esac
else
    status_message "success" "Pulling Portainer LTS image"
    run_silent docker pull portainer/portainer-ce:lts
fi

# Automatically detect the Docker host IP address
DOCKER_HOST_IP=$(hostname -I | awk '{print $1}')

# Run Portainer as a container with updated ports
status_message "success" "Running Portainer container"
run_silent docker run -d \
    -p 8000:8000 \
    -p 9443:9443 \
    --name portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    -v /mnt/sec/apps:/mnt/sec/apps:z \
    portainer/portainer-ce:lts

# Wait for Portainer to start
sleep 5

# Verify if Portainer is running
if docker ps | grep -q portainer; then
    status_message "success" "Portainer is up and running at https://$DOCKER_HOST_IP:9443"
else
    status_message "failure" "Portainer container failed to start"
fi

# Final completion message
status_message "success" "Portainer setup complete!"
