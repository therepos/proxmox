#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-gpu.sh?$(date +%s))"
# purpose: setups/switches nvidia gpu passthrough between vm and docker

# List available VMs in numbered format
echo "Available VMs:"
mapfile -t VM_LIST < <(qm list | awk 'NR>1 {print $1, $2}')

if [[ ${#VM_LIST[@]} -eq 0 ]]; then
  echo "No VMs found. Exiting."
  exit 1
fi

for i in "${!VM_LIST[@]}"; do
  echo "$((i + 1)). ${VM_LIST[$i]}"
done

# Prompt the user to select a VM
read -p "Enter the VM selection to bind/unbind the GPU: " VM_OPTION

# Validate selection
if ! [[ "$VM_OPTION" =~ ^[0-9]+$ ]] || (( VM_OPTION < 1 || VM_OPTION > ${#VM_LIST[@]} )); then
  echo "Invalid selection. Exiting."
  exit 1
fi

# Get selected VM ID
VMID=$(echo "${VM_LIST[$((VM_OPTION - 1))]}" | awk '{print $1}')
echo "Selected VM ID: $VMID"

# Variables
GPU_PCI_ID="01:00.0"  # GPU PCI ID
AUDIO_PCI_ID="01:00.1"  # GPU Audio PCI ID
VFIO_CONF="/etc/modprobe.d/vfio.conf"
CMDLINE_CONF="/etc/kernel/cmdline"
VM_CONF="/etc/pve/qemu-server/$VMID.conf"
MODULES_FILE="/etc/modules"

PROXMOX_REBOOT_REQUIRED=false
VM_REBOOT_REQUIRED=false

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
  echo "must be run as root." >&2
  exit 1
fi

# Check if the VM exists
if ! qm status "$VMID" > /dev/null 2>&1; then
  echo "VM $VMID does not exist. Please check the VM ID and try again." >&2
  exit 1
fi

# Extract GPU and Audio IDs dynamically
GPU_IDS=$(lspci -nn | grep "$GPU_PCI_ID" | awk -F '[\\[\\]]' '{print $2}')
AUDIO_IDS=$(lspci -nn | grep "$AUDIO_PCI_ID" | awk -F '[\\[\\]]' '{print $2}')

# Check if the GPU is already configured for passthrough
if grep -q "$GPU_IDS" "$VFIO_CONF" && grep -q "$AUDIO_IDS" "$VFIO_CONF"; then
  echo "GPU is currently configured for passthrough."
  read -p "Do you want to undo the passthrough configuration? [y/N]: " UNDO
  if [[ $UNDO =~ ^[Yy]$ ]]; then
    echo "Removing GPU from VFIO configuration."
    sed -i "/$GPU_IDS/d" "$VFIO_CONF"
    sed -i "/$AUDIO_IDS/d" "$VFIO_CONF"
    
    if ! update-initramfs -u; then
      echo "Failed to update initramfs. Please check your system." >&2
      exit 1
    fi
    PROXMOX_REBOOT_REQUIRED=true

    # Remove passthrough from VM configuration
    if [[ -f $VM_CONF ]]; then
      sed -i "/^hostpci0:/d" "$VM_CONF"
      sed -i "/^hostpci1:/d" "$VM_CONF"
      sed -i "/^args:/d" "$VM_CONF"
      echo "Passthrough configuration removed from VM $VMID."
    fi

    # Rebind GPU to NVIDIA drivers
    echo "Rebinding GPU to NVIDIA drivers."
    
    # Check if the GPU is bound to vfio-pci
    if [[ -e "/sys/bus/pci/devices/0000:$GPU_PCI_ID/driver" && "$(readlink /sys/bus/pci/devices/0000:$GPU_PCI_ID/driver)" == *vfio-pci* ]]; then
      echo "Unbinding GPU from vfio-pci."
      echo "0000:$GPU_PCI_ID" > /sys/bus/pci/drivers/vfio-pci/unbind
      echo "0000:$AUDIO_PCI_ID" > /sys/bus/pci/drivers/vfio-pci/unbind
    else
      echo "GPU is not bound to vfio-pci. Skipping unbind step."
    fi
    
    # Bind GPU to NVIDIA driver
    if [[ -e "/sys/bus/pci/devices/0000:$GPU_PCI_ID" ]]; then
      echo "0000:$GPU_PCI_ID" > /sys/bus/pci/drivers_probe
      echo "0000:$AUDIO_PCI_ID" > /sys/bus/pci/drivers_probe
      echo "GPU successfully rebound to NVIDIA drivers."
    else
      echo "Error: GPU device not found. Unable to rebind to NVIDIA drivers." >&2
      exit 1
    fi

    # Restart Docker to ensure it detects the GPU
    echo "Restarting Docker to enable GPU usage."
    systemctl restart docker

    echo "GPU is now available for Docker or other workloads on the host."
    if $PROXMOX_REBOOT_REQUIRED; then
      echo "System-level changes were made. Please reboot Proxmox for changes to take effect."
    else
      echo "No system reboot required. GPU is ready for host use."
    fi
    exit 0
  else
    echo "No changes made."
    exit 0
  fi
else
  echo "GPU is not currently configured for passthrough."
  read -p "Do you want to configure GPU passthrough? [y/N]: " PROCEED
  if [[ ! $PROCEED =~ ^[Yy]$ ]]; then
    echo "No changes made."
    exit 0
  fi
fi

# Step 1: Enable IOMMU
if ! grep -qE "(intel_iommu=on|amd_iommu=on)" "$CMDLINE_CONF"; then
  echo "Enabling IOMMU in kernel command line."
  if grep -q "intel" /proc/cpuinfo; then
    sed -i 's|$| intel_iommu=on iommu=pt|' "$CMDLINE_CONF"
  else
    sed -i 's|$| amd_iommu=on iommu=pt|' "$CMDLINE_CONF"
  fi

  if ! proxmox-boot-tool refresh; then
    echo "Failed to refresh Proxmox bootloader." >&2
    exit 1
  fi
  PROXMOX_REBOOT_REQUIRED=true
fi

# Step 2: Bind GPU to VFIO
echo "Binding GPU to VFIO driver."
if ! grep -q "$GPU_IDS" "$VFIO_CONF"; then
  echo "options vfio-pci ids=${GPU_IDS},${AUDIO_IDS}" > "$VFIO_CONF"
  if ! update-initramfs -u; then
    echo "Failed to update initramfs. Please check your system." >&2
    exit 1
  fi
  PROXMOX_REBOOT_REQUIRED=true
fi

# Step 3: Update VM Configuration
echo "Configuring VM $VMID for GPU passthrough."
if [[ ! -f $VM_CONF ]]; then
  echo "VM configuration file $VM_CONF not found." >&2
  exit 1
fi

# Add GPU passthrough to VM config
if ! grep -q "^hostpci0:" "$VM_CONF"; then
  sed -i "/^hostpci/d" "$VM_CONF"
  echo "hostpci0: $GPU_PCI_ID,pcie=1" >> "$VM_CONF"
  echo "hostpci1: $AUDIO_PCI_ID,pcie=1" >> "$VM_CONF"
  VM_REBOOT_REQUIRED=true
fi

# Ensure machine type and BIOS are set
sed -i "s/^bios:.*/bios: ovmf/" "$VM_CONF"
if ! grep -q "^machine:" "$VM_CONF"; then
  echo "machine: pc-q35-9.0" >> "$VM_CONF"
fi

# Add CPU args to hide KVM if not already set
if ! grep -q "^args:" "$VM_CONF"; then
  echo "args: -cpu host,kvm=off" >> "$VM_CONF"
  VM_REBOOT_REQUIRED=true
fi

# Step 4: Ensure VFIO modules are loaded at boot
VFIO_MODULES=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd")
echo "Ensuring VFIO modules are loaded at boot."
for MODULE in "${VFIO_MODULES[@]}"; do
  if ! grep -q "^$MODULE" "$MODULES_FILE"; then
    echo "$MODULE" >> "$MODULES_FILE"
    echo "Added $MODULE to $MODULES_FILE."
    PROXMOX_REBOOT_REQUIRED=true
  else
    echo "$MODULE is already present in $MODULES_FILE."
  fi
done

# Final Notification
if $PROXMOX_REBOOT_REQUIRED; then
  echo "System-level changes were made. Please reboot Proxmox for changes to take effect."
elif $VM_REBOOT_REQUIRED; then
  echo "Only the VM configuration was updated. Please reboot VM $VMID for changes to take effect."
else
  echo "No reboot required. All changes are effective immediately."
fi

exit 0
