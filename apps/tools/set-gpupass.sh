#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/set-gpupass.sh?$(date +%s))"
# purpose: set gpu passthrough

set -euo pipefail

echo "==> 0) Sanity checks"
lsmod | egrep 'nvidia|nouveau' >/dev/null && {
  echo "ERROR: 'nvidia' or 'nouveau' modules are loaded on the host. Purge/blacklist them first."; exit 1; }
dpkg -l | egrep 'nvidia|cuda|libnvidia' && echo "NOTE: Host NVIDIA/CUDA packages found. For passthrough you normally don't want these."

echo "==> 1) Verify IOMMU is active"
if ! dmesg | egrep -qi 'DMAR|IOMMU.*enabled|iommu.*Translated'; then
  echo "ERROR: IOMMU not active. Enable it in BIOS + add kernel flags (intel_iommu=on iommu=pt or amd_iommu=on iommu=pt)."; exit 1;
fi

echo "==> 2) Show current kernel cmdline (reference)"
cat /proc/cmdline

echo "==> 3) Ensure VFIO modules load at boot (idempotent)"
grep -q '^vfio_pci$' /etc/modules || cat >> /etc/modules << 'EOF'
vfio
vfio_pci
vfio_iommu_type1
vfio_virqfd
EOF

echo "==> 4) Detect NVIDIA GPU + audio PCI IDs"
# Pull all 10de devices, get unique IDs
IDS=$(lspci -Dnns | awk '/10de:/{print $0}' | awk -F'[][]' '{print $3}' | sort -u | paste -sd, -)
[ -n "$IDS" ] || { echo "ERROR: No NVIDIA (vendor 10de) devices found."; exit 1; }
echo "    NVIDIA device IDs detected: $IDS"

echo "==> 5) Bind to vfio-pci"
cat > /etc/modprobe.d/vfio.conf << EOF
options vfio-pci ids=${IDS} disable_vga=1
EOF

echo "==> 6) Rebuild initramfs"
update-initramfs -u

echo "==> Done. Please reboot your Proxmox node now."
echo "After reboot, verify with:"
echo "  lspci -k | grep -A3 -i nvidia"
echo "You should see: Kernel driver in use: vfio-pci"
