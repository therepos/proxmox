#!/bin/bash

# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/util/sambashare.sh)"

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to output status messages with color symbols
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

# Define the directory to be shared
SHARE_DIR="/mnt/nvme0n1/apps/jellyfin"
SHARE_NAME="jellyfin_share"

# Check if the directory exists
if [ ! -d "$SHARE_DIR" ]; then
    status_message "error" "Error: Directory $SHARE_DIR does not exist!"
fi

# Install Samba if not already installed
if ! command -v samba &> /dev/null; then
    echo "Samba not found. Installing..."
    sudo apt update && sudo apt install -y samba
    status_message "success" "Samba installed successfully."
else
    status_message "success" "Samba is already installed."
fi

# Backup the original Samba config
echo "Backing up existing Samba configuration..."
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
status_message "success" "Samba configuration backed up successfully."

# Create the Samba share configuration
echo "Creating Samba share configuration..."
echo "
[$SHARE_NAME]
   path = $SHARE_DIR
   browseable = yes
   writable = yes
   guest ok = yes
   read only = no
" | sudo tee -a /etc/samba/smb.conf > /dev/null
status_message "success" "Samba share configuration created for $SHARE_NAME."

# Set appropriate permissions for the shared directory
echo "Setting permissions for $SHARE_DIR..."
sudo chmod -R 777 "$SHARE_DIR"
status_message "success" "Permissions set for $SHARE_DIR."

# Restart Samba service to apply the configuration
echo "Restarting Samba service..."
sudo systemctl restart smbd
status_message "success" "Samba service restarted successfully."

# Optionally, add Samba user (if needed)
# Uncomment and replace 'username' with your desired Samba username
# echo "Adding Samba user..."
# sudo smbpasswd -a username
# sudo smbpasswd -e username
# status_message "success" "Samba user added successfully."

# Output the Samba share information
status_message "success" "Samba share '$SHARE_NAME' has been created successfully."
echo "You can access it from other machines using:"
echo "smb://<Proxmox-IP>/$SHARE_NAME"
