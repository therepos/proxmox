#!/bin/bash

# wget --header="Cache-Control: no-cache" -qO- https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-lxc.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-lxc.sh | bash

# Function to display usage instructions
usage() {
    echo "Usage: $0"
    echo "This script will prompt you for the container ID or name to uninstall."
    exit 1
}

# Check if the container identifier is provided as a command-line argument
if [ -z "$1" ]; then
    echo "Usage: $0 <container_name_or_id>"
    exit 1
fi

# Use the provided argument as the container identifier
CONTAINER_IDENTIFIER="$1"

# Check if the input is valid
if [ -z "$CONTAINER_IDENTIFIER" ]; then
    echo "No container identifier provided. Exiting."
    exit 1
fi

CONTAINER_ID=$(pct list | grep "$CONTAINER_IDENTIFIER" | awk '{print $1}')

if [ -z "$CONTAINER_ID" ]; then
    echo "No container with the identifier '$CONTAINER_IDENTIFIER' found."
    exit 1
fi

# Stop and destroy the container
echo "=== Stopping and destroying container with ID $CONTAINER_ID ==="
pct stop $CONTAINER_ID
pct destroy $CONTAINER_ID

# Find and remove associated service files
echo "=== Searching for and removing associated systemd service files ==="
SERVICE_FILE="/etc/systemd/system/${CONTAINER_IDENTIFIER}_service.service"
if [ -f "$SERVICE_FILE" ]; then
    rm -f "$SERVICE_FILE"
    echo "Service file removed: $SERVICE_FILE"
else
    echo "No service file found for $CONTAINER_IDENTIFIER."
fi

# Reload systemd daemon
echo "=== Reloading systemd daemon ==="
systemctl daemon-reload

# Remove any remaining container-specific folders
echo "=== Cleaning up remaining folders and configuration files ==="
LXC_FOLDER="/var/lib/lxc/$CONTAINER_IDENTIFIER"
if [ -d "$LXC_FOLDER" ]; then
    rm -rf "$LXC_FOLDER"
    echo "Removed LXC folder: $LXC_FOLDER"
else
    echo "No LXC folder found for $CONTAINER_IDENTIFIER."
fi

OUTPUT_FOLDER="/root/output"
if [ -d "$OUTPUT_FOLDER" ]; then
    rm -rf "$OUTPUT_FOLDER"
    echo "Removed output folder: $OUTPUT_FOLDER"
else
    echo "No output folder found."
fi

# Confirm cleanup
echo "=== Cleanup completed ==="

# Final message
echo "Container '$CONTAINER_IDENTIFIER' and associated files have been removed."
