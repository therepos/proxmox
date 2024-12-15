#!/usr/bin/env bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash

#!/usr/bin/env bash

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

# Checkpoints
STEP_BLACKLIST_NOUVEAU="/tmp/step_blacklist_nouveau_done"
STEP_INITRAMFS_UPDATE="/tmp/step_initramfs_update_done"
STEP_KERNEL_HEADERS="/tmp/step_kernel_headers_done"
STEP_DEPENDENCIES="/tmp/step_dependencies_done"
STEP_DRIVER_DOWNLOAD="/tmp/step_driver_download_done"
STEP_DRIVER_INSTALL="/tmp/step_driver_install_done"
STEP_CUDA_KEYRING="/tmp/step_cuda_keyring_done"

# Step 1: Blacklist Nouveau Driver
if [ ! -f "$STEP_BLACKLIST_NOUVEAU" ]; then
    print_status "success" "Blacklisting Nouveau driver"
    run_silent bash -c 'echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf'
    run_silent bash -c 'echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist-nouveau.conf'
    touch "$STEP_BLACKLIST_NOUVEAU"
fi

# Step 2: Update initramfs and Verify Nouveau Status
if [ ! -f "$STEP_INITRAMFS_UPDATE" ]; then
    print_status "success" "Updating initramfs"
    if run_silent update-initramfs -u; then
        print_status "success" "initramfs updated successfully"
        touch "$STEP_INITRAMFS_UPDATE"
    else
        print_status "failure" "Failed to update initramfs"
        exit 1
    fi

    # Check if Nouveau is still loaded
    print_status "success" "Checking if Nouveau is disabled"
    if lsmod | grep -q nouveau; then
        print_status "success" "Rebooting to disable Nouveau"
        reboot
        exit 0
    else
        print_status "success" "Nouveau is already disabled; no reboot needed"
    fi
fi

# Step 3: Install Kernel Headers
if [ ! -f "$STEP_KERNEL_HEADERS" ]; then
    print_status "success" "Checking and installing kernel headers"
    KERNEL_HEADERS="proxmox-headers-$(uname -r)"
    if dpkg-query -W -f='${Status}' $KERNEL_HEADERS 2>/dev/null | grep -q "install ok installed"; then
        print_status "success" "Kernel headers already installed: $KERNEL_HEADERS"
    else
        if run_silent apt install -y build-essential $KERNEL_HEADERS; then
            print_status "success" "Kernel headers and build-essential installed successfully"
            touch "$STEP_KERNEL_HEADERS"
        else
            print_status "failure" "Failed to install kernel headers. Verify your Proxmox setup."
            exit 1
        fi
    fi
fi

# Step 4: Install Additional Dependencies
DEPENDENCIES="pkg-config libglvnd-dev libx11-dev libxext-dev xorg-dev xserver-xorg-core xserver-xorg-dev lib32z1"
if [ ! -f "$STEP_DEPENDENCIES" ]; then
    print_status "success" "Installing additional dependencies"
    if run_silent apt install -y $DEPENDENCIES; then
        print_status "success" "Additional dependencies installed successfully"
        touch "$STEP_DEPENDENCIES"
    else
        print_status "failure" "Failed to install additional dependencies"
        exit 1
    fi
fi

# Step 5: Download NVIDIA Driver
NVIDIA_VERSION=${1:-"550.135"}
NVIDIA_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"
if [ ! -f "$STEP_DRIVER_DOWNLOAD" ]; then
    print_status "success" "Downloading NVIDIA driver"
    if run_silent wget -qO /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run "$NVIDIA_URL"; then
        print_status "success" "NVIDIA driver downloaded successfully"
        touch "$STEP_DRIVER_DOWNLOAD"
    else
        print_status "failure" "Failed to download NVIDIA driver"
        exit 1
    fi
fi

# Step 6: Install NVIDIA Driver
if [ ! -f "$STEP_DRIVER_INSTALL" ]; then
    print_status "success" "Installing NVIDIA driver"
    if run_silent bash /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run --accept-license --install-compat32-libs --glvnd-egl-config-path=/etc/glvnd/egl_vendor.d --dkms --run-nvidia-xconfig --silent; then
        print_status "success" "NVIDIA driver installed successfully"
        touch "$STEP_DRIVER_INSTALL"
    else
        print_status "failure" "NVIDIA driver installation failed. Check /var/log/nvidia-installer.log for details."
        exit 1
    fi
fi

# Step 7: Install CUDA Keyring
if [ ! -f "$STEP_CUDA_KEYRING" ]; then
    print_status "success" "Installing CUDA keyring"
    if run_silent apt update && run_silent apt install -y cuda-keyring; then
        print_status "success" "CUDA keyring installed successfully"
        touch "$STEP_CUDA_KEYRING"
    else
        print_status "failure" "Failed to install CUDA keyring"
        exit 1
    fi
fi

# Step 8: Verify NVIDIA Driver
print_status "success" "Verifying NVIDIA driver installation"
if nvidia-smi > /dev/null 2>&1; then
    print_status "success" "NVIDIA driver verified successfully"
else
    print_status "failure" "NVIDIA driver verification failed. Check hardware or logs."
    exit 1
fi

# Cleanup Temporary Files
print_status "success" "Cleaning up temporary files"
run_silent rm -f /tmp/NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run
run_silent rm -f "$STEP_BLACKLIST_NOUVEAU" "$STEP_INITRAMFS_UPDATE" "$STEP_KERNEL_HEADERS" "$STEP_DEPENDENCIES" "$STEP_DRIVER_DOWNLOAD" "$STEP_DRIVER_INSTALL" "$STEP_CUDA_KEYRING"

print_status "success" "NVIDIA driver installation completed successfully"
