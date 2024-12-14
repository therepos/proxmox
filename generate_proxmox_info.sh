#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash

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

    # Append header to log file
    echo -e "\n### $description ###" >> $OUTPUT_FILE

    # Run the command and provide feedback
    if eval "$command" >> $OUTPUT_FILE 2>&1; then
        echo -e "${GREEN}${RESET} Collecting $description"
    else
        echo -e "${RED}${RESET} Collecting $description"
    fi
}

# Start collecting information
run_task "Proxmox version information" "pveversion -v"
run_task "ZFS pool status" "zpool status"
run_task "ZFS filesystems" "zfs list"
run_task "CPU information" "lscpu"
run_task "Memory information" "free -h"
run_task "PCI devices" "lspci -nnk"
run_task "Block devices" "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL"
run_task "Mounted filesystems" "df -hT"
run_task "Network interfaces" "ip -br a"
run_task "Kernel version" "uname -a"
run_task "Running services" "systemctl list-units --type=service --state=running"
run_task "Listening ports" "ss -tuln"
run_task "Uptime" "uptime"
run_task "Last reboot" "who -b"
run_task "DMIDECODE information" "dmidecode"
run_task "GPU details" "lspci -vnn | grep -A 12 VGA"
run_task "Storage details" "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,TRAN"

# Epilogue
echo -e "${GREEN}✔${RESET} Data collection complete. Output saved to ${OUTPUT_FILE}."

