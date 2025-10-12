#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-nvidiadriver2.sh?$(date +%s))"
# purpose: installs nvidia driver and container toolkit
# =====
# notes:
# - continuous monitoring: watch -n 1 nvidia-smi
# - container specific monitoring: docker exec -it <container_id> /bin/bash
# - update nvidia-driver:
#   sudo apt-get purge nvidia-*
#   sudo update-initramfs -u
#   sudo reboot

#!/usr/bin/env bash
set -euo pipefail

# ---------- UI ----------
G="\e[32m✔\e[0m"; R="\e[31m✘\e[0m"; B="\e[34mℹ\e[0m"; Y="\e[33m!\e[0m"
ok(){ echo -e "${G} $*"; } info(){ echo -e "${B} $*"; } warn(){ echo -e "${Y} $*"; }
fail(){ echo -e "${R} $*"; exit 1; }
ask(){ local p="$1" d="${2:-}"; read -rp "$p${d:+ [$d]}: " REPLY </dev/tty || true; REPLY="${REPLY:-$d}"; }
yesno(){ local q="$1" d="${2:-N}"; ask "$q (y/N)" "$d"; [[ "${REPLY,,}" == "y" ]]; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Run as root"; } ; need_root

# ---------- helpers ----------
pkg(){ apt-get update -y; apt-get install -y "$@"; }
drv_ver(){ command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 || echo ""; }
has_vfio_cfg(){ [[ -f /etc/modprobe.d/vfio-pci.conf ]] || [[ -f /etc/modules-load.d/vfio_pci.conf ]]; }
gpu_lines(){ lspci -nn | grep -i 'nvidia'; }
grub_file="/etc/default/grub"

ensure_headers(){ pkg pve-headers-$(uname -r) || pkg linux-headers-$(uname -r); }

ensure_iommu_grub(){
  local cpuflag line
  if lscpu | grep -qi intel; then cpuflag="intel_iommu=on iommu=pt"; else cpuflag="amd_iommu=on iommu=pt"; fi
  line=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" || true)
  [[ -z "$line" ]] && fail "GRUB_CMDLINE_LINUX_DEFAULT not found in $grub_file"
  if ! grep -q "$cpuflag" <<<"$line"; then
    cp "$grub_file" "${grub_file}.bak.$(date +%s)"
    sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $cpuflag\"/" "$grub_file"
    info "Updated GRUB kernel params with: $cpuflag"
    update-grub
  fi
}

unbind_vfio_clean(){
  rm -f /etc/modprobe.d/vfio-pci.conf
  rm -f /etc/modules-load.d/vfio.conf /etc/modules-load.d/vfio_pci.conf /etc/modules-load.d/vfio_iommu_type1.conf
  rm -f /etc/modprobe.d/blacklist-nvidia.conf
  update-initramfs -u
  ok "Passthrough config removed. Reboot to return GPU to host."
  yesno "Reboot now?" && reboot
}

# ---------- HOST MODE ----------
install_host_driver(){
  info "Installing NVIDIA driver + container toolkit (host mode)…"
  ensure_headers
  pkg curl gnupg2 lsb-release

  # blacklist nouveau (safe repeat)
  echo -e "blacklist nouveau\noptions nouveau modeset=0" >/etc/modprobe.d/blacklist-nouveau.conf
  update-initramfs -u

  # CUDA repo (Debian 12 / Bookworm; valid for PVE9)
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/3bf863cc.pub \
    | gpg --dearmor -o /usr/share/keyrings/nvidia.gpg
  echo "deb [signed-by=/usr/share/keyrings/nvidia.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64 /" \
    >/etc/apt/sources.list.d/nvidia-cuda.list

  apt-get update -y
  pkg nvidia-driver nvidia-container-toolkit

  ok "Driver installed."
  yesno "Reboot now?" && reboot
}

uninstall_host_driver(){
  info "Purging NVIDIA driver packages…"
  apt-get purge -y 'nvidia-*' || true
  rm -f /etc/apt/sources.list.d/nvidia-cuda.list
  update-initramfs -u
  ok "Driver removed."
  yesno "Reboot now?" && reboot
}

host_mode_menu(){
  # If currently set for passthrough, offer cleanup first
  if has_vfio_cfg || lspci -k | awk '/NVIDIA/{f=1} f&&/Kernel driver in use:/{print; exit}' | grep -q 'vfio-pci'; then
    warn "GPU appears configured for passthrough (vfio-pci)."
    if yesno "Switch back to Host Mode and unbind from vfio-pci?"; then
      unbind_vfio_clean
      return
    fi
  fi

  local cur; cur="$(drv_ver)"
  if [[ -n "$cur" ]]; then
    echo "NVIDIA driver detected: $cur"
    echo "1) Leave as-is (show nvidia-smi)"
    echo "2) Reinstall/Upgrade driver"
    echo "3) Uninstall driver"
    echo "0) Back"
    ask "Choose [0-3]" "1"
    case "$REPLY" in
      1) nvidia-smi || true ;;
      2) install_host_driver ;;
      3) uninstall_host_driver ;;
      0) ;;
      *) echo "Invalid" ;;
    esac
  else
    echo "No host driver detected."
    echo "1) Install driver + container toolkit"
    echo "0) Back"
    ask "Choose [0-1]" "1"
    [[ "$REPLY" == "1" ]] && install_host_driver
  fi
}

