#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-guacamole.sh)"
# purpose: this script installs guacamole lxc
# =====
# notes:
# source: https://github.com/itiligent/Easy-Guacamole-Installer

# Step 1: Create an empty LXC
echo "Creating an empty LXC container..."
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/create-lxc.sh)"

if [[ $? -ne 0 ]]; then
    echo "Failed to create the LXC container. Exiting."
    exit 1
fi

echo "LXC container created successfully."

# Step 2: Retrieve the CTID of the newly created container
# Assuming the latest container ID is the newly created one
CTID=$(pvesh get /cluster/nextid)
CTID=$((CTID - 1))

echo "New LXC container has been created with CTID: $CTID"

# Wait for the container to fully initialize
echo "Waiting for the LXC container to start..."
sleep 5

# Step 3: Start the container if it's not already running
if ! pct status "$CTID" | grep -q "status: running"; then
    echo "Starting the LXC container..."
    pct start "$CTID"
    sleep 5
fi

# Step 4: Execute the second script inside the container
echo "Entering LXC container with CTID: $CTID to execute the second script..."
pct exec "$CTID" -- bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-nonroot.sh)"

if [[ $? -ne 0 ]]; then
    echo "Failed to execute the second script inside the LXC container. Exiting."
    exit 1
fi

echo "Second script executed successfully in the container."

# Step 5: Run the final setup script inside the container
echo "Running the final setup script inside the LXC container..."
sudo -u admin bash -c "wget https://raw.githubusercontent.com/itiligent/Guacamole-Install/main/1-setup.sh && chmod +x 1-setup.sh && ./1-setup.sh"

if [[ $? -ne 0 ]]; then
    echo "Failed to execute the final setup script inside the LXC container. Exiting."
    exit 1
fi

echo "Final setup script executed successfully."

# Completion message
echo "LXC container setup and configuration completed successfully."


