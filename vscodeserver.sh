#!/usr/bin/env bash

# bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/vscodeserver.sh)"
# bash -c "$(curl -fsSL https://github.com/therepos/proxmox/raw/main/vscodeserver.sh)"
# Modified by: therepos
# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/therepos/proxmox/raw/main/LICENSE
# Art: https://patorjk.com/software/taag/#p=display&f=Big&t=vscodeserver 

source <(curl -s https://raw.githubusercontent.com/therepos/proxmox/main/lib/build.func)

function header_info {
clear
cat <<"EOF"
                         | |                                   
 __   _____  ___ ___   __| | ___  ___  ___ _ ____   _____ _ __ 
 \ \ / / __|/ __/ _ \ / _` |/ _ \/ __|/ _ \ '__\ \ / / _ \ '__|
  \ V /\__ \ (_| (_) | (_| |  __/\__ \  __/ |   \ V /  __/ |   
   \_/ |___/\___\___/ \__,_|\___||___/\___|_|    \_/ \___|_|                            
EOF
}
header_info
echo -e "Loading..."
APP="VSCodeServer"
SVC="code-server"
PORT="8081"
var_disk="2"
var_cpu="2"
var_ram="8192"
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
if [[ ! -d /opt/${SVC} ]]; then msg_error "No ${APP} Installation Found!"; exit; fi

# Storage check
if (( $(df /boot | awk 'NR==2{gsub("%","",$5); print $5}') > 80 )); then
  read -r -p "Warning: Storage is dangerously low, continue anyway? <y/N> " prompt
  [[ ${prompt,,} =~ ^(y|yes)$ ]] || exit
fi

msg_info "Stopping ${SVC} service"
systemctl stop "${SVC}"
msg_ok "Stopped ${SVC} service"

msg_info "Updating ${SVC}"
curl -fsSL https://code-server.dev/install.sh | sh || {
    msg_error "Failed to update ${SVC}";
    exit
}
msg_ok "Updated ${SVC}"

msg_info "Starting ${SVC} service"
systemctl start "${SVC}" || msg_error "Failed to start ${SVC}"; exit
msg_ok "Started ${SVC} service"

msg_info "Cleaning Up"
rm -rf /tmp/${SVC}-installation-files  # Adjust if temp files are used
msg_ok "Cleaned up installation files"
msg_ok "${APP} Updated Successfully"
exit
}

# Calls build.func
start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${APP} Setup should be reachable by going to the following URL.
         ${BL}http://${IP}:${PORT}${CL} \n"
