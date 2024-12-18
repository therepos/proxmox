#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-lxc.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-lxc.sh | bash

# Function to display usage instructions
usage() {
    echo "Usage: $0 <container_name_or_id>"
    echo "Or run without arguments to be prompted for a container ID or name."
    exit 1
}

# Check if the container identifier is provided as an argument
if [ -z "$1" ]; then
    echo "No container identifier provided. Switching to interactive mode."
    read -p "Enter the container ID or name to uninstall: " CONTAINER_IDENTIFIER
else
    CONTAINER_IDENTIFIER="$1"
fi

# Validate the provided container identifier
CONTAINER_ID=$(pct list | awk -v id="$CONTAINER_IDENTIFIER" '$1 == id || $NF == id {print $1}')
if [ -z "$CONTAINER_ID" ]; then
    echo "No container with the identifier '$CONTAINER_IDENTIFIER' found."
    exit 1
fi

# Confirm uninstallation
echo "Container with ID $CONTAINER_ID has been identified for removal."
read -p "Are you sure you want to stop and destroy this container? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborting uninstallation."
    exit 1
fi

# Stop and destroy the container
echo "=== Stopping and destroying container with ID $CONTAINER_ID ==="
pct stop $CONTAINER_ID || echo "Failed to stop container $CONTAINER_ID. It may already be stopped."
pct destroy $CONTAINER_ID || echo "Failed to destroy container $CONTAINER_ID."

# Remove associated systemd service files
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

# Remove remaining container-specific folders
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



