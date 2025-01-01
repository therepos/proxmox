#!/bin/bash

GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# Step 1: Enable IOMMU in GRUB
echo "Configuring IOMMU settings..."
if ! grep -q "iommu=pt" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&intel_iommu=on amd_iommu=on iommu=pt /' /etc/default/grub
    update-grub
    echo -e "${GREEN}IOMMU settings added. Please reboot the system.${RESET}"
    exit 0
else
    echo -e "${GREEN}IOMMU settings already configured.${RESET}"
fi

# Step 2: Verify IOMMU Groups
echo "Verifying IOMMU groups..."
if find /sys/kernel/iommu_groups/ -type l | grep -q iommu_groups; then
    echo -e "${GREEN}IOMMU groups detected.${RESET}"
else
    echo -e "${RED}IOMMU groups not detected. Please check your system settings.${RESET}"
    exit 1
fi

# Step 3: Load VFIO Modules
echo "Loading VFIO modules..."
modprobe vfio vfio_pci vfio_iommu_type1
status_message $? "VFIO modules loaded"

# Ensure modules are loaded at boot
echo "Ensuring VFIO modules are loaded at boot..."
echo -e "vfio\nvfio_pci\nvfio_iommu_type1" > /etc/modules-load.d/vfio.conf
status_message $? "VFIO modules configured for boot"

# Step 4: Blacklist Conflicting Drivers
echo "Blacklisting conflicting drivers..."
cat <<EOF > /etc/modprobe.d/blacklist.conf
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist snd_hda_intel
EOF
update-initramfs -u
status_message $? "Conflicting drivers blacklisted"

# Step 5: Bind GPU to VFIO
echo "Binding GPU to VFIO..."
GPU_PCI_IDS="10de 2571"
GPU_AUDIO_IDS="10de 228e"
echo "$GPU_PCI_IDS" > /sys/bus/pci/drivers/vfio-pci/new_id
echo "$GPU_AUDIO_IDS" > /sys/bus/pci/drivers/vfio-pci/new_id
status_message $? "GPU and audio device bound to VFIO"

# Step 6: Verify GPU Binding
echo "Verifying GPU binding..."
if lspci -nnk | grep -A 3 -E "01:00.0|01:00.1" | grep -q vfio-pci; then
    echo -e "${GREEN}GPU is successfully bound to VFIO.${RESET}"
else
    echo -e "${RED}GPU binding failed. Please check the setup.${RESET}"
    exit 1
fi

# Optional: Add VM Configuration Commands Here
echo -e "${GREEN}GPU passthrough setup complete. Please reboot.${RESET}"
