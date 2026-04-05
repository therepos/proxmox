#!/usr/bin/env bash
# proxmox-gpu-guardrails.sh
# Validate common GPU passthrough + headless (Sunshine/Moonlight) VM pitfalls on Proxmox VE 9.
# Usage:
#   sudo bash proxmox-gpu-guardrails.sh <VMID> [GPU_BDF_PREFIX]
# Examples:
#   sudo bash proxmox-gpu-guardrails.sh 100
#   sudo bash proxmox-gpu-guardrails.sh 100 01:00
#
# Notes:
# - GPU_BDF_PREFIX is like "01:00" (without .0/.1). If provided, we validate bindings and duplication.
# - This script does NOT modify anything. It only reports PASS/WARN/FAIL and suggested fixes.

set -euo pipefail

VMID="${1:-}"
GPU_PREFIX="${2:-}"   # e.g. 01:00

if [[ -z "${VMID}" ]]; then
  echo "Usage: $0 <VMID> [GPU_BDF_PREFIX like 01:00]"
  exit 2
fi

CONF="/etc/pve/qemu-server/${VMID}.conf"
if [[ ! -f "${CONF}" ]]; then
  echo "FAIL: VM config not found: ${CONF}"
  exit 2
fi

PASS() { echo -e "PASS: $*"; }
WARN() { echo -e "WARN: $*"; }
FAIL() { echo -e "FAIL: $*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

section() { echo -e "\n== $* =="; }

section "Host basics"

# CPU vendor and IOMMU kernel flags
CPU_VENDOR="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
[[ -z "${CPU_VENDOR}" ]] && CPU_VENDOR="unknown"

CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
GRUB_CFG="$(grep -E 'GRUB_CMDLINE_LINUX_DEFAULT=|GRUB_CMDLINE_LINUX=' /etc/default/grub 2>/dev/null || true)"

echo "Info: CPU vendor: ${CPU_VENDOR}"
echo "Info: /proc/cmdline: ${CMDLINE}"

IOMMU_ENABLED="no"
if dmesg 2>/dev/null | grep -qiE 'IOMMU enabled|DMAR: IOMMU enabled|AMD-Vi:.*enabled'; then
  IOMMU_ENABLED="yes"
fi

if [[ "${IOMMU_ENABLED}" == "yes" ]]; then
  PASS "IOMMU appears enabled (dmesg)."
else
  WARN "IOMMU not clearly enabled (dmesg). Ensure kernel cmdline has intel_iommu=on or amd_iommu=on (and VT-d/AMD-Vi enabled in BIOS)."
fi

if [[ "${CPU_VENDOR}" =~ Intel ]]; then
  if echo "${CMDLINE}" | grep -q 'intel_iommu=on'; then PASS "intel_iommu=on present in kernel cmdline."
  else WARN "intel_iommu=on missing from kernel cmdline (required for Intel passthrough)."; fi
elif [[ "${CPU_VENDOR}" =~ AMD ]]; then
  if echo "${CMDLINE}" | grep -q 'amd_iommu=on'; then PASS "amd_iommu=on present in kernel cmdline."
  else WARN "amd_iommu=on missing from kernel cmdline (required for AMD passthrough)."; fi
else
  WARN "Unknown CPU vendor; can't verify correct IOMMU flag."
fi

# VFIO modules present/loaded
VFIO_MODS=(vfio vfio_pci vfio_iommu_type1 vfio_virqfd)
MISSING=()
for m in "${VFIO_MODS[@]}"; do
  if lsmod | awk '{print $1}' | grep -qx "${m}"; then
    :
  else
    MISSING+=("${m}")
  fi
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  PASS "VFIO modules loaded: ${VFIO_MODS[*]}"
else
  WARN "VFIO modules not all loaded: ${MISSING[*]} (may still work if autoloaded when VM starts)."
fi

section "VM configuration sanity (${CONF})"

# Read key VM options
MACHINE="$(grep -E '^machine:' "${CONF}" | awk '{print $2}' || true)"
BIOS="$(grep -E '^bios:' "${CONF}" | awk '{print $2}' || true)"
TPM="$(grep -E '^tpmstate0:' "${CONF}" || true)"
VGA_LINE="$(grep -E '^vga:' "${CONF}" || true)"

HOSTPCI_LINES="$(grep -E '^hostpci[0-9]+:' "${CONF}" || true)"
DISPLAY_LINE="$(grep -E '^vga:|^display:' "${CONF}" || true)" # Proxmox uses vga: none typically

echo "Info: machine=${MACHINE:-<unset>} bios=${BIOS:-<unset>} vga_line=${VGA_LINE:-<unset>}"
[[ -n "${TPM}" ]] && echo "Info: TPM configured."

if [[ "${MACHINE}" == pc-q35* || "${MACHINE}" == q35* ]]; then
  PASS "Machine type looks like q35 (${MACHINE})."
else
  WARN "Machine type not q35 (machine: ${MACHINE:-<unset>}). For GPU passthrough, q35 is recommended."
fi

if [[ "${BIOS}" == "ovmf" ]]; then
  PASS "BIOS is OVMF (UEFI)."
else
  WARN "BIOS not set to OVMF (bios: ${BIOS:-<unset>}). Windows 11 + passthrough typically expects OVMF."
fi

if [[ -n "${TPM}" ]]; then
  PASS "TPM state present (good for Windows 11)."
else
  WARN "No TPM state found; Windows 11 may require TPM 2.0."
fi

if echo "${CONF}" | grep -qE '^cpu:.*host'; then
  PASS "CPU type includes host."
else
  WARN "CPU type does not include host; for best perf/compat, set CPU to host."
fi

# Display expectations: for true headless passthrough, vga: none is typical
if grep -qE '^vga:\s*none' "${CONF}"; then
  PASS "VM display is disabled (vga: none) — correct for headless passthrough."
else
  WARN "VM display is not 'vga: none'. If you intend headless GPU-only, set vga: none (but ensure you have RDP/Moonlight recovery first)."
fi

# Check for common duplicate hostpci all-functions vs separate functions mistake
if [[ -n "${HOSTPCI_LINES}" ]]; then
  echo "Info: hostpci entries:"
  echo "${HOSTPCI_LINES}" | sed 's/^/  - /'
else
  WARN "No hostpci passthrough entries found in VM config."
fi

# Parse hostpci entries and look for duplicates of same device/function
declare -A SEEN_PCI=()
DUPES=0
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  # Example: hostpci0: 0000:01:00.0,pcie=1,x-vga=1
  # or:      hostpci0: 01:00,pcie=1, ...
  val="${line#*: }"
  addr="$(echo "${val}" | cut -d',' -f1)"
  # Normalize to full domain if possible
  if [[ "${addr}" =~ ^[0-9a-fA-F]{4}: ]]; then
    norm="${addr}"
  else
    # assume 00: and no domain -> 0000:
    norm="0000:${addr}"
    # if it was 01:00 (no .0/.1), keep as-is (functionless)
  fi
  if [[ -n "${SEEN_PCI[${norm}]:-}" ]]; then
    DUPES=$((DUPES+1))
  else
    SEEN_PCI["${norm}"]=1
  fi
done < <(echo "${HOSTPCI_LINES}")

if [[ "${DUPES}" -gt 0 ]]; then
  WARN "Possible duplicate passthrough entries detected (same PCI assigned more than once). Watch for: hostpci0 has 'all functions' AND you also added 01:00.1 separately."
else
  PASS "No obvious duplicate passthrough entries."
fi

# If GPU prefix provided, validate the pattern most people want:
# - hostpci includes ${GPU_PREFIX}.0 with x-vga=1 (primary)
# - hostpci includes ${GPU_PREFIX}.1 without x-vga=1
if [[ -n "${GPU_PREFIX}" ]]; then
  section "GPU-specific checks (prefix ${GPU_PREFIX})"

  # Resolve to domain form for sysfs lookups
  GPU0="0000:${GPU_PREFIX}.0"
  GPU1="0000:${GPU_PREFIX}.1"

  if [[ -e "/sys/bus/pci/devices/${GPU0}" ]]; then PASS "GPU function exists: ${GPU0}"; else WARN "GPU function not found in sysfs: ${GPU0}"; fi
  if [[ -e "/sys/bus/pci/devices/${GPU1}" ]]; then PASS "Audio function exists: ${GPU1}"; else WARN "Audio function not found in sysfs: ${GPU1}"; fi

  # Check VM config contains them
  if grep -q "${GPU_PREFIX}.0" "${CONF}" || grep -q "${GPU_PREFIX}," "${CONF}"; then
    PASS "VM config references GPU video function (${GPU_PREFIX}.0) or whole device (${GPU_PREFIX})."
  else
    FAIL "VM config does not reference GPU video function (${GPU_PREFIX}.0)."
  fi
  if grep -q "${GPU_PREFIX}.1" "${CONF}" || grep -q "${GPU_PREFIX}," "${CONF}"; then
    PASS "VM config references GPU audio function (${GPU_PREFIX}.1) or whole device (${GPU_PREFIX})."
  else
    WARN "VM config does not reference GPU audio function (${GPU_PREFIX}.1). (Audio passthrough optional.)"
  fi

  # Ensure ONLY the video function has x-vga=1 (primary)
  X_VGA_LINES="$(grep -E '^hostpci[0-9]+:.*x-vga=1' "${CONF}" || true)"
  if [[ -z "${X_VGA_LINES}" ]]; then
    WARN "No x-vga=1 found. For single-GPU passthrough/primary GPU, set x-vga=1 on ${GPU_PREFIX}.0."
  else
    # If any x-vga line references .1, that's bad.
    if echo "${X_VGA_LINES}" | grep -q "${GPU_PREFIX}\.1"; then
      FAIL "x-vga=1 appears on the audio function (${GPU_PREFIX}.1). Remove it; only ${GPU_PREFIX}.0 should be primary."
    else
      PASS "x-vga=1 not applied to audio function."
    fi
  fi

  # VFIO binding check (host side)
  if [[ -e "/sys/bus/pci/devices/${GPU0}/driver" ]]; then
    DRIVER0="$(basename "$(readlink "/sys/bus/pci/devices/${GPU0}/driver")")"
    echo "Info: Host driver for ${GPU0}: ${DRIVER0}"
    if [[ "${DRIVER0}" == "vfio-pci" ]]; then PASS "${GPU0} bound to vfio-pci."
    else WARN "${GPU0} not bound to vfio-pci (currently ${DRIVER0}). Host must bind GPU to vfio-pci for passthrough."; fi
  else
    WARN "Could not read host driver for ${GPU0}."
  fi

  if [[ -e "/sys/bus/pci/devices/${GPU1}/driver" ]]; then
    DRIVER1="$(basename "$(readlink "/sys/bus/pci/devices/${GPU1}/driver")")"
    echo "Info: Host driver for ${GPU1}: ${DRIVER1}"
    if [[ "${DRIVER1}" == "vfio-pci" ]]; then PASS "${GPU1} bound to vfio-pci."
    else WARN "${GPU1} not bound to vfio-pci (currently ${DRIVER1})."; fi
  fi

  # IOMMU group sanity (not always fatal if shared, but important)
  if [[ -e "/sys/bus/pci/devices/${GPU0}/iommu_group" ]]; then
    G0="$(basename "$(readlink "/sys/bus/pci/devices/${GPU0}/iommu_group")")"
    echo "Info: IOMMU group for ${GPU0}: ${G0}"
    GROUP_DEVS="$(ls "/sys/kernel/iommu_groups/${G0}/devices" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${GROUP_DEVS}" -le 2 ]]; then
      PASS "IOMMU group ${G0} looks tight (${GROUP_DEVS} device(s))."
    else
      WARN "IOMMU group ${G0} has ${GROUP_DEVS} devices. Passthrough may still work, but isolation is weaker (consider ACS if needed)."
    fi
  else
    WARN "No iommu_group link for ${GPU0} (IOMMU may be off)."
  fi
fi

section "Operational checks / reminders"

# Check if VM is running
if have_cmd qm; then
  STATUS="$(qm status "${VMID}" 2>/dev/null || true)"
  echo "Info: ${STATUS}"
else
  WARN "qm command not found; are you on Proxmox host?"
fi

cat <<'EOF'

Notes:
- If you plan headless GPU-only streaming (Moonlight/Sunshine), 'vga: none' is correct, but you must have:
  - A working RDP/Guacamole path AND/OR Sunshine reachable (Tailscale, LAN) before you disable the Proxmox display.
  - A virtual monitor solution (e.g., Virtual Display Driver inside Windows) if your GPU/headless setup needs it.

- If your VM fails to start with "device ... assigned more than once":
  - You likely added 01:00.1 separately AND also enabled all-functions on 01:00.0 entry. Use either:
    * one hostpci with all functions, OR
    * two hostpci entries, but no all-functions duplication.

EOF

PASS "Guardrails script completed."
