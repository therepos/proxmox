#!/bin/bash

# Define the non-root username
USERNAME="admin"

# Step 1: Update package list and install sudo
echo "Installing sudo..."
apt-get update -y
apt-get install -y sudo

# Step 2: Create a non-root user if it doesn't already exist
if ! id -u $USERNAME &>/dev/null; then
  echo "Creating non-root user: $USERNAME..."
  adduser --disabled-password --gecos '' $USERNAME
  echo "Adding $USERNAME to the sudo group..."
  usermod -aG sudo $USERNAME
else
  echo "User $USERNAME already exists."
fi

# Step 3: Switch to the non-root user
echo "Switching to non-root user: $USERNAME..."
su - $USERNAME
