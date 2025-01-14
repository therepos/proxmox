#!/bin/bash

# Define the non-root username
USERNAME="admin"

# Step 1: Create a non-root user if it doesn't already exist
if ! id -u $USERNAME &>/dev/null; then
  echo "Creating non-root user: $USERNAME..."
  adduser --disabled-password --gecos '' $USERNAME
else
  echo "User $USERNAME already exists."
fi

# Step 2: Switch to the non-root user
echo "Switching to non-root user: $USERNAME..."
su - $USERNAME
