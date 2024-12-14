#!/bin/bash

# wget -qO- https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash
# curl -s https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash

# Define the output file
OUTPUT_FILE="proxmox_info_$(date +%Y%m%d).log"

# Function to run a command and provide status feedback
run_task() {
    local description="$1"
    local command="$2"
    echo -e "\n### $description ###" >> $OUTPUT_FILE
    if eval "$command" >> $OUTPUT_FILE 2>&1; then
        echo -e "✔ $description"
    else
        echo -e "✘ $description"
    fi
}

# Start collecting data
run_task "Proxmox Version Info" "pveversion -v"
run_task "ZFS Pool Status" "zpool status"
run_task "ZFS Filesystems" "zfs list"
run_task "CPU Information" "lscpu"
run_task "Memory Information" "free -h"
run_task "PCI Devices" "lspci -nnk"
run_task "Block Devices" "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL"
run_task "Mounted Filesystems" "df -hT"
run_task "Network Interfaces" "ip -br a"
run_task "Kernel Version" "uname -a"
run_task "Running Services" "systemctl list-units --type=service --state=running"
run_task "Listening Ports" "ss -tuln"
run_task "Uptime" "uptime"
run_task "Last Reboot" "who -b"
run_task "DMIDECODE Information" "dmidecode"
run_task "GPU Details" "lspci -vnn | grep -A 12 VGA"
run_task "Storage Details" "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,TRAN"

echo -e "\nData collection complete. Output saved to $OUTPUT_FILE."


