#!/bin/bash

# Define colors for status messages (already include tick and cross)
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
        # Output success message with pre-defined tick
        echo -e "${GREEN} $description"
    else
        # Output failure message with pre-defined cross
        echo -e "${RED} $description"
    fi
}

# Start collecting information
run_task "Proxmox version information" "pveversion -v"
run_task "ZFS pool status" "zpool status"
run_task "ZFS filesystems" "zfs list"
run_task "CPU information" "lscpu"
run_task "Memory information" "free -h"
run_task "PCI devices" "lspci -nnk"
run_task "Block devices" "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL"
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

# Enhanced: Determine root device and Proxmox installation details
run_task "Determining root device and Proxmox installation details" \
"{
    echo \"Root filesystem mountpoint (from df):\"
    df -h /

    echo \"\nZFS dataset for root (from zfs list):\"
    root_dataset=\$(zfs list | awk '/\/ \$/ {print \$1}')
    echo \"\$root_dataset\"

    if [[ -z \"\$root_dataset\" ]]; then
        echo \"Error: Root dataset could not be identified.\"
        exit 1
    fi

    echo \"\nBlock device details for root (from lsblk):\"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,SERIAL | grep ' /$'

    echo \"\nDisk and partition details for the root ZFS pool (from zpool status):\"
    zpool status rpool | awk '/nvme/ {print \$1}'
}"

# Epilogue
echo -e "${GREEN} Data collection complete. Output saved to ${OUTPUT_FILE}.${RESET}"
