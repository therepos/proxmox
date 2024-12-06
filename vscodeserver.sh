#!/usr/bin/env bash
source <(curl -s https://raw.githubusercontent.com/therepos/proxmox/main/lib/build.func)
# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/therepos/proxmox/raw/main/LICENSE

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
if [[ ! -d /opt/code-server ]]; then msg_error "No ${APP} Installation Found!"; exit; fi

# Storage check
if (( $(df /boot | awk 'NR==2{gsub("%","",$5); print $5}') > 80 )); then
  read -r -p "Warning: Storage is dangerously low, continue anyway? <y/N> " prompt
  [[ ${prompt,,} =~ ^(y|yes)$ ]] || exit
fi

# wget -qL https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
msg_info "Stopping code-server service"
systemctl stop code-server
msg_ok "Stopped code-server service"

msg_info "Updating code-server"
curl -fsSL https://code-server.dev/install.sh | sh || {
    msg_error "Failed to update code-server";
    exit
}
msg_ok "Updated code-server"

msg_info "Starting code-server service"
systemctl start code-server || msg_error "Failed to start code-server"; exit
msg_ok "Started code-server service"

msg_info "Cleaning Up"
rm -rf /tmp/code-server-installation-files  # Adjust if temp files are used
msg_ok "Cleaned up installation files"
msg_ok "VS Code Server Updated Successfully"
exit

}

# Calls build.func
start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${APP} Setup should be reachable by going to the following URL.
         ${BL}http://${IP}:8081${CL} \n"
