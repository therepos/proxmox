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
    if [[ $? -eq 0 ]]; then
        status_message "success" "Samba group 'sambausers' created successfully."
    else
        echo "Error: Failed to create Samba group." >> "$LOG_FILE"
        echo "Command output:" >> "$LOG_FILE"
        groupadd sambausers 2>> "$LOG_FILE"
        status_message "error" "Failed to create Samba group. See log for details."
    fi
fi

# Continue script logic...
# (The rest remains unchanged)
