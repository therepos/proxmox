#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/installers/install-portainer.sh)"

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

# Pull the Portainer image
print_status "success" "Pulling Portainer image"
run_silent docker pull portainer/portainer-ce

# Run Portainer as a container
print_status "success" "Running Portainer container"
run_silent docker run -d \
    -p 9000:9000 \
    --name portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce

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
