#!/bin/bash
# purpose: this script installs guacamole LXC
# notes: https://github.com/itiligent/Easy-Guacamole-Installer

# Step 1: Create an empty LXC
echo "Creating an empty LXC container..."
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/create-lxc.sh)"

if [[ $? -ne 0 ]]; then
    echo "Failed to create the LXC container. Exiting."
    exit 1
fi

echo "LXC container created successfully."

# Step 2: Retrieve the CTID of the newly created container
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

# Step 4: Execute the non-root user setup script inside the container
pct enter "$CTID" <<EOF
  echo "Running the non-root user setup script inside the container..."
  bash -c "\$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-nonroot.sh)"
EOF

if [[ $? -ne 0 ]]; then
    echo "Failed to execute the non-root user setup script inside the LXC container. Exiting."
    exit 1
fi