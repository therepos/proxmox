#!/bin/bash

# wget -qO- https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash
# curl -s https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash

# Define colors for status messages
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Define the output file
OUTPUT_FILE="proxmox_info_$(date +%Y%m%d).log"

# Prologue
echo -e "${RESET}Proxmox Information Collection Script"
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
        echo -e "${GREEN}✔${RESET}"  # Green tick for success
    else
        echo -e "${RED}✘${RESET}"    # Red cross for failure
    fi
}

# Start collecting information
run_task "Proxmox version information" "pveversion -v"
run_task "ZFS pool status" "zpool status"
run_task "ZFS filesystem information" "zfs list"
run_task "storage configuration" "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,TRAN"
run_task "disk layout" "fdisk -l"
run_task "mounted filesystems" "df -hT"
run_task "network configuration" "ip -br a"
run_task "CPU information" "lscpu"
run_task "memory status" "free -h"
run_task "VM list" "qm list"
run_task "LXC container list" "pct list"
run_task "complete hardware information" "dmidecode"

# Epilogue
echo -e "\nInformation collected and saved to ${OUTPUT_FILE}."

