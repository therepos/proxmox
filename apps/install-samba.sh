#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-samba.sh)"
# purpose: this script installs samba

# Define colors and status symbols
GREEN="\e[32m\u2714\e[0m"
RED="\e[31m\u2718\e[0m"
RESET="\e[0m"
LOG_FILE="/var/log/install-samba.log"

# Function to output status messages with color symbols
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        echo "For more details, check the log file at $LOG_FILE."
        exit 1
    fi
}

# Redirect all output to a log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Start of the installation
echo "Starting Samba installation and configuration script..." > "$LOG_FILE"

# Define the directory to be shared
SHARE_DIR="/mnt/sec/media"
SHARE_NAME="mediadb"

# Ensure necessary dependencies are installed
echo "Checking and installing dependencies..." >> "$LOG_FILE"
DEPENDENCIES=("samba" "samba-common-bin")
for pkg in "${DEPENDENCIES[@]}"; do
    if ! dpkg -l | grep -qw "$pkg"; then
        echo "Installing missing package: $pkg..." >> "$LOG_FILE"
        sudo apt update >> "$LOG_FILE" 2>&1 && sudo apt install -y "$pkg" >> "$LOG_FILE" 2>&1
        [[ $? -eq 0 ]] && status_message "success" "$pkg installed successfully." || status_message "error" "Failed to install $pkg."
    else
        status_message "success" "$pkg is already installed."
    fi
done

# Check if Samba is installed
if ! command -v smbd &> /dev/null; then
    status_message "error" "Samba installation failed. Please check the logs."
fi

# Create the directory if it does not exist
if [ ! -d "$SHARE_DIR" ]; then
    echo "Directory $SHARE_DIR does not exist. Creating it..." >> "$LOG_FILE"
    sudo mkdir -p "$SHARE_DIR" >> "$LOG_FILE" 2>&1
    [[ $? -eq 0 ]] && status_message "success" "Directory $SHARE_DIR created successfully." || status_message "error" "Failed to create directory $SHARE_DIR."
fi

# Backup the original Samba config
echo "Backing up existing Samba configuration..." >> "$LOG_FILE"
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak >> "$LOG_FILE" 2>&1
[[ $? -eq 0 ]] && status_message "success" "Samba configuration backed up successfully." || status_message "error" "Failed to back up Samba configuration."

# Create a Samba group for managing access
echo "Creating Samba group..." >> "$LOG_FILE"
sudo groupadd sambausers 2>/dev/null
[[ $? -eq 0 ]] && status_message "success" "Samba group 'sambausers' created or already exists." || status_message "error" "Failed to create Samba group."

# Create the Samba share configuration
echo "Creating Samba share configuration..." >> "$LOG_FILE"
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
[[ $? -eq 0 ]] && status_message "success" "Samba share configuration created for $SHARE_NAME." || status_message "error" "Failed to create Samba share configuration."

# Set appropriate permissions for the shared directory
echo "Setting permissions for $SHARE_DIR..." >> "$LOG_FILE"
sudo chmod -R 775 "$SHARE_DIR" >> "$LOG_FILE" 2>&1
sudo chown -R root:sambausers "$SHARE_DIR" >> "$LOG_FILE" 2>&1
[[ $? -eq 0 ]] && status_message "success" "Permissions set for $SHARE_DIR." || status_message "error" "Failed to set permissions for $SHARE_DIR."

# Restart Samba service to apply the configuration
echo "Restarting Samba service..." >> "$LOG_FILE"
sudo systemctl restart smbd >> "$LOG_FILE" 2>&1
[[ $? -eq 0 ]] && status_message "success" "Samba service restarted successfully." || status_message "error" "Failed to restart Samba service."

# Prompt user to create a Samba user account
read -p "Enter the username for the Samba account: " samba_user
echo "Creating Samba user account for $samba_user..." >> "$LOG_FILE"

# Add system user and assign to Samba group
if id "$samba_user" &>/dev/null; then
    echo "User $samba_user already exists." >> "$LOG_FILE"
else
    sudo adduser "$samba_user" --no-create-home --disabled-password >> "$LOG_FILE" 2>&1
    [[ $? -eq 0 ]] && status_message "success" "User $samba_user added to the system." || status_message "error" "Failed to create system user $samba_user."
fi

sudo usermod -a -G sambausers "$samba_user" >> "$LOG_FILE" 2>&1

# Set Samba password for the user
echo "Setting Samba password for user $samba_user..." >> "$LOG_FILE"
sudo smbpasswd -a "$samba_user" >> "$LOG_FILE" 2>&1
sudo smbpasswd -e "$samba_user" >> "$LOG_FILE" 2>&1
[[ $? -eq 0 ]] && status_message "success" "Samba user $samba_user has been created and enabled." || status_message "error" "Failed to set Samba password for $samba_user."

# Output the Samba share information
status_message "success" "Samba share '$SHARE_NAME' has been created successfully."
echo "You can access it from other machines using:"
echo "\\\\<Proxmox-IP>\\$SHARE_NAME"

# Final reminder
echo "Ensure your Cloudflared tunnel is set up correctly to expose the Samba service."
