#!/bin/bash

# Variables
TEMPLATE="/var/lib/vz/template/cache/debian-12-standard_12.7-1_amd64.tar.zst"
STORAGE="local-zfs"  # Using local-zfs as the storage backend for LXC containers

# Check if the template exists at the specified path
if [ ! -f "$TEMPLATE" ]; then
    echo "Template not found at $TEMPLATE"
    exit 1
fi

# Find the next available container ID (dynamically determined)
CONTAINER_ID=$(sudo pct list | awk 'NR>1 {print $1}' | sort -n | tail -n 1)
CONTAINER_ID=$((CONTAINER_ID + 1))

# Prompt for the container name (e.g., CT101)
echo "Enter the desired container name (e.g., CT101):"
read CONTAINER_NAME

# Create the container
echo "Creating container with ID $CONTAINER_ID using template $TEMPLATE..."
sudo pct create $CONTAINER_ID $TEMPLATE -storage $STORAGE

# Update the container's name in the configuration file
echo "Setting the container name to $CONTAINER_NAME..."
sudo sed -i "s/^hostname:.*/hostname: $CONTAINER_NAME/" /etc/pve/lxc/$CONTAINER_ID.conf

# Start the container
echo "Starting container $CONTAINER_ID..."
sudo pct start $CONTAINER_ID

# Enter the container to modify the password
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
echo "Container $CONTAINER_ID created successfully with the name $CONTAINER_NAME and is now passwordless."
echo "You can access the container with: sudo pct enter $CONTAINER_ID"
