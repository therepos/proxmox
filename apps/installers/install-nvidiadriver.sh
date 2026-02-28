#!/usr/bin/env bash
set -euo pipefail

# pve-nvidia-easy.sh
# Goal: fuss-free host NVIDIA driver + Docker GPU enablement on Proxmox using APT (no .run installer)
echo "Proxmox NVIDIA Easy Installer"
echo "Version 1.0"

RED="\033[0;31m"; GRN="\033[0;32m"; YLW="\033[0;33m"; BLU="\033[0;34m"; NC="\033[0m"
say() { echo -e "${BLU}==>${NC} $*"; }
ok()  { echo -e "${GRN}OK:${NC} $*"; }
warn(){ echo -e "${YLW}WARN:${NC} $*"; }
die() { echo -e "${RED}ERR:${NC} $*"; exit 1; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root (sudo -i)."; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pause_confirm() {
  local prompt="${1:-Continue? [y/N]} "
  read -r -p "$prompt" ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

detect_env() {
  [[ -f /etc/pve/.version ]] || die "This doesn't look like a Proxmox host (/etc/pve/.version missing)."
  PVE_VER="$(pveversion 2>/dev/null | head -n1 || true)"
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
  say "Detected: ${PVE_VER}"
  say "Detected OS: ${OS_ID} ${OS_VER} (${VERSION_CODENAME:-no-codename})"
}

check_gpu_present() {
  if ! have_cmd lspci; then apt-get update -y && apt-get install -y pciutils; fi
  if ! lspci | grep -Ei 'NVIDIA|RTX|Quadro|GeForce' >/dev/null; then
    die "No NVIDIA GPU detected by lspci."
  fi
  ok "NVIDIA GPU detected."
}

check_vfio_binding() {
  if ! have_cmd lspci; then return 0; fi
  local lines
  lines="$(lspci -nnk | awk 'BEGIN{RS="";FS="\n"} /NVIDIA/ {print $0 "\n"}' || true)"
  if echo "$lines" | grep -q "Kernel driver in use: vfio-pci"; then
    warn "Your NVIDIA GPU is currently bound to vfio-pci (passthrough mode)."
    warn "Host driver install will NOT work until you undo vfio binding for the GPU."
    echo
    echo "$lines"
    echo
    warn "If you want, stop now and revert your passthrough config first."
    pause_confirm "Continue anyway (not recommended)? [y/N] " || exit 0
  fi
}

driver_status() {
  if have_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    ok "NVIDIA driver already working (nvidia-smi OK)."
    nvidia-smi || true
    return 0
  fi
  warn "NVIDIA driver not working yet (nvidia-smi failed or missing)."
  return 1
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
}

enable_nonfree_components_deb822() {
  # Debian 12/13 commonly uses deb822 sources files (*.sources)
  local f="/etc/apt/sources.list.d/debian.sources"
  [[ -f "$f" ]] || return 0

  backup_file "$f"
  # Add missing components to any "Components:" line
  # Ensure: main contrib non-free non-free-firmware
  if grep -q "^Components:" "$f"; then
    sed -i -E 's/^Components:(.*)$/Components: main contrib non-free non-free-firmware/' "$f"
    ok "Updated $f Components -> main contrib non-free non-free-firmware"
  else
    warn "No Components: line found in $f (skipping)."
  fi
}

enable_nonfree_components_legacy() {
  # Legacy /etc/apt/sources.list style
  local f="/etc/apt/sources.list"
  [[ -f "$f" ]] || return 0

  backup_file "$f"
  # Add contrib non-free non-free-firmware to Debian repo lines that already have "main"
  sed -i -E 's/^(deb\s+[^#].*\s)(main)(\s*)$/\1main contrib non-free non-free-firmware\3/g' "$f"
  sed -i -E 's/^(deb\s+[^#].*\s)(main)(\s+contrib\s+non-free)(\s*)$/\1main contrib non-free non-free-firmware\4/g' "$f"
  ok "Updated $f to include contrib/non-free/non-free-firmware where applicable."
}

install_prereqs() {
  say "Installing prerequisites (headers, dkms, build tools)…"
  apt-get update -y
  apt-get install -y "pve-headers-$(uname -r)" dkms build-essential
  ok "Prerequisites installed."
}

install_nvidia_driver_apt() {
  say "Installing NVIDIA driver via APT (recommended)…"
  apt-get install -y nvidia-driver
  ok "nvidia-driver installed."
}

install_container_toolkit() {
  # Use distro packages if available; otherwise you may need NVIDIA repo.
  # We'll try APT first; if it fails, we stop and tell the user.
  say "Installing NVIDIA Container Toolkit (for Docker GPU)…"
  if apt-get install -y nvidia-container-toolkit; then
    ok "nvidia-container-toolkit installed."
  else
    warn "Could not install nvidia-container-toolkit from current APT sources."
    warn "You may need to add NVIDIA's libnvidia-container repository for your distro."
    warn "See NVIDIA docs for repository setup."
    return 1
  fi

  if have_cmd nvidia-ctk; then
    say "Configuring Docker runtime using nvidia-ctk (edits /etc/docker/daemon.json)…"
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker || true
    ok "Docker configured for NVIDIA runtime."
  else
    warn "nvidia-ctk not found (toolkit install may be incomplete)."
    return 1
  fi
}

post_reboot_message() {
  echo
  echo "========================================================="
  echo "Next step: REBOOT the Proxmox host."
  echo "After reboot, run:"
  echo "  nvidia-smi"
  echo "If you enabled Docker GPU, test:"
  echo "  docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi"
  echo "========================================================="
  echo
}

main() {
  need_root
  detect_env
  check_gpu_present
  check_vfio_binding

  if driver_status; then
    echo
    if pause_confirm "Install/Configure NVIDIA Container Toolkit for Docker GPU? [y/N] "; then
      install_container_toolkit || true
    fi
    exit 0
  fi

  echo
  say "This script will:"
  echo "  1) Enable Debian contrib/non-free components (needed for nvidia-driver)"
  echo "  2) Install headers + dkms + build tools"
  echo "  3) Install nvidia-driver via APT"
  echo "  4) (Optional) Install NVIDIA Container Toolkit for Docker"
  echo
  pause_confirm "Proceed? [y/N] " || exit 0

  enable_nonfree_components_deb822
  enable_nonfree_components_legacy

  install_prereqs
  install_nvidia_driver_apt

  echo
  if pause_confirm "Also set up Docker GPU support (nvidia-container-toolkit)? [y/N] "; then
    install_container_toolkit || true
  fi

  post_reboot_message
}

main "$@"