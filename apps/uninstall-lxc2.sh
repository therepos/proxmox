#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/uninstall-lxc.sh)"

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to display status messages with color
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "\n${GREEN} ${message}${RESET}"
    else
        echo -e "\n${RED} ${message}${RESET}"
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

# Step 2: Confirm uninstallation
read -p "Are you sure you want to uninstall container '$container' (ID: $CT_ID)? (y/n): " confirmation
if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    status_message "failure" "Uninstallation canceled."
fi

# Step 3: Stop the container if it's running
CONTAINER_STATUS=$(pct status "$CT_ID" 2>/dev/null)

if [[ "$CONTAINER_STATUS" == "status: running" ]]; then
    echo "Stopping container '$container'..."
    pct stop "$CT_ID" && status_message "success" "Container '$container' stopped." || status_message "failure" "Failed to stop container '$container'."
else
    status_message "success" "Container '$container' is already stopped."
fi

# Step 4: Remove the container
echo "Removing container '$container'..."
pct destroy "$CT_ID" && status_message "success" "Container '$container' removed." || status_message "failure" "Failed to remove container '$container'."

# Step 5: Remove associated data if needed
# Check if any data directory exists (e.g., mount points or persistent data)
DATA_DIR="/var/lib/lxc/$CT_ID"
if [ -d "$DATA_DIR" ]; then
    echo "Removing data directory for '$container' at $DATA_DIR..."
    rm -rf "$DATA_DIR" && status_message "success" "Data directory for '$container' removed." || status_message "failure" "Failed to remove data directory for '$container'."
fi

# Step 6: Remove container's configuration file
CONF_FILE="/etc/pve/lxc/$CT_ID.conf"
if [ -f "$CONF_FILE" ]; then
    echo "Removing configuration file for '$container' at $CONF_FILE..."
    rm -f "$CONF_FILE" && status_message "success" "Configuration file for '$container' removed." || status_message "failure" "Failed to remove configuration file for '$container'."
fi

# Step 7: Remove network settings or interfaces
# Check for specific container-related network interfaces or settings
NETWORK_CONFIG="/etc/network/interfaces.d/$CT_ID"
if [ -f "$NETWORK_CONFIG" ]; then
    echo "Removing custom network config for '$container' at $NETWORK_CONFIG..."
    rm -f "$NETWORK_CONFIG" && status_message "success" "Network config for '$container' removed." || status_message "failure" "Failed to remove network config for '$container'."
fi

# Step 8: Remove log files
LOG_DIR="/var/log/lxc/$CT_ID"
if [ -d "$LOG_DIR" ]; then
    echo "Removing log files for '$container' at $LOG_DIR..."
    rm -rf "$LOG_DIR" && status_message "success" "Log files for '$container' removed." || status_message "failure" "Failed to remove log files for '$container'."
fi

# Step 9: Remove any backup files
BACKUP_DIR="/var/lib/vz/dump"
if [ -d "$BACKUP_DIR" ]; then
    echo "Removing backup files for '$container' in $BACKUP_DIR..."
    rm -f "$BACKUP_DIR/$CT_ID.tar.gz" && status_message "success" "Backup files for '$container' removed." || status_message "failure" "Failed to remove backup files for '$container'."
fi

# Optional: Clean up any custom volumes or associated configuration files
# Uncomment and modify the following section if additional files need cleanup
# CUSTOM_VOLUMES=("/path/to/volume1" "/path/to/volume2")
# for volume in "${CUSTOM_VOLUMES[@]}"; do
#     if [ -d "$volume" ]; then
#         echo "Removing custom volume or directory: $volume..."
#         rm -rf "$volume" && status_message "success" "Custom volume '$volume' removed." || status_message "failure" "Failed to remove custom volume '$volume'."
#     fi
# done

status_message "success" "Container '$container' has been cleanly uninstalled."
exit 0
