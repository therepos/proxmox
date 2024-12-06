#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

# Define the variable here
PORT="8081"  

source /dev/stdin <<< "$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y curl
$STD apt-get install -y sudo
$STD apt-get install -y mc
msg_ok "Installed Dependencies"

msg_info "Installing VS Code Server"
curl -fsSL https://code-server.dev/install.sh | sh > /dev/null 2>&1
# Ensure binary is moved to /opt/code-server for consistent placement
mkdir -p /opt/code-server
cp $(which code-server) /opt/code-server/code-server
msg_ok "Installed VS Code Server"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/code-server.service
[Unit]
Description=VS Code Server
After=network.target

[Service]
Type=simple
ExecStart=/opt/code-server/code-server --host 0.0.0.0 --port ${PORT} --auth none --disable-telemetry
WorkingDirectory=/opt/code-server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now code-server.service
msg_ok "Created Service"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
