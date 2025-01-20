#!/bin/bash
# purpose: this script installs calibre-web 

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

# Function to uninstall Calibre-Web
uninstall_calibre_web() {
    echo "Uninstalling Calibre-Web..."
    systemctl stop calibre-web
    systemctl disable calibre-web
    rm -f /etc/systemd/system/calibre-web.service
    systemctl daemon-reload
    status_message "success" "Calibre-Web has been uninstalled."
}

# Function to change the port of Calibre-Web
change_port() {
    local default_port="8083"
    local new_port="3015"

    SERVICE_FILE="/etc/systemd/system/calibre-web.service"

    if [[ -f "$SERVICE_FILE" ]]; then
        sed -i "s|ExecStart=.*|ExecStart=/usr/local/bin/calibre-web --port $new_port|" "$SERVICE_FILE"

        # Reload and restart the service
        systemctl daemon-reload
        systemctl restart calibre-web

        status_message "success" "Calibre-Web port has been changed to $new_port."
    else
        status_message "error" "Calibre-Web service file not found. Ensure Calibre-Web is installed properly."
    fi
}

# Check if Calibre-Web is already installed
if systemctl is-active --quiet calibre-web; then
    echo "Calibre-Web is already installed and running."
    read -p "Do you want to uninstall it? [y/N]: " uninstall_response
    if [[ "$uninstall_response" =~ ^[Yy]$ ]]; then
        uninstall_calibre_web
        exit 0
    else
        status_message "success" "Existing Calibre-Web installation retained."
        exit 0
    fi
fi

# Step 1: Install Calibre-Web
bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/ct/calibre-web.sh)"

# Check if the installation was successful
if [[ $? -ne 0 ]]; then
    status_message "error" "Calibre-Web installation failed. Please check your network connection or the script URL."
else
    status_message "success" "Calibre-Web installation completed successfully."
fi

# Step 2: Change the default port to 3015
change_port
