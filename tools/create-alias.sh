#!/bin/bash

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
BLUE="\e[34mℹ\e[0m"

function status_message() { 
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    elif [[ "$status" == "info" ]]; then
        echo -e "${BLUE} ${message}"
    else
        echo -e "${RED} ${message}"
    fi
}

ALIAS_FILE="$HOME/.bashrc"

# Backup first
cp "$ALIAS_FILE" "$ALIAS_FILE.bak"
status_message "info" "Backup created at $ALIAS_FILE.bak"

# Add aliases
{
  echo ""
  echo "# Custom Aliases"
  echo "alias ollama='cd /mnt/sec/apps/ollama'"
  echo "alias purgedockerct='bash -c \"\$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/purge-dockerct.sh)\"'"
  # Add more aliases below as needed
} >> "$ALIAS_FILE"

status_message "success" "Aliases added to $ALIAS_FILE"

# Reload shell config
source "$ALIAS_FILE"
status_message "success" "Shell reloaded. Aliases are ready to use."
