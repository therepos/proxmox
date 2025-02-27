#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-portainer.sh)"
# purpose: this script installs portainer docker
# updating:
#  docker stop portainer
#  docker rm portainer
#  <rerun the script to get the latest version>

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

# Function to uninstall Portainer
uninstall_portainer() {
    print_status "success" "Stopping and removing Portainer container"
    run_silent docker stop portainer
    run_silent docker rm portainer
    run_silent docker volume rm portainer_data
    print_status "success" "Portainer has been successfully uninstalled"
}

# Check if Portainer is already installed
if docker ps -a | grep -q "portainer"; then
    echo "Portainer is already installed."
    read -p "Do you want to uninstall it? [y/N]: " uninstall_response
    if [[ "$uninstall_response" =~ ^[Yy]$ ]]; then
        uninstall_portainer
        exit 0
    else
        print_status "success" "Existing Portainer installation retained."
        exit 0
    fi
fi

# Automatically detect the Docker host IP address
DOCKER_HOST_IP=$(hostname -I | awk '{print $1}')

# Pull the Portainer image
print_status "success" "Pulling Portainer image"
run_silent docker pull portainer/portainer-ce:latest

# Run Portainer as a container
print_status "success" "Running Portainer container"
run_silent docker run -d \
    -p 9000:9000 \
    --name portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    -v /mnt/sec/apps:/mnt/sec/apps \  # Grant access to `/mnt/sec/apps/`
    portainer/portainer-ce:latest

# Wait for Portainer to start
sleep 5

# Verify if Portainer is running
if docker ps | grep -q portainer; then
    print_status "success" "Portainer is up and running at http://$DOCKER_HOST_IP:9000"
else
    print_status "failure" "Portainer container failed to start"
fi

# Final completion message
print_status "success" "Portainer installation complete!"
