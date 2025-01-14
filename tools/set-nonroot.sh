#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-nonroot.sh)"
# purpose: this scripts switches from root to non-root user

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
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

# Define the non-root username
USERNAME="admin"

# Step 1: Update package list and install sudo
echo "Installing sudo..."
apt-get update -y && status_message "success" "Package list updated." || status_message "failure" "Failed to update package list."
apt-get install -y sudo && status_message "success" "Sudo installed." || status_message "failure" "Failed to install sudo."

# Step 2: Create a non-root user if it doesn't already exist
if ! id -u $USERNAME &>/dev/null; then
  echo "Creating non-root user: $USERNAME..."
  adduser --disabled-password --gecos '' $USERNAME && status_message "success" "User $USERNAME created." || status_message "failure" "Failed to create user $USERNAME."
  echo "Adding $USERNAME to the sudo group..."
  usermod -aG sudo $USERNAME && status_message "success" "User $USERNAME added to sudo group." || status_message "failure" "Failed to add $USERNAME to sudo group."
else
  echo "User $USERNAME already exists."
  status_message "success" "User $USERNAME already exists."
fi

# Step 3: Switch to the non-root user
echo "Switching to non-root user: $USERNAME..."
su - $USERNAME && status_message "success" "Switched to user $USERNAME." || status_message "failure" "Failed to switch to user $USERNAME."
