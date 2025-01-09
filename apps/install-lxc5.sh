#!/bin/bash

# Variables
TEMPLATE="/var/lib/vz/template/cache/debian-12-standard_12.7-1_amd64.tar.zst"
STORAGE="local-zfs"  # Using local-zfs as the storage backend for LXC containers

# Check if template exists at the specified path
if [ ! -f "$TEMPLATE" ]; then
    echo "Template not found at $TEMPLATE"
    exit 1
fi

# Find the next available container ID
CONTAINER_ID=$(sudo pct list | awk 'NR>1 {print $1}' | sort -n | tail -n 1)
CONTAINER_ID=$((CONTAINER_ID + 1))

# Create the container
echo "Creating container with ID $CONTAINER_ID using template $TEMPLATE..."
sudo pct create $CONTAINER_ID $TEMPLATE -storage $STORAGE

# Start the container
echo "Starting container $CONTAINER_ID..."
sudo pct start $CONTAINER_ID

# Enter the container to modify password
echo "Entering the container to disable root password..."
sudo pct enter $CONTAINER_ID <<EOF
    # Disable root password
    passwd -d root

    # Exit from container
    exit
EOF

# Reboot the container to apply changes
echo "Rebooting container $CONTAINER_ID to apply changes..."
sudo pct reboot $CONTAINER_ID

# Display success message
echo "Container $CONTAINER_ID created successfully and is now passwordless."
echo "You can access the container with: sudo pct enter $CONTAINER_ID"
