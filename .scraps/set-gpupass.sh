#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/set-gpupass.sh?$(date +%s))"
# purpose: set gpu passthrough
# version: pve9

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "must be run as root"; exit 1; }

# 0) Host must not be using NVIDIA drivers
if lsmod | egrep -q '(^| )nvidia|nouveau( |$)'; then
  echo "ERROR: host has nvidia/nouveau modules loaded. Remove/blacklist first."; exit 1
fi
dpkg -l | egrep 'nvidia|cuda|libnvidia' && \
  echo "NOTE: Host NVIDIA/CUDA packages found. Usually not desired for passthrough."

# 1) Check IOMMU
if ! dmesg | egrep -qi 'DMAR|IOMMU.*enabled|iommu.*Translated'; then
  echo "ERROR: IOMMU not active. Enable in BIOS + kernel flags (intel_iommu=on iommu=pt or amd_iommu=on iommu=pt)."
  exit 1
fi

# Show current kernel cmdline (FYI only)
cat /proc/cmdline

# 2) Ensure vfio modules are loaded at boot
if ! grep -q '^vfio_pci$' /etc/modules; then
  cat >>/etc/modules <<'EOF'
vfio
vfio_pci
vfio_iommu_type1
vfio_virqfd
EOF
fi

# 3) Detect NVIDIA PCI IDs
IDS=$(lspci -Dnns | awk '/10de:/{print}' | awk -F'[][]' '{print $3}' | sort -u | paste -sd, -)
[[ -n "$IDS" ]] || { echo "ERROR: no NVIDIA devices found (vendor 10de)."; exit 1; }
echo "Detected NVIDIA IDs: $IDS"

# 4) Bind to vfio-pci
cat >/etc/modprobe.d/vfio.conf <<EOF
options vfio-pci ids=${IDS} disable_vga=1
EOF

# 5) Update initramfs
update-initramfs -u

echo "Done. Reboot now."
echo "After reboot:  lspci -k | grep -A3 -i nvidia  (expect vfio-pci)"
