#!/usr/bin/env bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash

# Function to print status with green or red check marks
print_status() {
    if [ "$1" == "success" ]; then
        echo -e "\033[0;32m✔\033[0m $2"
    else
        echo -e "\033[0;31m✘\033[0m $2"
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

# Update initramfs
print_status "success" "Updating initramfs"
if sudo update-initramfs -u > /dev/null 2>&1; then
    print_status "success" "initramfs updated successfully"
else
    print_status "failure" "Failed to update initramfs"
    exit 1
fi

# Install kernel headers
print_status "success" "Checking and installing kernel headers"
KERNEL_HEADERS="proxmox-headers-$(uname -r)"
if dpkg-query -W -f='${Status}' $KERNEL_HEADERS 2>/dev/null | grep -q "install ok installed"; then
    print_status "success" "Kernel headers already installed: $KERNEL_HEADERS"
else
    if sudo apt install -y build-essential $KERNEL_HEADERS > /dev/null 2>&1; then
        print_status "success" "Kernel headers and build-essential installed successfully"
    else
        print_status "failure" "Failed to install kernel headers. Verify your Proxmox setup."
        exit 1
    fi
fi

# Install additional dependencies
DEPENDENCIES="pkg-config libglvnd-dev libx11-dev libxext-dev xorg-dev xserver-xorg-core xserver-xorg-dev lib32z1"
print_status "success" "Installing additional dependencies"
if sudo apt install -y $DEPENDENCIES > /dev/null 2>&1; then
    print_status "success" "Additional dependencies installed successfully"
else
    print_status "failure" "Failed to install additional dependencies"
    exit 1
fi

# Set PKG_CONFIG_PATH in ~/.bashrc
print_status "success" "Updating PKG_CONFIG_PATH in ~/.bashrc"
if ! grep -q '^export PKG_CONFIG_PATH=\$PKG_CONFIG_PATH:/usr/lib/x86_64-linux-gnu/pkgconfig/' ~/.bashrc; then
    echo 'export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/lib/x86_64-linux-gnu/pkgconfig/' >> ~/.bashrc
    print_status "success" "Added PKG_CONFIG_PATH to ~/.bashrc"
else
    print_status "success" "PKG_CONFIG_PATH already exists in ~/.bashrc"
fi

# Download and install NVIDIA driver
NVIDIA_VERSION=${1:-"550.135"}
NVIDIA_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
print_status "success" "Downloading NVIDIA driver"
if wget -qO /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run "$NVIDIA_URL"; then
    print_status "success" "NVIDIA driver downloaded successfully"
else
    print_status "failure" "Failed to download NVIDIA driver"
    exit 1
fi

# Install NVIDIA driver
print_status "success" "Installing NVIDIA driver"
if bash /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run --accept-license --install-compat32-libs --glvnd-egl-config-path=/etc/glvnd/egl_vendor.d --dkms --run-nvidia-xconfig --silent; then
    print_status "success" "NVIDIA driver installed successfully"
else
    print_status "failure" "NVIDIA driver installation failed. Check /var/log/nvidia-installer.log for details."
    exit 1
fi

# Cleanup
cleanup() {
    TEMP_FILES=("/tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run")
    for file in "${TEMP_FILES[@]}"; do
        if rm -f "$file" > /dev/null 2>&1; then
            print_status "success" "Cleaned up temporary file: $file"
        else
            print_status "failure" "Failed to clean up temporary file: $file"
        fi
    done
}
cleanup

# Verify NVIDIA driver
print_status "success" "Verifying NVIDIA driver installation"
if nvidia-smi > /dev/null 2>&1; then
    print_status "success" "NVIDIA driver verified successfully"
else
    print_status "failure" "NVIDIA driver verification failed. Check hardware or logs."
    exit 1
fi

# Install CUDA keyring
print_status "success" "Installing CUDA keyring"
if sudo apt update > /dev/null 2>&1; then
    if sudo apt install -y cuda-keyring > /dev/null 2>&1; then
        print_status "success" "CUDA keyring installed successfully"
    else
        print_status "failure" "Failed to install CUDA keyring"
        exit 1
    fi
else
    print_status "failure" "Failed to update package lists"
    exit 1
fi
