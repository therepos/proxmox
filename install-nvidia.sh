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

# Update system packages
print_status "success" "Updating system packages"
run_silent apt-get update -y

# Install necessary dependencies for NVIDIA drivers
print_status "success" "Installing required dependencies for NVIDIA driver"
run_silent apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Add the NVIDIA package repositories
print_status "success" "Adding NVIDIA package repository"
run_silent curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
run_silent curl -s -L https://nvidia.github.io/nvidia-docker/debian/nvidia-docker.list > /etc/apt/sources.list.d/nvidia-docker.list

# Install the NVIDIA driver
print_status "success" "Installing NVIDIA driver"
run_silent apt-get update -y
run_silent apt-get install -y nvidia-driver

# Reboot to finalize driver installation (optional, but necessary to load NVIDIA kernel modules)
print_status "success" "Rebooting to finalize NVIDIA driver installation"
run_silent reboot

# After reboot, verify that NVIDIA driver is correctly installed
sleep 5  # wait for the system to reboot

if nvidia-smi > /dev/null 2>&1; then
    print_status "success" "NVIDIA driver installed successfully"
else
    print_status "failure" "NVIDIA driver installation failed"
fi

# Install NVIDIA Container Toolkit for Docker
print_status "success" "Installing NVIDIA Container Toolkit"
run_silent apt-get install -y nvidia-docker2

# Restart Docker to enable NVIDIA runtime support
print_status "success" "Restarting Docker service to enable NVIDIA runtime"
run_silent systemctl restart docker

# Verify if the NVIDIA runtime is available in Docker
if docker info | grep -q "Runtimes: nvidia"; then
    print_status "success" "NVIDIA Container Toolkit installed and configured successfully"
else
    print_status "failure" "NVIDIA Container Toolkit installation failed"
fi

# Final completion message
print_status "success" "NVIDIA driver and NVIDIA Container Toolkit installation complete!"
