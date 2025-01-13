#!/bin/bash

# Proxmox Cleanup Script
# This script removes unnecessary files and frees up disk space on a Proxmox server

# Function to clean APT cache
clean_apt_cache() {
    echo "Cleaning APT cache..."
    apt-get clean
    apt-get autoremove --purge -y
}

# Function to clean old backups
clean_old_backups() {
    echo "Cleaning old backups..."
    find /var/lib/vz/dump/ -type f -name "*.tar.lzo" -mtime +30 -exec rm -f {} \;
}

# Function to clear old system logs
clear_logs() {
    echo "Clearing old system logs..."
    journalctl --vacuum-time=7d
    rm -f /var/log/*gz
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
}

# Function to remove unused ISO images
clean_isos() {
    echo "Cleaning unused ISO images..."
    rm -f /var/lib/vz/template/iso/*.iso
}

# Function to remove orphaned configuration files
clean_configs() {
    echo "Cleaning orphaned configuration files..."
    find /etc/pve -type f -name "*.conf" -exec rm -f {} \;
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

    echo "Proxmox cleanup completed!"
}

# Execute the script
main
