#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-nonroot.sh)"

# Define variables
USERNAME="admin"
DEFAULT_PASSWORD="password"
USER_HOME="/home/$USERNAME"

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Please run it with sudo."
    exit 1
fi

# Ensure sudo is installed
if ! command -v sudo &>/dev/null; then
    echo "sudo is not installed. Installing sudo..."
    apt update && apt install -y sudo
    echo "sudo installed successfully."
fi

# Create the non-root user if it doesn't exist
if id "$USERNAME" &>/dev/null; then
    echo "User '$USERNAME' already exists."
else
    echo "Creating user '$USERNAME'..."
    adduser --home "$USER_HOME" --gecos "" --disabled-password "$USERNAME"
    echo "$USERNAME:$DEFAULT_PASSWORD" | chpasswd
    echo "User '$USERNAME' created successfully with default password '$DEFAULT_PASSWORD'."
fi

# Add the user to the sudo group
echo "Adding '$USERNAME' to the sudo group..."
usermod -aG sudo "$USERNAME"
echo "User '$USERNAME' has been granted sudo access."

# Ensure the user has a valid shell
echo "Ensuring '$USERNAME' has a valid shell..."
chsh -s /bin/bash "$USERNAME"
echo "Shell for '$USERNAME' set to /bin/bash."

# Fix home directory permissions
echo "Ensuring correct ownership of the home directory..."
chown -R "$USERNAME:$USERNAME" "$USER_HOME"
chmod 755 "$USER_HOME"
echo "Permissions for '$USER_HOME' fixed."

# Summary of actions
echo "User '$USERNAME' has been successfully created with sudo privileges and the default password '$DEFAULT_PASSWORD'."
echo "Setup as non-root user completed."

# Run commands as the non-root user (if needed)
sudo -u "$USERNAME" bash -c "
    echo 'Running additional setup tasks as $USERNAME...'
    # Place any additional commands here
"

# Exit the script cleanly
echo "Script execution completed. Exiting."
exit 0
