#!/usr/bin/env bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash

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

# Blacklist nouveau driver
print_status "success" "Blacklisting nouveau driver"
echo "blacklist nouveau" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null
echo "options nouveau modeset=0" | sudo tee -a /etc/modprobe.d/blacklist-nouveau.conf > /dev/null

# Verify and update initramfs
print_status "success" "Updating initramfs"
if sudo update-initramfs -u > /dev/null 2>&1; then
    print_status "success" "initramfs updated successfully"
else
    print_status "failure" "Failed to update initramfs"
    exit 1
fi

# Install dependencies
print_status "success" "Installing dependencies"
# Install kernel headers dynamically
if sudo apt install -y build-essential pve-headers-$(uname -r); then
    print_status "success" "Kernel headers installed"
KERNEL_HEADERS="proxmox-headers-$(uname -r)"  # Adjust for Proxmox systems
print_status "success" "Checking for kernel headers: $KERNEL_HEADERS"
if dpkg-query -W -f='${Status}' $KERNEL_HEADERS 2>/dev/null | grep -q "install ok installed"; then
    print_status "success" "Kernel headers already installed: $KERNEL_HEADERS"
else
    print_status "failure" "Failed to install kernel headers. Verify your Proxmox setup."
    exit 1
    if sudo apt install -y build-essential $KERNEL_HEADERS > /dev/null 2>&1; then
        print_status "success" "Kernel headers and build-essential installed"
    else
        print_status "failure" "Failed to install kernel headers. Verify your Proxmox setup."
        exit 1
    fi
fi

# Install additional dependencies
if sudo apt install -y pkg-config libglvnd-dev libx11-dev libxext-dev xorg-dev xserver-xorg-core xserver-xorg-dev lib32z1 > /dev/null 2>&1; then
DEPENDENCIES="pkg-config libglvnd-dev libx11-dev libxext-dev xorg-dev xserver-xorg-core xserver-xorg-dev lib32z1"
print_status "success" "Installing additional dependencies: $DEPENDENCIES"
if sudo apt install -y $DEPENDENCIES > /dev/null 2>&1; then
    print_status "success" "Additional dependencies installed successfully"
else
    print_status "failure" "Failed to install additional dependencies"
    exit 1
fi

# Ensure the PKG_CONFIG_PATH configuration is not duplicated in ~/.bashrc
print_status "success" "Updating PKG_CONFIG_PATH configuration"
if ! grep -q '^export PKG_CONFIG_PATH=\$PKG_CONFIG_PATH:/usr/lib/x86_64-linux-gnu/pkgconfig/' ~/.bashrc; then
    echo 'export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/lib/x86_64-linux-gnu/pkgconfig/' >> ~/.bashrc
    print_status "success" "Added PKG_CONFIG_PATH configuration to ~/.bashrc"
else
    print_status "success" "PKG_CONFIG_PATH configuration already exists in ~/.bashrc"
fi

# Download and install NVIDIA driver
print_status "success" "Downloading and installing NVIDIA driver"
NVIDIA_VERSION=${1:-"550.135"}
NVIDIA_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"

# Download the NVIDIA installer
if wget -qO /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run "$NVIDIA_URL"; then
    print_status "success" "NVIDIA driver downloaded successfully"
else
    print_status "failure" "Failed to download NVIDIA driver from $NVIDIA_URL"
    exit 1
fi

# Run the NVIDIA installer
if bash /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run --accept-license --install-compat32-libs --glvnd-egl-config-path=/etc/glvnd/egl_vendor.d --dkms --run-nvidia-xconfig --silent; then
    print_status "success" "NVIDIA driver installed successfully"
else
    print_status "failure" "NVIDIA driver installation failed"
    exit 1
fi

# Clean up the downloaded file
if rm -f /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run; then
    print_status "success" "Cleaned up temporary files"
else
    print_status "failure" "Failed to clean up temporary files"
fi

# Verify NVIDIA driver installation
if nvidia-smi > /dev/null 2>&1; then
    print_status "success" "NVIDIA driver installed and verified"
else
    print_status "failure" "Driver verification failed. Check logs or hardware."
    exit 1
fi

# Update and install CUDA keyring
print_status "success" "Updating and installing CUDA keyring"

# Update package lists
if sudo apt update > /dev/null 2>&1; then
    print_status "success" "Package lists updated successfully"
else
    print_status "failure" "Failed to update package lists"
    exit 1
fi

# Install CUDA keyring
if sudo apt install -y cuda-keyring > /dev/null 2>&1; then
    print_status "success" "CUDA keyring installed successfully"
else
    print_status "failure" "Failed to install CUDA keyring"
    exit 1
fi

: <<'EOF'
#The -y flag skips confirmation for autoremove.
sudo ./NVIDIA-Linux-x86_64-550.135.run --uninstall
apt-get remove --purge '^nvidia-.*'
apt-get autoremove -y 
#
sudo apt install nvidia-driver
#
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/libnvidia-container1_1.17.3-1_amd64.deb
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/nvidia-container-toolkit_1.17.3-1_amd64.deb
sudo dpkg -i libnvidia-container1_1.17.3-1_amd64.deb
sudo dpkg -i nvidia-container-toolkit_1.17.3-1_amd64.deb
# Verify NVIDIA driver version:
nvidia-smi
# Verify the DKMS module:
dkms status
# Ensure the X configuration file is updated:
cat /etc/X11/xorg.conf
# Find
sudo find / -name nvidia-uninstall 2>/dev/null
EOF
