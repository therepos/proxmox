#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-webmin.sh?$(date +%s))"
# purpose: installs webmin

# Setup Webmin repo and install
bash <(curl -fsSL https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh)
apt-get install webmin --install-recommends -y

# Add current user to docker group
usermod -aG docker $(whoami)

echo "Done! Webmin is at https://$(hostname -I | awk '{print $1}'):10000"
echo "User '$(whoami)' added to docker group. Log out and back in for it to take effect."