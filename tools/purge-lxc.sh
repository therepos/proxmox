#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/uninstall-lxc.sh)"
# purpose: this script removes user-specified lxc container

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to display status messages with color
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}${RESET}"
    else
        echo -e "${RED} ${message}${RESET}"
        exit 1
    fi
}

# Step 1: List all available containers with their IDs and names for user selection
containers=$(pct list | tail -n +2 | awk '{print $1, "-", $NF}')
if [ -z "$containers" ]; then
    status_message "failure" "No containers found."
fi

# Display header and containers for user selection
echo -e "Select container by number:"
select container_name in $(echo "$containers" | awk -F ' - ' '{print $2}'); do
    if [ -n "$container_name" ]; then
        CT_ID=$(echo "$containers" | grep " - $container_name$" | awk -F ' - ' '{print $1}')
        echo "You selected container: $container_name (ID: $CT_ID)"
        break
    else
        echo "Invalid choice. Please select a valid container."
    fi
done

# Confirm uninstallation
read -p "Are you sure you want to uninstall container (ID: $CT_ID)? (y/n): " confirmation
if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    status_message "failure" "Uninstallation canceled."
fi

# Step 3: Stop the container if it's running
CONTAINER_STATUS=$(pct status "$CT_ID" 2>/dev/null)

if [[ "$CONTAINER_STATUS" == "status: running" ]]; then
    pct stop "$CT_ID" &>/dev/null
    status_message "success" "Container '$container_name' stopped."
else
    status_message "success" "Container '$container_name' is already stopped."
fi

# Step 4: Remove the container
pct destroy "$CT_ID" &>/dev/null
status_message "success" "Container '$container_name' removed."

# Step 5: Remove associated data if needed
DATA_DIR="/var/lib/lxc/$CT_ID"
if [ -d "$DATA_DIR" ]; then
    rm -rf "$DATA_DIR" &>/dev/null
    status_message "success" "Data directory for '$container_name' removed."
fi

# Step 6: Remove backup files
BACKUP_DIR="/var/lib/vz/dump"
if [ -f "$BACKUP_DIR/$CT_ID.tar.gz" ]; then
    rm -f "$BACKUP_DIR/$CT_ID.tar.gz" &>/dev/null
    status_message "success" "Backup files for '$container_name' removed."
fi

# Optional: Clean up additional resources
# Uncomment and modify the following if needed:
# CUSTOM_VOLUMES=("/path/to/volume1" "/path/to/volume2")
# for volume in "${CUSTOM_VOLUMES[@]}"; do
#     if [ -d "$volume" ]; then
#         rm -rf "$volume" &>/dev/null
#         status_message "success" "Custom volume '$volume' removed."
#     fi
# done

# Final message
status_message "success" "Container '$container_name' has been cleanly uninstalled."
exit 0
