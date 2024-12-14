#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-docker.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-docker.sh | bash

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

# Stop Docker service
print_status "success" "Stopping Docker service"
if systemctl stop docker > /dev/null 2>&1; then
    print_status "success" "Docker service stopped"
else
    print_status "failure" "Docker service not found or already stopped"
fi

# Remove Docker packages
print_status "success" "Removing Docker packages"
if run_silent apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras -q; then
    print_status "success" "Docker packages removed"
else
    print_status "failure" "Docker packages removal failed"
fi

# Remove ZFS if you want to clean it up as well
print_status "success" "Removing ZFS utilities (optional)"
if run_silent apt-get purge -y zfsutils-linux -q; then
    print_status "success" "ZFS utilities removed"
else
    print_status "failure" "ZFS utilities removal failed"
fi

# Remove Docker configuration files and directories
print_status "success" "Removing Docker configuration files and directories"
if run_silent rm -rf /etc/docker /var/lib/docker /var/lib/containerd /var/run/docker; then
    print_status "success" "Docker configuration files removed"
else
    print_status "failure" "Failed to remove Docker configuration files"
fi

# Clean up any remaining Docker-related files (volumes, networks, etc.)
print_status "success" "Removing Docker volumes, networks, and images"
if run_silent docker system prune -af; then
    print_status "success" "Docker volumes and networks removed"
else
    print_status "failure" "Docker volumes and networks removal failed"
fi

# Remove Docker from systemd
print_status "success" "Disabling and removing Docker systemd service"
if run_silent systemctl disable docker && run_silent rm /etc/systemd/system/docker.service /etc/systemd/system/docker.socket; then
    print_status "success" "Docker systemd service disabled and removed"
else
    print_status "failure" "Docker systemd service removal failed"
fi

# Remove Docker's GPG key and repository
print_status "success" "Removing Docker GPG key and repository"
if run_silent rm /etc/apt/sources.list.d/docker.list && run_silent rm /etc/apt/trusted.gpg.d/docker-archive-keyring.gpg; then
    print_status "success" "Docker GPG key and repository removed"
else
    print_status "failure" "Failed to remove Docker GPG key and repository"
fi

# Remove other Docker-related files (optional)
print_status "success" "Removing other Docker-related files"
if run_silent rm -rf /var/lib/docker-compose; then
    print_status "success" "Other Docker-related files removed"
else
    print_status "failure" "Failed to remove other Docker-related files"
fi

# Clean up any orphaned packages
print_status "success" "Cleaning up orphaned packages"
if run_silent apt-get autoremove -y -q && run_silent apt-get clean -q; then
    print_status "success" "Orphaned packages cleaned up"
else
    print_status "failure" "Orphaned package cleanup failed"
fi

# Verify Docker removal
if ! command -v docker &> /dev/null; then
    print_status "success" "Docker successfully removed"
else
    print_status "failure" "Docker removal failed"
fi

# Final completion message
print_status "success" "Docker uninstallation complete!"
