#!/bin/bash

# wget -qO- https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash
# curl -s https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash

# Define the output file
OUTPUT_FILE="proxmox_info_$(date +%Y%m%d).log"

# Prologue
echo -e "\033[1mProxmox Information Collection Script\033[0m"
echo -e "-------------------------------------"

# Function to run a task with colored dynamic feedback
run_task() {
    local description="$1"
    local command="$2"

    # Show collecting status
    echo -n "Collecting $description... "
    echo -e "\n### $description ###" >> $OUTPUT_FILE

    # Run the command and provide feedback
    if eval "$command" >> $OUTPUT_FILE 2>&1; then
        echo -e "\033[32m✔\033[0m"  # Green tick for success
    else
        echo -e "\033[31m✘\033[0m"  # Red cross for failure
    fi
}

# Start collecting information
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

# Epilogue
echo -e "\033[32mData collection complete. Output saved to $OUTPUT_FILE.\033[0m"
