#!/bin/bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/uninstallers/uninstall-nvidiadriver.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/uninstallers/uninstall-nvidiadriver.sh | bash

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

# Uninstall NVIDIA Drivers Script
# Run this script as root or with sudo

echo "Starting NVIDIA driver uninstallation process..."

# 1. Check if NVIDIA driver is installed
print_status "success" "Check if NVIDIA driver is installed"
if ! command -v nvidia-smi &> /dev/null; then
    echo "NVIDIA drivers are not installed or nvidia-smi is not available."
    echo "Exiting..."
    exit 1
fi

# 2. Stop display manager (to safely remove drivers)
echo "Stopping display manager..."
if systemctl list-units --type=service | grep -q "gdm.service"; then
    systemctl stop gdm
elif systemctl list-units --type=service | grep -q "lightdm.service"; then
    systemctl stop lightdm
elif systemctl list-units --type=service | grep -q "sddm.service"; then
    systemctl stop sddm
fi

# 3. Run NVIDIA uninstaller if installed via .run file
if [ -f /usr/bin/nvidia-uninstall ]; then
    echo "Running NVIDIA uninstaller..."
    /usr/bin/nvidia-uninstall --silent || echo "Failed to run NVIDIA uninstaller."
elif [ -f /usr/local/bin/nvidia-uninstall ]; then
    echo "Running NVIDIA uninstaller from /usr/local/bin..."
    /usr/local/bin/nvidia-uninstall --silent || echo "Failed to run NVIDIA uninstaller."
else
    echo "No NVIDIA uninstaller found. Skipping this step."
fi

# 4. Remove NVIDIA packages
print_status "success" "Removing NVIDIA packages"
if command -v apt &> /dev/null; then
    if sudo apt purge -y 'nvidia-*' 'libnvidia-*' > /dev/null 2>&1; then
        print_status "success" "NVIDIA packages removed successfully"
    else
        print_status "failure" "Failed to remove NVIDIA packages. Check your package manager."
    fi
    if sudo apt autoremove -y > /dev/null 2>&1; then
        print_status "success" "Unused dependencies removed successfully"
    else
        print_status "failure" "Failed to remove unused dependencies"
    fi
elif command -v yum &> /dev/null; then
    if sudo yum remove -y 'nvidia-*' > /dev/null 2>&1; then
        print_status "success" "NVIDIA packages removed successfully"
    else
        print_status "failure" "Failed to remove NVIDIA packages with yum"
    fi
elif command -v dnf &> /dev/null; then
    if sudo dnf remove -y 'nvidia-*' > /dev/null 2>&1; then
        print_status "success" "NVIDIA packages removed successfully"
    else
        print_status "failure" "Failed to remove NVIDIA packages with dnf"
    fi
else
    print_status "failure" "No supported package manager found, skipping package removal"
fi

# 5. Remove NVIDIA configuration files
echo "Removing NVIDIA configuration files..."
rm -rf /etc/X11/xorg.conf /etc/X11/xorg.conf.d/nvidia.conf
rm -rf /etc/modprobe.d/nvidia.conf /usr/share/X11/xorg.conf.d/nvidia.conf

# 6. Remove NVIDIA kernel modules
echo "Removing NVIDIA kernel modules..."
rm -rf /lib/modules/$(uname -r)/kernel/drivers/video/nvidia*

# 7. Remove NVIDIA temporary files and folders
echo "Cleaning up NVIDIA-related temporary files and folders..."
rm -rf /tmp/.X*-lock /tmp/.nvidia*

# 8. Remove leftover NVIDIA directories
echo "Removing leftover NVIDIA directories..."
rm -rf /usr/local/cuda* /usr/lib/nvidia* /usr/lib32/nvidia* /usr/lib64/nvidia* /usr/share/nvidia* /usr/local/nvidia*

# 9. Notify the user
echo "Uninstallation of NVIDIA drivers is complete."
echo "Please reboot your system to ensure all changes take effect."

exit 0
