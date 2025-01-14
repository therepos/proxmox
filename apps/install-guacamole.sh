#!/bin/bash
# purpose: this script installs guacamole LXC
# notes: https://github.com/itiligent/Easy-Guacamole-Installer

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# Step 1: Create an empty LXC
status_message "success" "Creating an empty LXC container..."
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/create-lxc.sh)"

if [[ $? -ne 0 ]]; then
    status_message "error" "Failed to create the LXC container. Exiting."
else
    status_message "success" "LXC container created successfully."
fi

# Step 2: Retrieve the CTID of the newly created container
CTID=$(pvesh get /cluster/nextid)
CTID=$((CTID - 1))

status_message "success" "New LXC container has been created with CTID: $CTID"

# Wait for the container to fully initialize
status_message "success" "Waiting for the LXC container to start..."
sleep 5

# Step 3: Start the container if it's not already running
if ! pct status "$CTID" | grep -q "status: running"; then
    status_message "success" "Starting the LXC container..."
    pct start "$CTID" &> /dev/null
    sleep 5
fi

# Step 4: Execute the non-root user setup script inside the container
pct enter "$CTID" <<EOF &> /dev/null
  echo "Running the non-root user setup script inside the container..."
  bash -c "\$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-nonroot.sh)"
EOF

if [[ $? -ne 0 ]]; then
    status_message "error" "Failed to execute the non-root user setup script inside the LXC container. Exiting."
else
    status_message "success" "Non-root user setup script executed successfully inside the container."
fi
