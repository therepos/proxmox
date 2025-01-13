#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/uninstall-dockerct.sh)"
# purpose: this script removes unnecessary files and frees up disk space on a proxmox server

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to display status messages with color
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}${RESET}"
    else
        echo -e "${RED} ${message}${RESET}"
        exit 1
    fi
}

# Function to clean APT cache
clean_apt_cache() {
    echo "Cleaning APT cache..."
    apt-get clean && apt-get autoremove --purge -y
    if [ $? -eq 0 ]; then
        status_message "success" "APT cache cleaned successfully."
    else
        status_message "failure" "Failed to clean APT cache."
    fi
}

# Function to clean old backups
clean_old_backups() {
    echo "Cleaning old backups..."
    find /var/lib/vz/dump/ -type f -name "*.tar.lzo" -mtime +30 -exec rm -f {} \;
    if [ $? -eq 0 ]; then
        status_message "success" "Old backups cleaned successfully."
    else
        status_message "failure" "Failed to clean old backups."
    fi
}

# Function to clear old system logs
clear_logs() {
    echo "Clearing old system logs..."
    journalctl --vacuum-time=7d
    rm -f /var/log/*gz
    if [ $? -eq 0 ]; then
        status_message "success" "Old logs cleared successfully."
    else
        status_message "failure" "Failed to clear logs."
    fi
}

# Function to remove unused VM and container disk images
clean_vm_disks() {
    echo "Cleaning unused VM disk images..."
    for vm_dir in /var/lib/vz/images/*; do
        if [ -d "$vm_dir" ]; then
            vm_id=$(basename "$vm_dir")
            if ! pvevm status $vm_id >/dev/null 2>&1; then
                rm -rf "$vm_dir"
                echo "Removed unused disk images for VM $vm_id"
            fi
        fi
    done
    if [ $? -eq 0 ]; then
        status_message "success" "Unused VM disk images cleaned successfully."
    else
        status_message "failure" "Failed to clean unused VM disk images."
    fi
}

# Function to remove unused ISO images
clean_isos() {
    echo "Cleaning unused ISO images..."
    rm -f /var/lib/vz/template/iso/*.iso
    if [ $? -eq 0 ]; then
        status_message "success" "Unused ISO images cleaned successfully."
    else
        status_message "failure" "Failed to clean unused ISO images."
    fi
}

# Function to remove orphaned configuration files
clean_configs() {
    echo "Cleaning orphaned configuration files..."
    find /etc/pve -type f -name "*.conf" -exec rm -f {} \;
    if [ $? -eq 0 ]; then
        status_message "success" "Orphaned configuration files cleaned successfully."
    else
        status_message "failure" "Failed to clean orphaned configuration files."
    fi
}

# Main function that calls the cleanup steps
main() {
    echo "Starting Proxmox disk cleanup..."

    # Run each cleanup step
    clean_apt_cache
    clean_old_backups
    clear_logs
    clean_vm_disks
    clean_isos
    clean_configs

    echo -e "${GREEN} Proxmox cleanup completed!${RESET}"
}

# Execute the script
main

