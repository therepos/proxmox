#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/uninstallers/uninstall-nvidiact.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/uninstallers/uninstall-nvidiact.sh | bash

# apt-get purge -y nvidia-container-toolkit
# apt-get autoremove -y
# rm -rf /etc/docker/daemon.json
# rm -rf /etc/nvidia-container-runtime

#!/bin/bash

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

# Uninstall NVIDIA Container Toolkit Script
# Run this script as root or with sudo

echo "Starting NVIDIA Container Toolkit uninstallation process..."

# 1. Check if Docker is installed
if ! command -v docker &> /dev/null; then
    print_status "failure" "Docker is not installed, skipping NVIDIA Container Toolkit uninstallation."
    exit 1
else
    print_status "success" "Docker is installed"
fi

# 2. Remove NVIDIA Docker package (nvidia-docker2)
echo "Removing NVIDIA Docker package..."
if dpkg -l | grep -q "nvidia-docker2"; then
    run_silent sudo apt-get purge -y nvidia-docker2
    print_status "success" "nvidia-docker2 removed."
else
    print_status "failure" "nvidia-docker2 package not found."
fi

# 3. Remove NVIDIA Docker repository
echo "Removing NVIDIA Docker repository..."
if [ -f "/etc/apt/sources.list.d/nvidia-docker.list" ]; then
    run_silent sudo rm /etc/apt/sources.list.d/nvidia-docker.list
    print_status "success" "NVIDIA Docker repository removed."
else
    print_status "failure" "NVIDIA Docker repository not found."
fi

# 4. Remove NVIDIA Docker GPG key
echo "Removing NVIDIA Docker GPG key..."
if [ -f "/etc/apt/trusted.gpg.d/nvidia.asc" ]; then
    run_silent sudo rm /etc/apt/trusted.gpg.d/nvidia.asc
    print_status "success" "NVIDIA Docker GPG key removed."
else
    print_status "failure" "NVIDIA Docker GPG key not found."
fi

# 5. Remove NVIDIA runtime configuration from Docker
echo "Removing NVIDIA runtime configuration from Docker..."
if [ -d "/etc/systemd/system/docker.service.d" ]; then
    run_silent sudo rm -rf /etc/systemd/system/docker.service.d
    print_status "success" "NVIDIA runtime configuration removed from Docker."
else
    print_status "failure" "NVIDIA runtime configuration for Docker not found."
fi

# 6. Clean up unused packages and dependencies
echo "Cleaning up unused packages and dependencies..."
if run_silent sudo apt-get autoremove -y; then
    print_status "success" "Unused dependencies removed successfully."
else
    print_status "failure" "Failed to remove unused dependencies."
fi

# 7. Final system update
echo "Updating package list..."
if run_silent sudo apt-get update; then
    print_status "success" "System package list updated."
else
    print_status "failure" "Failed to update system package list."
fi

echo "NVIDIA Container Toolkit and related components have been uninstalled."

exit 0

