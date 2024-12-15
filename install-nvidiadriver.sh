#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-nvidiadriver.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/uninstall-nvidiadriver.sh | bash

# Function to print status with green or red check marks
print_status() {
    if [ "$1" == "success" ]; then
        echo -e "\033[0;32m✔\033[0m $2"  # Green check mark
    else
        echo -e "\033[0;31m✘\033[0m $2"  # Red cross mark
    fi
}

# Function to run commands silently, suppressing output
run_silent() {
    "$@" > /dev/null 2>&1
}

print_status "success" "Starting NVIDIA driver uninstallation process"

# 1. Check if NVIDIA driver is installed
if ! command -v nvidia-smi &> /dev/null; then
    print_status "failure" "NVIDIA drivers are not installed or nvidia-smi is unavailable"
    exit 1
fi
print_status "success" "NVIDIA driver detected"

# 2. Stop display manager
print_status "success" "Stopping display manager"
if systemctl list-units --type=service | grep -q "gdm.service"; then
    run_silent systemctl stop gdm
elif systemctl list-units --type=service | grep -q "lightdm.service"; then
    run_silent systemctl stop lightdm
elif systemctl list-units --type=service | grep -q "sddm.service"; then
    run_silent systemctl stop sddm
else
    print_status "success" "No active display manager detected"
fi

# 3. Run NVIDIA uninstaller
print_status "success" "Checking for NVIDIA uninstaller"
if [ -f /usr/bin/nvidia-uninstall ]; then
    run_silent /usr/bin/nvidia-uninstall --silent
    print_status "success" "NVIDIA uninstaller ran successfully"
elif [ -f /usr/local/bin/nvidia-uninstall ]; then
    run_silent /usr/local/bin/nvidia-uninstall --silent
    print_status "success" "NVIDIA uninstaller ran successfully"
else
    print_status "success" "No NVIDIA uninstaller found, skipping"
fi

# 4. Remove NVIDIA packages
print_status "success" "Removing NVIDIA packages"
if command -v apt &> /dev/null; then
    run_silent sudo apt purge -y 'nvidia-*' 'libnvidia-*'
    run_silent sudo apt autoremove -y
elif command -v yum &> /dev/null; then
    run_silent sudo yum remove -y 'nvidia-*'
elif command -v dnf &> /dev/null; then
    run_silent sudo dnf remove -y 'nvidia-*'
else
    print_status "failure" "No supported package manager found, skipping package removal"
fi

# 5. Remove NVIDIA configuration files
print_status "success" "Removing NVIDIA configuration files"
run_silent rm -rf /etc/X11/xorg.conf /etc/X11/xorg.conf.d/nvidia.conf
run_silent rm -rf /etc/modprobe.d/nvidia.conf /usr/share/X11/xorg.conf.d/nvidia.conf

# 6. Remove NVIDIA kernel modules
print_status "success" "Removing NVIDIA kernel modules"
run_silent rm -rf /lib/modules/$(uname -r)/kernel/drivers/video/nvidia*

# 7. Remove NVIDIA temporary files and folders
print_status "success" "Cleaning up NVIDIA-related temporary files and folders"
run_silent rm -rf /tmp/.X*-lock /tmp/.nvidia*

# 8. Remove leftover NVIDIA directories
print_status "success" "Removing leftover NVIDIA directories"
run_silent rm -rf /usr/local/cuda* /usr/lib/
