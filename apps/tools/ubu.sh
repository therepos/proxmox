#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/ubu.sh?$(date +%s))"
# purpose: add samba user and access

sudo apt update
sudo apt install -y wget curl gnupg2 apt-transport-https software-properties-common
wget -qO- http://www.webmin.com/jcameron-key.asc | sudo gpg --dearmor -o /usr/share/keyrings/webmin.gpg
echo "deb [signed-by=/usr/share/keyrings/webmin.gpg] http://download.webmin.com/download/repository sarge contrib" | sudo tee /etc/apt/sources.list.d/webmin.list
sudo apt update
sudo apt install -y webmin