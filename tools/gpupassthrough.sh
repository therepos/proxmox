#!/bin/bash

# Variables
VMID=102  # Set your VM ID here
GPU_PCI_ID="01:00.0"  # GPU PCI ID
AUDIO_PCI_ID="01:00.1"  # GPU Audio PCI ID
VFIO_CONF="/etc/modprobe.d/vfio.conf"
CMDLINE_CONF="/etc/kernel/cmdline"
VM_CONF="/etc/pve/qemu-server/$VMID.conf"
VBIOS_PATH="/path/to/vbios.rom"  # Optional: Set to your vBIOS file if needed

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

# Check if GPU is already being passed through
if grep -q "$GPU_PCI_ID" $VFIO_CONF; then
  echo "GPU is currently configured for passthrough."
  read -p "Do you want to undo the passthrough configuration? [y/N]: " UNDO
  if [[ $UNDO =~ ^[Yy]$ ]]; then
    echo "Removing GPU from VFIO configuration."
    sed -i "/$GPU_PCI_ID/d" $VFIO_CONF
    sed -i "/$AUDIO_PCI_ID/d" $VFIO_CONF
    update-initramfs -u

    # Remove passthrough from VM configuration
    if [[ -f $VM_CONF ]]; then
      sed -i "/^hostpci0:/d" $VM_CONF
      sed -i "/^hostpci1:/d" $VM_CONF
      sed -i "/^args:/d" $VM_CONF
      echo "Passthrough configuration removed from VM $VMID."
    fi

    echo "Passthrough configuration undone. Please reboot the system for changes to take effect."
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
if ! grep -qE "(intel_iommu=on|amd_iommu=on)" $CMDLINE_CONF; then
  echo "Enabling IOMMU in kernel command line."
  if grep -q "intel" /proc/cpuinfo; then
    sed -i 's|$| intel_iommu=on iommu=pt|' $CMDLINE_CONF
  else
    sed -i 's|$| amd_iommu=on iommu=pt|' $CMDLINE_CONF
  fi
  proxmox-boot-tool refresh
  echo "IOMMU enabled. Please reboot the host before rerunning this script."
  exit 0
fi

# Step 2: Bind GPU to VFIO
echo "Binding GPU to VFIO driver."
echo "options vfio-pci ids=$(lspci -nn | grep $GPU_PCI_ID | awk -F '[\[\]]' '{print $2}'),$(lspci -nn | grep $AUDIO_PCI_ID | awk -F '[\[\]]' '{print $2}')" > $VFIO_CONF
update-initramfs -u

# Step 3: Update VM Configuration
echo "Configuring VM $VMID for GPU passthrough."
if [[ ! -f $VM_CONF ]]; then
  echo "VM configuration file $VM_CONF not found." >&2
  exit 1
fi

# Add GPU passthrough to VM config
sed -i "/^hostpci/d" $VM_CONF
echo "hostpci0: $GPU_PCI_ID,pcie=1" >> $VM_CONF
echo "hostpci1: $AUDIO_PCI_ID,pcie=1" >> $VM_CONF

# Add vBIOS if specified
if [[ -f $VBIOS_PATH ]]; then
  sed -i "/hostpci0:/s/$/,romfile=$VBIOS_PATH/" $VM_CONF
fi

# Ensure machine type and BIOS are set
sed -i "s/^bios:.*/bios: ovmf/" $VM_CONF
if ! grep -q "^machine:" $VM_CONF; then
  echo "machine: pc-q35-9.0" >> $VM_CONF
fi

# Add CPU args to hide KVM if not already set
if ! grep -q "^args:" $VM_CONF; then
  echo "args: -cpu host,kvm=off" >> $VM_CONF
fi

# Step 4: Reboot or Start VM
echo "GPU passthrough setup completed. You can now start the VM with 'qm start $VMID'."

exit 0
