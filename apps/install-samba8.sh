#!/bin/bash
# Enhanced Samba installation and configuration script for Proxmox with dependency checks

# Enable debugging for detailed logs
set -x

# Define colors and status symbols
GREEN="\e[32m\u2714\e[0m"
RED="\e[31m\u2718\e[0m"
RESET="\e[0m"
LOG_FILE="/var/log/install-samba.log"

# Function to output status messages with color symbols and detailed logging
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
        echo "[SUCCESS] ${message}" >> "$LOG_FILE"
    else
        echo -e "${RED} ${message}"
        echo "[ERROR] ${message}" >> "$LOG_FILE"
        echo "For more details, check the log file at $LOG_FILE."
        exit 1
    fi
}

# Redirect all output to a log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Start of the installation
echo "Starting Samba installation and configuration script..." > "$LOG_FILE"

# Ensure necessary dependencies are installed
echo "Checking and installing dependencies..." >> "$LOG_FILE"

REQUIRED_DEPENDENCIES=("sudo" "samba" "samba-common-bin")
for dep in "${REQUIRED_DEPENDENCIES[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
        echo "Installing missing dependency: $dep..." >> "$LOG_FILE"
        apt update >> "$LOG_FILE" 2>&1 && apt install -y "$dep" >> "$LOG_FILE" 2>&1
        [[ $? -eq 0 ]] && status_message "success" "$dep installed successfully." || status_message "error" "Failed to install $dep."
    else
        status_message "success" "$dep is already installed."
    fi
done

# Define the directory to be shared
SHARE_DIR="/mnt/sec/media"
SHARE_NAME="mediadb"

# Create the directory if it does not exist
if [ ! -d "$SHARE_DIR" ]; then
    echo "Directory $SHARE_DIR does not exist. Creating it..." >> "$LOG_FILE"
    mkdir -p "$SHARE_DIR" >> "$LOG_FILE" 2>&1
    [[ $? -eq 0 ]] && status_message "success" "Directory $SHARE_DIR created successfully." || status_message "error" "Failed to create directory $SHARE_DIR."
fi

# Backup the original Samba config
echo "Backing up existing Samba configuration..." >> "$LOG_FILE"
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak >> "$LOG_FILE" 2>&1
[[ $? -eq 0 ]] && status_message "success" "Samba configuration backed up successfully." || status_message "error" "Failed to back up Samba configuration."

# Create a Samba group for managing access
echo "Checking and creating Samba group..." >> "$LOG_FILE"
if getent group sambausers > /dev/null 2>&1; then
    echo "Samba group 'sambausers' already exists." >> "$LOG_FILE"
    status_message "success" "Samba group 'sambausers' already exists."
else
    echo "Attempting to create Samba group 'sambausers'..." >> "$LOG_FILE"
    groupadd sambausers >> "$LOG_FILE" 2>&1
    [[ $? -eq 0 ]] && status_message "success" "Samba group 'sambausers' created successfully." || status_message "error" "Failed to create Samba group."
fi

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
" >> /etc/samba/smb.conf
[[ $? -eq 0 ]] && status_message "success" "Samba share configuration created for $SHARE_NAME." || status_message "error" "Failed to create Samba share configuration."

# Set appropriate permissions for the shared directory
echo "Setting permissions for $SHARE_DIR..." >> "$LOG_FILE"
chmod -R 775 "$SHARE_DIR" >> "$LOG_FILE" 2>&1
chown -R root:sambausers "$SHARE_DIR" >> "$LOG_FILE" 2>&1
[[ $? -eq 0 ]] && status_message "success" "Permissions set for $SHARE_DIR." || status_message "error" "Failed to set permissions for $SHARE_DIR."

# Restart Samba service to apply the configuration
echo "Restarting Samba service..." >> "$LOG_FILE"
systemctl restart smbd >> "$LOG_FILE" 2>&1
[[ $? -eq 0 ]] && status_message "success" "Samba service restarted successfully." || status_message "error" "Failed to restart Samba service."

# Prompt user to create a Samba user account
read -p "Enter the username for the Samba account: " samba_user
echo "Creating Samba user account for $samba_user..." >> "$LOG_FILE"

# Add system user and assign to Samba group
if id "$samba_user" &>/dev/null; then
    echo "User $samba_user already exists." >> "$LOG_FILE"
    status_message "success" "User $samba_user already exists."
else
    adduser "$samba_user" --ingroup sambausers
    [[ $? -eq 0 ]] && status_message "success" "User $samba_user added to the system." || status_message "error" "Failed to create system user $samba_user."
fi

# Set Samba password for the user
echo "Setting Samba password for user $samba_user..." >> "$LOG_FILE"
read -s -p "Enter a password for the Samba user '$samba_user': " samba_password
echo
read -s -p "Confirm the password for the Samba user '$samba_user': " samba_password_confirm
echo

if [[ "$samba_password" != "$samba_password_confirm" ]]; then
    status_message "error" "Passwords do not match. Please re-run the script and try again."
fi

{
    echo "$samba_password"
    echo "$samba_password"
} | smbpasswd -s -a "$samba_user" >> "$LOG_FILE" 2>&1

if [[ $? -eq 0 ]]; then
    smbpasswd -e "$samba_user" >> "$LOG_FILE" 2>&1
    status_message "success" "Samba user $samba_user has been created and enabled."
else
    status_message "error" "Failed to set Samba password for $samba_user."
fi

# Output the Samba share information
status_message "success" "Samba share '$SHARE_NAME' has been created successfully."
echo "You can access it from other machines using:"
echo "\\\\<Proxmox-IP>\\$SHARE_NAME"

# Final reminder
echo "Ensure your Cloudflared tunnel is set up correctly to expose the Samba service."
