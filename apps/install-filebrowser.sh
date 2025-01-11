#!/bin/bash

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

# Function to change the port of FileBrowser
change_port() {
    read -p "Do you want to change the default port (8080)? [y/N]: " change_response
    if [[ "$change_response" =~ ^[Yy]$ ]]; then
        read -p "Enter the new port number: " new_port

        if [[ ! $new_port =~ ^[0-9]+$ || $new_port -lt 1 || $new_port -gt 65535 ]]; then
            status_message "error" "Invalid port number. Please enter a number between 1 and 65535."
        fi

        # Update the systemd service file
        SERVICE_FILE="/etc/systemd/system/filebrowser.service"

        if [[ -f "$SERVICE_FILE" ]]; then
            sed -i "s|ExecStart=.*|ExecStart=/usr/local/bin/filebrowser -r / --port $new_port|" "$SERVICE_FILE"

            # Reload and restart the service
            systemctl daemon-reload
            systemctl restart filebrowser

            status_message "success" "FileBrowser port has been changed to $new_port."
        else
            status_message "error" "FileBrowser service file not found. Ensure FileBrowser is installed properly."
        fi
    else
        status_message "success" "Port change skipped. FileBrowser will run on the default port (8080)."
    fi
}

# Step 1: Install FileBrowser
bash -c "$(wget -qLO - https://github.com/tteck/Proxmox/raw/main/misc/filebrowser.sh)"

# Check if the installation was successful
if [[ $? -ne 0 ]]; then
    status_message "error" "FileBrowser installation failed. Please check your network connection or the script URL."
else
    status_message "success" "FileBrowser installation completed successfully."
fi

# Step 2: Prompt for port change
change_port
