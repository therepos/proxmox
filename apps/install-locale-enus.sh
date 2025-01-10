#!/bin/bash

# Define colors and status symbols
GREEN="\e[32m\u2714\e[0m"
RED="\e[31m\u2718\e[0m"
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

# Function to check if a locale is already installed
function is_locale_installed() {
    local locale=$1
    locale -a | grep -q "^${locale}$"
}

# Main script starts here
LOCALE="en_US.UTF-8"
DEFAULT_LOCALE_FILE="/etc/default/locale"

# Check if the required locale is already installed
if is_locale_installed "$LOCALE"; then
    status_message success "Locale ${LOCALE} is already installed."
else
    # Install locales package if not present
    status_message success "Installing required locale ${LOCALE}..."
    sudo apt update && sudo apt install -y locales || status_message error "Failed to install locales package."

    # Generate the required locale
    sudo locale-gen "$LOCALE" || status_message error "Failed to generate locale ${LOCALE}."
    sudo dpkg-reconfigure locales || status_message error "Failed to reconfigure locales."

    status_message success "Locale ${LOCALE} has been successfully installed."
fi

# Make the locale persistent
if [[ -f "$DEFAULT_LOCALE_FILE" ]]; then
    sudo sed -i "/^LANG=/c\LANG=${LOCALE}" "$DEFAULT_LOCALE_FILE" || status_message error "Failed to update $DEFAULT_LOCALE_FILE."
    sudo sed -i "/^LANGUAGE=/c\LANGUAGE=${LOCALE}" "$DEFAULT_LOCALE_FILE" || status_message error "Failed to update $DEFAULT_LOCALE_FILE."
    sudo sed -i "/^LC_ALL=/c\LC_ALL=${LOCALE}" "$DEFAULT_LOCALE_FILE" || status_message error "Failed to update $DEFAULT_LOCALE_FILE."
else
    echo -e "LANG=${LOCALE}\nLANGUAGE=${LOCALE}\nLC_ALL=${LOCALE}" | sudo tee "$DEFAULT_LOCALE_FILE" > /dev/null || status_message error "Failed to create $DEFAULT_LOCALE_FILE."
fi

# Apply changes
source "$DEFAULT_LOCALE_FILE" || status_message error "Failed to apply locale settings."
status_message success "Locale settings have been successfully updated."

# Verify
locale | grep "$LOCALE" && status_message success "Locale ${LOCALE} is active." || status_message error "Locale ${LOCALE} is not active."
