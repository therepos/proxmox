#!/bin/bash

# Step 1: Create an empty LXC
echo "Creating an empty LXC container..."
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/install-lxc.sh)"

if [[ $? -ne 0 ]]; then
    echo "Failed to create the LXC container. Exiting."
    exit 1
fi

echo "LXC container created successfully."

# Step 2: Retrieve the CTID of the newly created container
# Assuming the latest container ID is the newly created one
CTID=$(pvesh get /cluster/nextid)
CTID=$((CTID - 1))

echo "Entering LXC container with CTID: $CTID..."

# Execute the second script inside the container
pct enter "$CTID" -- bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-nonroot.sh)"

if [[ $? -ne 0 ]]; then
    echo "Failed to execute the second script inside the LXC container. Exiting."
    exit 1
fi

echo "Second script executed successfully in the container."

# Step 3: Run the final setup script inside the container
echo "Running the final setup script inside the LXC container..."

pct enter "$CTID" -- bash -c "wget https://raw.githubusercontent.com/itiligent/Guacamole-Install/main/1-setup.sh && chmod +x 1-setup.sh && ./1-setup.sh"

if [[ $? -ne 0 ]]; then
    echo "Failed to execute the final setup script inside the LXC container. Exiting."
    exit 1
fi

echo "Final setup script executed successfully."

# Completion message
echo "LXC container setup and configuration completed successfully."
