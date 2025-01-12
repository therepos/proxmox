#!/bin/bash

# Define variables
USERNAME="admin"
USER_HOME="/home/$USERNAME"

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Please run it with sudo."
    exit 1
fi

# Create the non-root user if it doesn't exist
if id "$USERNAME" &>/dev/null; then
    echo "User '$USERNAME' already exists."
else
    echo "Creating user '$USERNAME'..."
    adduser --home "$USER_HOME" "$USERNAME"
    echo "User '$USERNAME' created successfully."
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

# Summary
echo "User '$USERNAME' has been successfully created with sudo privileges."
echo "Switch to the user with: su $USERNAME"
