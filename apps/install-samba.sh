#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-samba.sh)"
# purpose: this script installs samba service

# Define colors and status symbols
GREEN="\e[32m\u2714\e[0m"
RED="\e[31m\u2718\e[0m"
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

# Check if Samba is already installed
if command -v samba &> /dev/null; then
    echo "Samba is already installed."
    read -p "Do you wish to uninstall Samba? (yes/no): " uninstall_choice
    if [[ "$uninstall_choice" == "yes" ]]; then
        echo "Uninstalling Samba and cleaning up..."
        sudo systemctl stop smbd nmbd
        sudo apt purge -y samba samba-common samba-common-bin
        sudo apt autoremove -y
        sudo rm -rf /etc/samba /var/lib/samba /var/cache/samba
        status_message "success" "Samba has been uninstalled and cleaned up."
        exit 0
    else
        status_message "success" "Proceeding with the existing Samba installation."
    fi
else
    echo "Samba is not installed. Proceeding with installation..."
    sudo apt update && sudo apt install -y samba
    status_message "success" "Samba installed successfully."
fi

# Define the directory to be shared
SHARE_DIR="/mnt/sec/media"
SHARE_NAME="mediadb"

# Check if the directory exists
if [ ! -d "$SHARE_DIR" ]; then
    status_message "error" "Error: Directory $SHARE_DIR does not exist!"
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
   guest ok = no
   read only = no
   create mask = 0775
   directory mask = 0775
   valid users = @sambausers
" | sudo tee -a /etc/samba/smb.conf > /dev/null
status_message "success" "Samba share configuration created for $SHARE_NAME."

# Set appropriate permissions for the shared directory
echo "Setting permissions for $SHARE_DIR..."
sudo chmod -R 775 "$SHARE_DIR"
sudo chown -R nobody:sambausers "$SHARE_DIR"
status_message "success" "Permissions set for $SHARE_DIR."

# Restart Samba service to apply the configuration
echo "Restarting Samba service..."
sudo systemctl restart smbd
status_message "success" "Samba service restarted successfully."

# Prompt user to create a Samba user account
echo "You need to create a Samba user account for write access."
read -p "Enter the username for the Samba account: " samba_user

# Add system user and assign to samba group
if id "$samba_user" &>/dev/null; then
    echo "User $samba_user already exists."
else
    sudo adduser "$samba_user" --no-create-home --disabled-password
    status_message "success" "User $samba_user added to the system."
fi

sudo usermod -a -G sambausers "$samba_user"

# Set Samba password for the user
echo "Setting Samba password for user $samba_user..."
echo -e "Please enter a password for the Samba user $samba_user."
sudo smbpasswd -a "$samba_user"
sudo smbpasswd -e "$samba_user"
status_message "success" "Samba user $samba_user has been created and enabled."

# Output the Samba share information
status_message "success" "Samba share '$SHARE_NAME' has been created successfully."
echo "You can access it from other machines using:"
echo "\\\\<Proxmox-IP>\\$SHARE_NAME"
