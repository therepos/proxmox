#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/purge-lxc.sh?$(date +%s))"
# purpose: removes a user-specified LXC container

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
containers=$(pct list | tail -n +2 | awk '{print $1":"$NF}')
if [ -z "$containers" ]; then
    status_message "failure" "No containers found."
fi

# Display CT IDs and Names for selection
echo -e "Select container by number (ID: Name):"
PS3="#? "
select container_entry in $containers; do
    if [ -n "$container_entry" ]; then
        CT_ID=$(echo "$container_entry" | awk -F':' '{print $1}')
        container_name=$(echo "$container_entry" | awk -F':' '{print $2}')
        echo "You selected container: $container_name (ID: $CT_ID)"
        break
    fi
    echo "Invalid choice. Please select a valid container."
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
if [ $? -eq 0 ]; then
    status_message "success" "Container '$container_name' removed."
else
    status_message "failure" "Failed to remove container '$container_name'."
fi

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

# Final message
status_message "success" "Container '$container_name' has been cleanly uninstalled."
exit 0
