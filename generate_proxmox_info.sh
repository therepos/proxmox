#!/bin/bash

# wget -qO- https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash
# curl -s https://raw.githubusercontent.com/therepos/proxmox/main/generate_proxmox_info.sh | bash

# Define the output file
OUTPUT_FILE="proxmox_info_$(date +%Y%m%d).log"

# Define colors for status messages
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

echo "Proxmox Information Collection Script"
echo "-------------------------------------"

# Function to run a command and provide status feedback
run_task() {
    local description="$1"
    local command="$2"

    # Execute the command and display the result with a tick or cross
    if eval "$command"; then
        echo -e "${GREEN} $description"
    else
        echo -e "${RED} $description"
    fi
}

# Start collecting data
run_task "Collecting Proxmox version information" "echo '### Proxmox Version Info ###' > $OUTPUT_FILE && pveversion -v >> $OUTPUT_FILE 2>&1"
run_task "Collecting ZFS pool status" "echo -e '\n### ZFS Pool Status ###' >> $OUTPUT_FILE && zpool status >> $OUTPUT_FILE 2>&1"
run_task "Collecting ZFS filesystem information" "echo -e '\n### ZFS Filesystems ###' >> $OUTPUT_FILE && zfs list >> $OUTPUT_FILE 2>&1"
run_task "Collecting storage configuration" "echo -e '\n### Storage Configuration ###' >> $OUTPUT_FILE && cat /etc/pve/storage.cfg >> $OUTPUT_FILE 2>&1"
run_task "Collecting disk layout" "echo -e '\n### Disk Layout ###' >> $OUTPUT_FILE && lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT >> $OUTPUT_FILE 2>&1"
run_task "Collecting mounted filesystems" "echo -e '\n### Mounted Filesystems ###' >> $OUTPUT_FILE && df -hT >> $OUTPUT_FILE 2>&1"
run_task "Collecting network configuration" "echo -e '\n### Network Configuration ###' >> $OUTPUT_FILE && cat /etc/network/interfaces >> $OUTPUT_FILE 2>&1"
run_task "Collecting CPU information" "echo -e '\n### CPU Information ###' >> $OUTPUT_FILE && lscpu >> $OUTPUT_FILE 2>&1"
run_task "Collecting memory status" "echo -e '\n### Memory Status ###' >> $OUTPUT_FILE && free -h >> $OUTPUT_FILE 2>&1"
run_task "Collecting VM list" "echo -e '\n### VM List ###' >> $OUTPUT_FILE && qm list >> $OUTPUT_FILE 2>&1"
run_task "Collecting LXC container list" "echo -e '\n### LXC Container List ###' >> $OUTPUT_FILE && pct list >> $OUTPUT_FILE 2>&1"
run_task "Collecting complete hardware information" "echo -e '\n### Complete Hardware Information ###' >> $OUTPUT_FILE && lshw -short >> $OUTPUT_FILE 2>&1"

echo -e "\nInformation collected and saved to $OUTPUT_FILE."