# ---------- PASSTHROUGH ----------
setup_passthrough(){
  info "Configuring GPU passthrough (vfio-pci)…"
  ensure_headers
  ensure_iommu_grub

  # Offer to remove host driver to avoid conflicts
  if [[ -n "$(drv_ver)" ]]; then
    if yesno "Host NVIDIA driver detected. Remove it to avoid conflicts?"; then
      uninstall_host_driver
      # returns after reboot if chosen
    fi
  fi

  # Detect single NVIDIA GPU & audio
  mapfile -t LINES < <(gpu_lines)
  [[ ${#LINES[@]} -gt 0 ]] || fail "No NVIDIA GPU detected."
  GPU_ADDR="$(echo "${LINES[0]}" | awk '{print $1}')"                 # e.g., 65:00.0
  GPU_ID="$(echo "${LINES[0]}"   | grep -oP '\[\K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}')"
  BUS="${GPU_ADDR%:*}"; SLOT_FUNC="${GPU_ADDR##*:}"; SLOT="${SLOT_FUNC%.*}"
  AUDIO_ADDR="${BUS}:${SLOT}.1"
  AUDIO_LINE="$(lspci -nn | grep -i "^${AUDIO_ADDR} ")"
  AUDIO_ID=""; [[ -n "$AUDIO_LINE" ]] && AUDIO_ID="$(echo "$AUDIO_LINE" | grep -oP '\[\K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}')"

  # Blacklist host drivers so they don't claim GPU on next boot
  echo -e "blacklist nouveau\noptions nouveau modeset=0" >/etc/modprobe.d/blacklist-nouveau.conf
  echo -e "blacklist nvidia\nblacklist nvidiafb\nblacklist rivafb" >/etc/modprobe.d/blacklist-nvidia.conf

  # Load vfio modules on boot
  echo "vfio" >/etc/modules-load.d/vfio.conf
  echo "vfio_pci" >/etc/modules-load.d/vfio_pci.conf
  echo "vfio_iommu_type1" >/etc/modules-load.d/vfio_iommu_type1.conf

  # Bind by IDs (GPU + audio if present)
  if [[ -n "$AUDIO_ID" ]]; then
    echo "options vfio-pci ids=${GPU_ID},${AUDIO_ID}" >/etc/modprobe.d/vfio-pci.conf
  else
    echo "options vfio-pci ids=${GPU_ID}" >/etc/modprobe.d/vfio-pci.conf
  fi

  update-initramfs -u
  ok "VFIO configured for GPU ${GPU_ADDR}${AUDIO_ID:+ (+ audio ${AUDIO_ADDR})}."
  warn "Passthrough requires a reboot to fully take effect."

  # Bind to a VM now (writes config; will work after reboot)
  echo
  echo "Bind GPU to a VM now?"
  echo "1) Yes"
  echo "2) No (assign later in GUI)"
  ask "Choose [1-2]" "1"
  if [[ "$REPLY" == "1" ]]; then
    echo; qm list || warn "Could not list VMs (qm missing?)"
    ask "Enter VMID to assign GPU to"
    VMID="$REPLY"; [[ -n "$VMID" ]] || fail "No VMID provided."
    qm set "$VMID" --hostpci0 "${GPU_ADDR},pcie=1" >/dev/null
    if [[ -n "$AUDIO_ID" ]]; then
      qm set "$VMID" --hostpci1 "${AUDIO_ADDR},pcie=1" >/dev/null
    fi
    ok "Assigned GPU ${GPU_ADDR}${AUDIO_ID:+ and ${AUDIO_ADDR}} to VM ${VMID}."
  fi

  yesno "Reboot now to activate passthrough?" && reboot
}

# ---------- MENU ----------
while true; do
  echo
  echo "NVIDIA Setup Menu:"
  echo "1) Host Mode  (install/upgrade/uninstall driver + container toolkit)"
  echo "2) Passthrough Mode  (vfio-pci; optional VM bind before reboot)"
  echo "0) Exit"
  ask "Choose [0-2]" "1"
  case "$REPLY" in
    1) host_mode_menu ;;
    2) setup_passthrough ;;
    0) exit 0 ;;
    *) echo "Invalid";;
  esac
done
