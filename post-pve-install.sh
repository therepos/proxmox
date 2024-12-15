#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

header_info() {
  clear
  cat <<"EOF"
    ____ _    ________   ____             __     ____           __        ____
   / __ \ |  / / ____/  / __ \____  _____/ /_   /  _/___  _____/ /_____ _/ / /
  / /_/ / | / / __/    / /_/ / __ \/ ___/ __/   / // __ \/ ___/ __/ __ `/ / /
 / ____/| |/ / /___   / ____/ /_/ (__  ) /_   _/ // / / (__  ) /_/ /_/ / / /
/_/     |___/_____/  /_/    \____/____/\__/  /___/_/ /_/____/\__/\__,_/_/_/

EOF
}

RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

set -euo pipefail
shopt -s inherit_errexit nullglob

msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

start_routines() {
  header_info

  # Automatically selecting "yes" for each prompt
  CHOICE="yes"  # Automatically agree to correcting Proxmox VE sources
  msg_info "Correcting Proxmox VE Sources"
  cat <<EOF >/etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib
deb http://deb.debian.org/debian bookworm-updates main contrib
deb http://security.debian.org/debian-security bookworm-security main contrib
EOF
  echo 'APT::Get::Update::SourceListWarnings::NonFreeFirmware "false";' >/etc/apt/apt.conf.d/no-bookworm-firmware.conf
  msg_ok "Corrected Proxmox VE Sources"

  CHOICE="yes"  # Automatically select "yes" to disabling 'pve-enterprise'
  msg_info "Disabling 'pve-enterprise' repository"
  cat <<EOF >/etc/apt/sources.list.d/pve-enterprise.list
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF
  msg_ok "Disabled 'pve-enterprise' repository"

  CHOICE="yes"  # Automatically select "yes" to enabling 'pve-no-subscription'
  msg_info "Enabling 'pve-no-subscription' repository"
  cat <<EOF >/etc/apt/sources.list.d/pve-install-repo.list
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
  msg_ok "Enabled 'pve-no-subscription' repository"

  CHOICE="yes"  # Automatically select "yes" to correcting 'ceph' repositories
  msg_info "Correcting 'ceph package repositories'"
  cat <<EOF >/etc/apt/sources.list.d/ceph.list
# deb https://enterprise.proxmox.com/debian/ceph-quincy bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
# deb https://enterprise.proxmox.com/debian/ceph-reef bookworm enterprise
# deb http://download.proxmox.com/debian/ceph-reef bookworm no-subscription
EOF
  msg_ok "Corrected 'ceph package repositories'"

  CHOICE="yes"  # Automatically select "yes" to adding the 'pvetest' repository
  msg_info "Adding 'pvetest' repository and set disabled"
  cat <<EOF >/etc/apt/sources.list.d/pvetest-for-beta.list
# deb http://download.proxmox.com/debian/pve bookworm pvetest
EOF
  msg_ok "Added 'pvetest' repository"

  CHOICE="yes"  # Automatically select "yes" to disabling the subscription nag
  whiptail --backtitle "Proxmox VE Helper Scripts" --msgbox --title "Support Subscriptions" "Supporting the software's development team is essential. Check their official website's Support Subscriptions for pricing. Without their dedicated work, we wouldn't have this exceptional software." 10 58
  msg_info "Disabling subscription nag"
  echo "DPkg::Post-Invoke { \"dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; if [ \$? -eq 1 ]; then { echo 'Removing subscription nag from UI...'; sed -i '/.*data\.status.*{/{s/\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi\"; };" >/etc/apt/apt.conf.d/no-nag-script
  apt --reinstall install proxmox-widget-toolkit &>/dev/null
  msg_ok "Disabled subscription nag (Delete browser cache)"

  CHOICE="yes"  # Automatically select "yes" to enabling high availability
  msg_info "Enabling high availability"
  systemctl enable -q --now pve-ha-lrm
  systemctl enable -q --now pve-ha-crm
  systemctl enable -q --now corosync
  msg_ok "Enabled high availability"

  CHOICE="yes"  # Automatically select "yes" to update Proxmox VE
  msg_info "Updating Proxmox VE (Patience)"
  apt-get update &>/dev/null
  apt-get -y dist-upgrade &>/dev/null
  msg_ok "Updated Proxmox VE"

  CHOICE="yes"  # Automatically select "yes" to rebooting Proxmox VE
  msg_info "Rebooting Proxmox VE"
  sleep 2
  msg_ok "Completed Post Install Routines"
  reboot
}

header_info
echo -e "\nThis script will Perform Post Install Routines.\n"
# Skipping user prompt to start the script
echo "Starting Post Install Script automatically..."  # Modified line here

if ! pveversion | grep -Eq "pve-manager/8.[0-2]"; then
  msg_error "This version of Proxmox Virtual Environment is not supported"
  echo -e "Requires Proxmox Virtual Environment Version 8.0 or later."
  echo -e "Exiting..."
  sleep 2
  exit
fi

start_routines

header_info
echo -e "\nThis script will Perform Post Install Routines.\n"
while true; do
  read -p "Start the Proxmox VE Post Install Script (y/n)?" yn
  case $yn in
  [Yy]*) break ;;
  [Nn]*) clear; exit ;;
  *) echo "Please answer yes or no." ;;
  esac
done

if ! pveversion | grep -Eq "pve-manager/8.[0-2]"; then
  msg_error "This version of Proxmox Virtual Environment is not supported"
  echo -e "Requires Proxmox Virtual Environment Version 8.0 or later."
  echo -e "Exiting..."
  sleep 2
  exit
fi

start_routines
