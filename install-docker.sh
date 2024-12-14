#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash

# Update system packages
apt-get update -y

# Install necessary dependencies for Docker and ZFS
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release zfsutils-linux

# Add Docker’s official GPG key
curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -

# Set up the Docker stable repository
echo "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index again after adding Docker repository
apt-get update -y

# Install Docker CE (Community Edition)
apt-get install -y docker-ce docker-ce-cli containerd.io

# Verify Docker installation
docker --version

# Configure Docker to use ZFS as the storage driver
# Ensure the Docker daemon is configured to use ZFS as the default storage driver
echo '{
  "storage-driver": "zfs"
}' > /etc/docker/daemon.json

# Restart Docker service
systemctl restart docker

# Verify Docker is using ZFS storage driver
docker info | grep Storage

echo "Docker and ZFS setup complete!"
