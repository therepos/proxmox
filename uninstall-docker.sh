#!/bin/bash

# Function to print status with green or red check marks
print_status() {
    if [ "$1" == "success" ]; then
        echo -e "\033[0;32m✔\033[0m $2"  # Green check mark
    else
        echo -e "\033[0;31m✘\033[0m $2"  # Red cross mark
    fi
}

# Stop Docker service
print_status "success" "Stopping Docker service"
systemctl stop docker

# Remove Docker packages
print_status "success" "Removing Docker packages"
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras

# Remove ZFS if you want to clean it up as well
print_status "success" "Removing ZFS utilities (optional)"
apt-get purge -y zfsutils-linux

# Remove Docker configuration files and directories
print_status "success" "Removing Docker configuration files and directories"
rm -rf /etc/docker /var/lib/docker /var/lib/containerd /var/run/docker

# Clean up any remaining Docker-related files (volumes, networks, etc.)
print_status "success" "Removing Docker volumes, networks, and images"
docker system prune -af

# Remove Docker from systemd
print_status "success" "Disabling and removing Docker systemd service"
systemctl disable docker
rm /etc/systemd/system/docker.service /etc/systemd/system/docker.socket

# Remove Docker's GPG key and repository
print_status "success" "Removing Docker GPG key and repository"
rm /etc/apt/sources.list.d/docker.list
rm /etc/apt/trusted.gpg.d/docker-archive-keyring.gpg

# Remove other Docker-related files (optional)
print_status "success" "Removing other Docker-related files"
rm -rf /var/lib/docker-compose

# Clean up any orphaned packages
print_status "success" "Cleaning up orphaned packages"
apt-get autoremove -y
apt-get clean

# Verify Docker removal
if ! command -v docker &> /dev/null; then
    print_status "success" "Docker successfully removed"
else
    print_status "failure" "Docker removal failed"
fi

# Final completion message
print_status "success" "Docker uninstallation complete!"
