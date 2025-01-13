#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/fix-locale.sh)"
# purpose: this script fixes missing en_US.UTF-8 locale

# Define colors for output
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

# Step 1: Install locale package (if not installed)
echo "Checking if 'locales' package is installed..."
sudo apt update -y && sudo apt install -y locales
status_message "success" "Locales package installed or already present."

# Step 2: Generate en_US.UTF-8 locale
echo "Generating 'en_US.UTF-8' locale..."
sudo locale-gen en_US.UTF-8
status_message "success" "Generated 'en_US.UTF-8' locale."

# Step 3: Update system-wide locale settings
echo "Updating default locale to 'en_US.UTF-8'..."
echo -e "LANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\nLANGUAGE=en_US.UTF-8" | sudo tee /etc/default/locale > /dev/null
status_message "success" "System-wide locale updated to 'en_US.UTF-8'."

# Step 4: Apply locale settings
echo "Applying locale settings..."
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LANGUAGE="en_US.UTF-8"
source /etc/default/locale
status_message "success" "Locale settings applied."

# Step 5: Verify the locale settings
echo "Verifying locale settings..."
locale | grep "en_US.UTF-8"
if [[ $? -eq 0 ]]; then
    status_message "success" "Locale settings verified as 'en_US.UTF-8'."
else
    status_message "error" "Locale verification failed."
fi

# Completion message
echo -e "${GREEN}Locale configuration completed successfully!${RESET}"
