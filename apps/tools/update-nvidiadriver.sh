#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/set-nonroot.sh?$(date +%s))"
# purpose: updates nvidia driver

# Log file for tracking the process
LOGFILE="/var/log/nvidia_driver_upgrade.log"

# Function to log messages with timestamp
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
}

# Step 1: Update the package list
log_message "Updating package list..."
sudo apt update -y
if [ $? -ne 0 ]; then
    log_message "Failed to update package list. Exiting."
    exit 1
fi

# Step 2: Upgrade the NVIDIA driver
log_message "Upgrading NVIDIA driver..."
sudo apt upgrade -y nvidia-driver
if [ $? -ne 0 ]; then
    log_message "Failed to upgrade NVIDIA driver. Exiting."
    exit 1
fi

# Step 3: Check if a reboot is required
log_message "Checking if a reboot is required..."
if [ -f /var/run/reboot-required ]; then
    log_message "Reboot required after NVIDIA driver upgrade."
else
    log_message "No reboot required."
fi

# Step 4: Print the result
log_message "Upgrade completed successfully."
echo "NVIDIA driver upgrade completed. Please check the log file at $LOGFILE for details."

# End of script
