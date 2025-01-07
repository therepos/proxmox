#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/installers/install-openwebui.sh)"

source <(curl -s https://raw.githubusercontent.com/tteck/Proxmox/main/misc/build.func)

# Copyright (c) 2021-2024 tteck
# Author: tteck
# Co-Author: havardthom
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

# Allow user to define the port, default to 8080 if not provided
PORT=${1:-8080}  # Use the first argument or default to 8080

function header_info {
clear
cat <<"EOF"     
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_/

EOF
}
header_info
echo -e "Loading..."
APP="Open WebUI"
var_disk="16"
var_cpu="4"
var_ram="4096"
var_os="debian"
var_version="12"
variables
color
catch_errors

function default_settings() {
  CT_TYPE="1"
  PW=""
  CT_ID=$NEXTID
  HN=$NSAPP
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  BRG="vmbr0"
  NET="dhcp"
  GATE=""
  APT_CACHER=""
  APT_CACHER_IP=""
  DISABLEIP6="no"
  MTU=""
  SD=""
  NS=""
  MAC=""
  VLAN=""
  SSH="no"
  VERB="no"
  echo_default
}

function update_script() {
header_info
if [[ ! -d /opt/open-webui ]]; then msg_error "No ${APP} Installation Found!"; exit; fi
msg_info "Updating ${APP} (Patience)"
cd /opt/open-webui
output=$(git pull --no-rebase)
if echo "$output" | grep -q "Already up to date."
then
  msg_ok "$APP is already up to date."
  exit
fi
systemctl stop open-webui.service
npm install &>/dev/null
export NODE_OPTIONS="--max-old-space-size=3584"
npm run build &>/dev/null
cd ./backend
pip install -r requirements.txt -U &>/dev/null
systemctl start open-webui.service
msg_ok "Updated Successfully"
exit
}

# Modify the default port in the Open WebUI backend configuration
  pct exec $CT_ID -- bash -c "
    if [[ -f /opt/open-webui/backend/open_webui/__init__.py ]]; then
      echo 'Modifying Open WebUI default port to $PORT in __init__.py...'
      sed -i \"s/port=8080/port=$PORT/\" /opt/open-webui/backend/open_webui/__init__.py
      echo 'Port modified successfully in __init__.py.'
    else
      echo 'Warning: __init__.py not found. Unable to modify default port.'
    fi
  "

  # Optional: Also modify the start.sh script as a fallback
  pct exec $CT_ID -- bash -c "
    if [[ -f /opt/open-webui/backend/start.sh ]]; then
      echo 'Modifying Open WebUI default port to $PORT in start.sh...'
      sed -i 's/--port 8080/--port $PORT/' /opt/open-webui/backend/start.sh
      echo 'Port modified successfully in start.sh.'
    else
      echo 'Warning: start.sh not found. Unable to modify default port.'
    fi
  "

  # Restart the Open WebUI service to apply changes
  pct exec $CT_ID -- bash -c "
    if systemctl is-active --quiet open-webui.service; then
      echo 'Restarting Open WebUI service...'
      systemctl restart open-webui.service
      echo 'Service restarted successfully.'
    else
      echo 'Warning: Open WebUI service not found. Restart failed.'
    fi
  "

# Display the chosen port for clarity
echo "Open WebUI will be configured to use port $PORT."

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${APP} should be reachable by going to the following URL.
         ${BL}http://${IP}:$PORT${CL} \n"
