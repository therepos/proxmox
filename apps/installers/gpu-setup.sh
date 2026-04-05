#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/gpu-setup.sh?$(date +%s))"
# Purpose: GPU passthrough (host) + NVIDIA driver install (VM) — combined
# =============================================================================
# Usage (auto-detects Proxmox host vs VM):
#
# Host commands (Proxmox only):
#   gpu-setup                            Interactive menu
#   gpu-setup status                     Show current GPU passthrough state
#   gpu-setup enable                     Configure host for passthrough (may need reboot)
#   gpu-setup bind                       Assign GPU to a VM (interactive selection)
#   gpu-setup bind 200                   Assign GPU to VM 200
#   gpu-setup bind free                  Unbind GPU from all VMs
#   gpu-setup revert                     Undo all changes
#   gpu-setup snapshot                   Save diagnostics to /root/
#
# VM commands (Ubuntu VM only):
#   gpu-setup driver                     Install NVIDIA driver + container toolkit
#   gpu-setup driver --uninstall         Remove NVIDIA driver + container toolkit
#
# Non-interactive (for Webmin custom commands):
#   bash -c "$(wget -qLO- ...)" -- bind 200 -y
#   bash -c "$(wget -qLO- ...)" -- bind free -y
#   bash -c "$(wget -qLO- ...)" -- driver
#   bash -c "$(wget -qLO- ...)" -- driver --uninstall
# =============================================================================

set -euo pipefail

# Environment detection
is_proxmox_host() {
  [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null
}

# Self-install (host only — VMs just run directly)
INSTALL_PATH="/usr/local/bin/gpu-setup.sh"
FUNC_LINE='gpu-setup() { /usr/local/bin/gpu-setup.sh "$@"; }'

if is_proxmox_host; then
  if [[ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]] && [[ "${BASH_SOURCE[0]:-}" != "$INSTALL_PATH" ]]; then
    SCRIPT_URL="https://github.com/therepos/proxmox/raw/main/apps/tools/gpu-setup.sh"
    echo "[info] Installing gpu-setup.sh to $INSTALL_PATH..."
    wget -qO "$INSTALL_PATH" "${SCRIPT_URL}?$(date +%s)" || { echo "[err] Download failed." >&2; exit 1; }
    chmod +x "$INSTALL_PATH"
    echo "[ok] Installed to $INSTALL_PATH"

    # Add gpu-setup function to bashrc if not present
    if ! grep -qF 'gpu-setup()' ~/.bashrc 2>/dev/null; then
      echo "$FUNC_LINE" >> ~/.bashrc
      echo "[ok] Added gpu-setup function to ~/.bashrc"
    fi

    # Remove old gpu-passthrough function if present
    if grep -qF 'gpu-passthrough()' ~/.bashrc 2>/dev/null; then
      sed -i '/gpu-passthrough()/d' ~/.bashrc
      rm -f /usr/local/bin/gpu-passthrough.sh 2>/dev/null || true
      echo "[ok] Cleaned up old gpu-passthrough references"
    fi

    echo "[ok] Done! Run: gpu-setup"
    echo "  Host: gpu-setup status|enable|bind|revert|snapshot"
    echo "  VM:   gpu-setup driver"
    echo "  Starting now..."
    echo
    exec "$INSTALL_PATH" "$@"
  fi
fi

# Version
SCRIPT_VERSION="2.0.0"

# UI
# Detect non-interactive mode early (full arg parsing happens in main)
NONINTERACTIVE="${NONINTERACTIVE:-0}"
for _arg in "$@"; do [[ "$_arg" == "-y" || "$_arg" == "--yes" ]] && NONINTERACTIVE=1; done

if [[ "$NONINTERACTIVE" == "1" ]] || [[ ! -t 1 ]]; then
  say()  { echo "[ok] $*"; }
  warn() { echo "[warn] $*" >&2; }
  err()  { echo "[err] $*" >&2; }
  info() { echo "[info] $*"; }
else
  say()  { echo -e "\033[1;32m[ok]\033[0m $*"; }
  warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
  err()  { echo -e "\033[1;31m[err]\033[0m $*" >&2; }
  info() { echo -e "\033[1;36m[info]\033[0m $*"; }
fi
die()  { err "$*"; exit 1; }

prompt_yn() {
  local q="$1" default="${2:-n}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    info "(auto-yes) $q"
    return 0
  fi
  local hint="[y/N]"
  [[ "${default,,}" == "y" ]] && hint="[Y/n]"
  read -r -p "$q $hint: " ans
  ans="${ans:-$default}"
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

run_qm() {
  # Never suppress errors.
  local rc=0
  qm "$@" || rc=$?
  if [[ $rc -ne 0 ]]; then
    err "Command failed (exit $rc): qm $*"
    exit 1
  fi
}

# Pre-Requisites
[[ $EUID -eq 0 ]] || die "Run as root (use: sudo $0)"

apt_install_if_missing() {
  local bin="$1" pkg="$2"
  if has_cmd "$bin"; then return 0; fi
  warn "Missing '$bin'. Installing: $pkg"
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get update -y >/dev/null 2>&1; then
    die "apt-get update failed. Check network connectivity."
  fi
  if ! apt-get install -y "$pkg" >/dev/null 2>&1; then
    die "Failed to install $pkg."
  fi
  has_cmd "$bin" || die "Installed $pkg but '$bin' is still missing."
  say "Installed $pkg"
}

# Host-only prereqs
if is_proxmox_host; then
  apt_install_if_missing lspci pciutils
  apt_install_if_missing update-initramfs initramfs-tools

# Hard requirements on Proxmox host
  for c in qm awk grep sed tee find date lsmod lscpu cat sort paste tail tr cut readlink; do
    has_cmd "$c" || die "Missing required command '$c'. This does not look like a standard Proxmox host."
  done

  # Boot refresh tooling
  if [[ -f /etc/kernel/cmdline ]]; then
    has_cmd proxmox-boot-tool || die "Missing 'proxmox-boot-tool' but systemd-boot detected."
  else
    has_cmd update-grub || warn "GRUB detected but 'update-grub' missing; IOMMU enable/revert may fail."
  fi
fi

# Constants/State
STATE_DIR="/var/lib/gpu-setup"
STATE_FILE="$STATE_DIR/state.env"
TS="$(date +%Y%m%d-%H%M%S)"
if is_proxmox_host; then
  mkdir -p "$STATE_DIR"
  # Migrate old gpu-passthrough state if present
  if [[ -f /var/lib/gpu-passthrough/state.env ]] && [[ ! -f "$STATE_FILE" ]]; then
    cp /var/lib/gpu-passthrough/state.env "$STATE_FILE"
    echo "[info] Migrated state from /var/lib/gpu-passthrough/"
  fi
fi

# Script-owned modprobe files (do not touch user generic vfio.conf etc.)
MODPROBE_VFIO="/etc/modprobe.d/gpu-setup-vfio.conf"
MODPROBE_BL_NOUVEAU="/etc/modprobe.d/gpu-setup-blacklist-nouveau.conf"
MODPROBE_BL_NVIDIA="/etc/modprobe.d/gpu-setup-blacklist-nvidia.conf"

# State helpers
load_state() {
  # Reset all state vars to empty before sourcing to prevent stale data
  STATE_VERSION=""
  STATE_CREATED_AT=""
  BOOT_METHOD=""
  IOMMU_FLAGS_ADDED=""
  VFIO_MODULE_LINES_ADDED=""
  GPU_PCI_FUNCS=""
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

write_state() {
  cat >"$STATE_FILE" <<EOF
# gpu-setup state (auto-generated). Remove only via: gpu-setup revert
STATE_VERSION="1"
STATE_CREATED_AT="${STATE_CREATED_AT:-$TS}"

BOOT_METHOD="${BOOT_METHOD:-}"                 # systemd-boot | grub
IOMMU_FLAGS_ADDED="${IOMMU_FLAGS_ADDED:-}"     # exact tokens added by script
VFIO_MODULE_LINES_ADDED="${VFIO_MODULE_LINES_ADDED:-}"  # exact lines added to /etc/modules
GPU_PCI_FUNCS="${GPU_PCI_FUNCS:-}"             # space-separated, e.g. "0000:01:00.0 0000:01:00.1"
EOF
}

ensure_state() {
  load_state
  [[ -f "$STATE_FILE" ]] || { STATE_CREATED_AT="$TS"; write_state; }
}

# Detection helpers
boot_method_detect() {
  if [[ -f /etc/kernel/cmdline ]]; then echo "systemd-boot"; else echo "grub"; fi
}

cpu_vendor() {
  lscpu 2>/dev/null | awk -F: '/Vendor ID:/ {gsub(/^[ \t]+/,"",$2); print $2; exit}'
}

iommu_flag_tokens_for_cpu() {
  local v; v="$(cpu_vendor || true)"
  case "$v" in
    GenuineIntel) echo "intel_iommu=on iommu=pt" ;;
    AuthenticAMD) echo "amd_iommu=on iommu=pt" ;;
    *) echo "" ;;
  esac
}

# FIX: original find returned 0 even with no symlinks; now checks output exists
iommu_active() {
  [[ -d /sys/kernel/iommu_groups ]] && \
    [[ -n "$(find /sys/kernel/iommu_groups -type l -maxdepth 3 2>/dev/null | head -1)" ]]
}

# Correct for lspci -Dn numeric output
detect_nvidia_gpu_addrs() {
  lspci -Dn | awk '($2 ~ /^0300:/ || $2 ~ /^0302:/) && $3 ~ /^10de:/ {print $1}'
}

choose_gpu() {
  mapfile -t GPUS < <(detect_nvidia_gpu_addrs)
  [[ ${#GPUS[@]} -gt 0 ]] || die "No NVIDIA GPU found on this host."
  if [[ ${#GPUS[@]} -eq 1 ]] || [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$NONINTERACTIVE" == "1" ]] && [[ ${#GPUS[@]} -gt 1 ]] && info "(auto) Selecting first GPU: ${GPUS[0]}"
    echo "${GPUS[0]}"
    return
  fi

  echo >&2
  echo "Detected NVIDIA GPU(s):" >&2
  local i=1 g
  for g in "${GPUS[@]}"; do
    echo "  [$i] ${g#0000:} ($(lspci -s "${g#0000:}" | sed -E 's/^[0-9a-fA-F:.]+ //'))" >&2
    i=$((i+1))
  done

  while true; do
    read -r -p "Choose GPU number [1-${#GPUS[@]}] (default 1): " pick
    pick="${pick:-1}"
    [[ "$pick" =~ ^[0-9]+$ ]] || { warn "Enter a number."; continue; }
    (( pick >= 1 && pick <= ${#GPUS[@]} )) || { warn "Out of range."; continue; }
    echo "${GPUS[$((pick-1))]}"
    return
  done
}

gpu_model_for_addr() {
  local addr="$1"
  lspci -s "${addr#0000:}" 2>/dev/null | sed -E 's/^[0-9a-fA-F:.]+ //'
}

sibling_functions() {
  local addr="$1"
  local prefix="${addr%.*}"
  lspci -Dn | awk -v pfx="$prefix" '$1 ~ ("^" pfx "\\.") {print $1}' | sort
}

driver_in_use() {
  local addr="$1"
  lspci -s "${addr#0000:}" -k 2>/dev/null | awk -F': ' '/Kernel driver in use:/ {print $2; exit}'
}

# FIX: tighter regex — original had operator precedence bug matching partial names
host_has_nvidia_modules_loaded() {
  lsmod | grep -Eq '^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm|nouveau) '
}

list_vms() {
  qm list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n
}

vm_running() {
  local vmid="$1"
  qm status "$vmid" 2>/dev/null | grep -q 'status: running'
}

vm_exists() {
  local vmid="$1"
  qm status "$vmid" >/dev/null 2>&1
}

find_vm_assignments_for_addr() {
  local addr="$1"
  local short="${addr#0000:}"
  local vmid
  for vmid in $(list_vms); do
    qm config "$vmid" 2>/dev/null | awk -v vm="$vmid" -v a="$addr" -v s="$short" '
      $1 ~ /^hostpci[0-9]+:/ { if (index($0,a) || index($0,s)) print vm " " $0 }'
  done
}

# IOMMU group isolation check
check_iommu_group_isolation() {
  local addr="$1"
  local group_link="/sys/bus/pci/devices/${addr}/iommu_group"

  if [[ ! -L "$group_link" ]]; then
    warn "Could not determine IOMMU group for $addr (no symlink)."
    return 0  # non-fatal: might not be booted with IOMMU yet
  fi

  local group_path
  group_path="$(readlink -f "$group_link")"
  local group_num
  group_num="$(basename "$group_path")"

  local non_gpu=()
  local dev
  for dev in "$group_path"/devices/*; do
    dev="$(basename "$dev")"
    local class
    class="$(cat /sys/bus/pci/devices/"$dev"/class 2>/dev/null || echo "0x000000")"
    # 0x0604xx = PCI bridge — safe to share
    [[ "$class" == 0x0604* ]] && continue
    # Check if it's one of the GPU sibling functions
    local prefix="${addr%.*}"
    if [[ "$dev" == "${prefix}."* ]]; then continue; fi
    non_gpu+=("$dev")
  done

  if [[ ${#non_gpu[@]} -gt 0 ]]; then
    echo
    warn "IOMMU group $group_num contains non-GPU devices alongside your GPU:"
    local d
    for d in "${non_gpu[@]}"; do
      echo "  - $d ($(lspci -s "${d#0000:}" 2>/dev/null | sed -E 's/^[0-9a-fA-F:.]+ //' || echo unknown))"
    done
    warn "Passthrough may not work, or may require ACS override patch."
    warn "If your VM fails to start, this is the most likely cause."
    echo
    if ! prompt_yn "Continue anyway?"; then
      die "Aborted due to IOMMU group isolation concern."
    fi
  else
    say "IOMMU group $group_num is clean (GPU functions + bridges only)."
  fi
}

# File helpers
write_file_atomic() {
  local path="$1" tmp="${path}.tmp.$$"
  cat >"$tmp"
  mv "$tmp" "$path"
}

remove_exact_line_from_file() {
  local file="$1" line="$2"
  [[ -f "$file" ]] || return 0
  grep -qxF "$line" "$file" || return 0
  awk -v l="$line" '$0 != l' "$file" > "${file}.tmp.$$" && mv "${file}.tmp.$$" "$file"
}

# IOMMU kernel flags (tracked)
cmdline_has_token() {
  local text="$1" token="$2"
  [[ " $text " == *" $token "* ]]
}

enable_iommu_kernel_flags_if_missing() {
  local tokens; tokens="$(iommu_flag_tokens_for_cpu)"
  [[ -n "$tokens" ]] || die "Unsupported CPU vendor; cannot determine IOMMU flags."

  local method; method="$(boot_method_detect)"
  BOOT_METHOD="$method"

  local changed=0
  local added_tokens=()

  if [[ "$method" == "systemd-boot" ]]; then
    local f="/etc/kernel/cmdline"
    [[ -f "$f" ]] || die "systemd-boot detected but /etc/kernel/cmdline not found."
    local cur; cur="$(cat "$f")"
    local t
    for t in $tokens; do
      if ! cmdline_has_token "$cur" "$t"; then
        cur="${cur} ${t}"
        added_tokens+=("$t")
        changed=1
      fi
    done
    if [[ $changed -eq 1 ]]; then
      write_file_atomic "$f" <<<"$(echo "$cur" | tr -s ' ' | sed 's/^ //;s/ $//')"
      proxmox-boot-tool refresh
      IOMMU_FLAGS_ADDED="${added_tokens[*]}"
      write_state
      say "Enabled IOMMU kernel flags: ${IOMMU_FLAGS_ADDED}"
    fi
  else
    local f="/etc/default/grub"
    [[ -f "$f" ]] || die "GRUB config not found at /etc/default/grub"

    local var line cur_val new_val
    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
      var="GRUB_CMDLINE_LINUX_DEFAULT"
      line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f")"
    else
      var="GRUB_CMDLINE_LINUX"
      line="$(grep -E '^GRUB_CMDLINE_LINUX=' "$f" || true)"
      [[ -n "$line" ]] || die "No GRUB_CMDLINE_LINUX* line found."
    fi

    cur_val="$(echo "$line" | sed -E 's/^[A-Z0-9_]+=//;s/^"//;s/"$//')"
    new_val="$cur_val"
    local t
    for t in $tokens; do
      if ! cmdline_has_token "$new_val" "$t"; then
        new_val="${new_val} ${t}"
        added_tokens+=("$t")
        changed=1
      fi
    done

    if [[ $changed -eq 1 ]]; then
      new_val="$(echo "$new_val" | tr -s ' ' | sed 's/^ //;s/ $//')"
      sed -i -E "s|^${var}=\".*\"|${var}=\"${new_val//|/\\|}\"|" "$f"
      update-grub || true
      IOMMU_FLAGS_ADDED="${added_tokens[*]}"
      write_state
      say "Enabled IOMMU kernel flags: ${IOMMU_FLAGS_ADDED}"
    fi
  fi

  echo "$changed"
}

remove_iommu_kernel_flags_we_added() {
  ensure_state
  load_state
  [[ -n "${IOMMU_FLAGS_ADDED:-}" ]] || { echo 0; return; }

  local method="${BOOT_METHOD:-}"
  [[ -n "$method" ]] || method="$(boot_method_detect)"
  local tokens="$IOMMU_FLAGS_ADDED"

  if [[ "$method" == "systemd-boot" ]]; then
    local f="/etc/kernel/cmdline"
    local cur; cur="$(cat "$f")"
    local t
    for t in $tokens; do
      cur="$(echo " $cur " | sed -E "s/[[:space:]]${t}[[:space:]]/ /g" | sed 's/^ //;s/ $//')"
    done
    cur="$(echo "$cur" | tr -s ' ')"
    write_file_atomic "$f" <<<"$cur"
    proxmox-boot-tool refresh
  else
    local f="/etc/default/grub"
    local var line cur_val new_val
    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
      var="GRUB_CMDLINE_LINUX_DEFAULT"
      line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f")"
    else
      var="GRUB_CMDLINE_LINUX"
      line="$(grep -E '^GRUB_CMDLINE_LINUX=' "$f" || true)"
      [[ -n "$line" ]] || die "No GRUB_CMDLINE_LINUX* line found."
    fi
    cur_val="$(echo "$line" | sed -E 's/^[A-Z0-9_]+=//;s/^"//;s/"$//')"
    new_val="$cur_val"
    local t
    for t in $tokens; do
      new_val="$(echo " $new_val " | sed -E "s/[[:space:]]${t}[[:space:]]/ /g" | sed 's/^ //;s/ $//')"
    done
    new_val="$(echo "$new_val" | tr -s ' ' | sed 's/^ //;s/ $//')"
    sed -i -E "s|^${var}=\".*\"|${var}=\"${new_val//|/\\|}\"|" "$f"
    update-grub || true
  fi

  IOMMU_FLAGS_ADDED=""
  BOOT_METHOD="$method"
  write_state
  echo 1
}

# VFIO host config (tracked)
compute_ids_csv_for_funcs() {
  local funcs=("$@")
  local ids
  ids="$(
    for f in "${funcs[@]}"; do
      lspci -Dnns "${f#0000:}" | awk -F'[][]' '{print $3}'
    done | sort -u | paste -sd, -
  )"
  [[ -n "$ids" ]] || die "Could not compute PCI IDs for GPU functions: ${funcs[*]}"
  echo "$ids"
}

ensure_vfio_modules_boot() {
  ensure_state
  load_state
  local f="/etc/modules"
  touch "$f"

  # FIX: vfio_virqfd was merged into vfio in kernel 5.16+; only add if it exists as a module
  local required_modules=(vfio vfio_pci vfio_iommu_type1)
  if modinfo vfio_virqfd &>/dev/null; then
    required_modules+=(vfio_virqfd)
  fi

  local added=()
  local m
  for m in "${required_modules[@]}"; do
    if ! grep -qxF "$m" "$f" 2>/dev/null; then
      echo "$m" >> "$f"
      added+=("$m")
    fi
  done

  if [[ ${#added[@]} -gt 0 ]]; then
    VFIO_MODULE_LINES_ADDED="${added[*]}"
    write_state
    echo 1
  else
    echo 0
  fi
}

write_vfio_and_blacklist_files() {
  local funcs=("$@")
  local ids_csv; ids_csv="$(compute_ids_csv_for_funcs "${funcs[@]}")"

  write_file_atomic "$MODPROBE_VFIO" <<EOF
# managed by gpu-setup — do not edit manually
options vfio-pci ids=${ids_csv} disable_vga=1
EOF

  write_file_atomic "$MODPROBE_BL_NOUVEAU" <<'EOF'
# managed by gpu-setup — do not edit manually
blacklist nouveau
options nouveau modeset=0
EOF

  write_file_atomic "$MODPROBE_BL_NVIDIA" <<'EOF'
# managed by gpu-setup — do not edit manually
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF

  say "VFIO binding: ids=${ids_csv}"
  say "Blacklisted: nvidia, nvidia_drm, nvidia_modeset, nvidia_uvm, nouveau"
}

remove_vfio_and_blacklist_files() {
  rm -f "$MODPROBE_VFIO" "$MODPROBE_BL_NOUVEAU" "$MODPROBE_BL_NVIDIA" || true
  # Clean up old gpu-passthrough file names if present
  rm -f /etc/modprobe.d/gpu-passthrough-vfio.conf \
        /etc/modprobe.d/gpu-passthrough-blacklist-nouveau.conf \
        /etc/modprobe.d/gpu-passthrough-blacklist-nvidia.conf 2>/dev/null || true
}

remove_vfio_module_lines_we_added() {
  ensure_state
  load_state
  [[ -n "${VFIO_MODULE_LINES_ADDED:-}" ]] || { echo 0; return; }
  local f="/etc/modules"
  local m
  for m in $VFIO_MODULE_LINES_ADDED; do
    remove_exact_line_from_file "$f" "$m"
  done
  VFIO_MODULE_LINES_ADDED=""
  write_state
  echo 1
}

# VM menu
prompt_vmid_menu() {
  local q="$1"
  mapfile -t MENU < <(qm list 2>/dev/null | tail -n +2 | while read -r vmid name status _; do
    [[ -n "$vmid" ]] && echo "$vmid|$name|$status"
  done)

  # FIX: filter out any empty entries from mapfile
  local clean=()
  local entry
  for entry in "${MENU[@]}"; do
    [[ -n "$entry" ]] && clean+=("$entry")
  done
  MENU=("${clean[@]+"${clean[@]}"}")

  echo >&2
  echo "$q" >&2

  if [[ ${#MENU[@]} -eq 0 ]]; then
    warn "No VMs found. Create a VM in Proxmox first."
    echo "__EXIT__"
    return
  fi

  # Single VM: explicit prompt
  if [[ ${#MENU[@]} -eq 1 ]]; then
    local vmid name status rest
    vmid="${MENU[0]%%|*}"
    rest="${MENU[0]#*|}"
    name="${rest%%|*}"
    status="${rest#*|}"
    echo "Only one VM detected: $vmid ($name) [$status]" >&2
    echo >&2
    echo "0) Do nothing (exit)" >&2
    echo "F) Free/Unbind GPU from any VM" >&2
    echo "1) Assign GPU to VM $vmid ($name)" >&2
    while true; do
      read -r -p "Choice (0, F, or 1): " pick
      pick="${pick:-0}"
      case "${pick^^}" in
        0) echo "__EXIT__"; return ;;
        F) echo "__FREE__"; return ;;
        1) echo "$vmid"; return ;;
        *) warn "Enter 0, F, or 1." ;;
      esac
    done
  fi

  echo "Select an option:" >&2
  echo "  0) Do nothing (exit)" >&2
  echo "  F) Free/Unbind GPU from any VM" >&2
  echo >&2
  echo "Or select a VM:" >&2
  echo "  #  VMID   Status    Name" >&2
  echo "  -- -----  --------  -------------------------" >&2

  local i=1 row vmid name status rest
  for row in "${MENU[@]}"; do
    vmid="${row%%|*}"
    rest="${row#*|}"
    name="${rest%%|*}"
    status="${rest#*|}"
    printf "  %-2s %-5s  %-8s  %s\n" "$i" "$vmid" "$status" "$name" >&2
    i=$((i+1))
  done

  while true; do
    read -r -p "Choice (0, F, or 1-${#MENU[@]}): " pick
    pick="${pick:-0}"
    case "${pick^^}" in
      0) echo "__EXIT__"; return ;;
      F) echo "__FREE__"; return ;;
    esac
    [[ "$pick" =~ ^[0-9]+$ ]] || { warn "Enter 0, F, or a number."; continue; }
    (( pick >= 1 && pick <= ${#MENU[@]} )) || { warn "Out of range."; continue; }
    vmid="${MENU[$((pick-1))]%%|*}"
    echo "$vmid"
    return
  done
}

# VM bind/switch helpers
remove_from_vm_if_present() {
  local vmid="$1"; shift
  local addr
  for addr in "$@"; do
    while read -r _ rest; do
      [[ -n "$rest" ]] || continue
      local key
      key="$(echo "$rest" | awk -F: '{print $1}')"
      [[ -n "$key" ]] || continue
      warn "Removing $key from VM $vmid"
      run_qm set "$vmid" --delete "$key"
    done < <(qm config "$vmid" 2>/dev/null | awk -v a="$addr" -v s="${addr#0000:}" '
      $1 ~ /^hostpci[0-9]+:/ && (index($0,a) || index($0,s)) {print "X " $0}')
  done
}

add_funcs_to_vm() {
  local vmid="$1"; shift
  local funcs=("$@")

  local used
  used="$(qm config "$vmid" 2>/dev/null | awk -F: '/^hostpci[0-9]+:/{gsub("hostpci","",$1); print $1}' | sort -n | paste -sd, -)"
  local slots=() i
  for i in $(seq 0 9); do
    if ! echo ",$used," | grep -q ",$i,"; then slots+=("$i"); fi
  done

  local idx=0 f short
  for f in "${funcs[@]}"; do
    [[ ${#slots[@]} -gt $idx ]] || die "No free hostpci slots on VM $vmid (all 10 used)."
    short="${f#0000:}"
    info "Adding $short to VM $vmid as hostpci${slots[$idx]}"
    run_qm set "$vmid" --"hostpci${slots[$idx]}" "${short},pcie=1"
    idx=$((idx+1))
  done
}


# VM stop/start helpers
stop_vm_with_wait() {
  local vmid="$1"
  local interval=3

  if ! vm_running "$vmid"; then
    say "VM $vmid is already stopped."
    return 0
  fi

  # Check if guest agent is available — if not, skip straight to qm stop
  local has_agent=0
  if qm config "$vmid" 2>/dev/null | grep -qE '^agent:.*1'; then
    # Agent is configured; try graceful shutdown
    info "Sending graceful shutdown to VM $vmid..."
    if qm shutdown "$vmid" 2>/dev/null; then
      has_agent=1
      local waited=0
      while vm_running "$vmid" && (( waited < 30 )); do
        printf "."
        sleep "$interval"
        waited=$((waited + interval))
      done
      echo
    fi
  fi

  # If no agent, or graceful shutdown didn't work, use qm stop
  if vm_running "$vmid"; then
    if [[ $has_agent -eq 0 ]]; then
      info "No guest agent detected. Stopping VM $vmid directly..."
    else
      warn "Graceful shutdown timed out. Stopping VM $vmid..."
    fi
    qm stop "$vmid" 2>&1 || true

    local waited=0
    while vm_running "$vmid" && (( waited < 30 )); do
      printf "."
      sleep "$interval"
      waited=$((waited + interval))
    done
    echo
  fi

  # Last resort: force stop
  if vm_running "$vmid"; then
    warn "VM $vmid still running. Force-stopping..."
    qm stop "$vmid" --forceStop 1 2>&1 || true
    sleep 5
    if vm_running "$vmid"; then
      err "Could not stop VM $vmid after multiple attempts."
      return 1
    fi
  fi

  say "VM $vmid stopped."
  sleep 2  # brief pause to let resources release
  return 0
}

start_vm_with_wait() {
  local vmid="$1"

  # Safety: if VM is somehow running, stop it first
  if vm_running "$vmid"; then
    warn "VM $vmid is currently running. Stopping it first..."
    stop_vm_with_wait "$vmid" || return 1
  fi

  info "Starting VM $vmid..."
  local start_output
  if ! start_output="$(qm start "$vmid" 2>&1)"; then
    err "Failed to start VM $vmid."
    echo "$start_output" >&2
    echo
    err "Common causes:"
    echo "  • Missing EFI disk (if OVMF was enabled)"
    echo "  • IOMMU group conflict"
    echo "  • GPU not properly bound to vfio-pci (try rebooting host)"
    echo
    info "Run 'gpu-setup snapshot' and check the output for clues."
    return 1
  fi

  # Wait briefly and verify it's actually running
  sleep 3
  if vm_running "$vmid"; then
    say "VM $vmid is running with GPU passthrough!"
  else
    warn "VM $vmid was started but doesn't appear to be running."
    warn "Check the Proxmox UI or run: qm status $vmid"
  fi
}

# Modes
mode_status() {
  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  echo
  echo "═══════════════════════════════════"
  echo " GPU Passthrough Status"
  echo "═══════════════════════════════════"
  echo
  echo "  CPU vendor : $(cpu_vendor || echo unknown)"
  echo "  Boot method: $(boot_method_detect)"
  echo "  IOMMU      : $(iommu_active && echo "ACTIVE [ok]" || echo "NOT ACTIVE [err]")"
  echo "  NVIDIA GPU : ${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"

  local f
  for f in "${FUNCS[@]}"; do
    local drv
    drv="$(driver_in_use "$f" || echo "none")"
    local marker=""
    [[ "$drv" == "vfio-pci" ]] && marker=" (ready for passthrough)"
    echo "    ${f#0000:} → driver: ${drv}${marker}"
  done

  # Show IOMMU group info
  if iommu_active; then
    local group_link="/sys/bus/pci/devices/${gpu}/iommu_group"
    if [[ -L "$group_link" ]]; then
      local gnum
      gnum="$(basename "$(readlink -f "$group_link")")"
      echo "  IOMMU group: $gnum"
    fi
  fi

  echo
  echo "  VM assignments:"
  local any=0 assigns
  for f in "${FUNCS[@]}"; do
    assigns="$(find_vm_assignments_for_addr "$f" || true)"
    if [[ -n "$assigns" ]]; then
      any=1
      echo "$assigns" | awk '{vm=$1; $1=""; sub(/^ /,""); print "    VM " vm ": " $0}'
    fi
  done
  [[ $any -eq 0 ]] && echo "    (not assigned to any VM)"

  # Show state file status
  echo
  if [[ -f "$STATE_FILE" ]]; then
    echo "  State file: $STATE_FILE (gpu-setup has been run before)"
  else
    echo "  State file: none (gpu-setup has not configured anything yet)"
  fi
}

mode_snapshot() {
  local out="/root/gpu-preflight-${TS}.txt"
  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  {
    echo "===== gpu-setup snapshot ====="
    echo "Version: $SCRIPT_VERSION"
    echo
    echo "===== DATE ====="; date
    echo; echo "===== KERNEL ====="; uname -r || true
    echo; echo "===== CPU ====="; lscpu | grep -iE 'Vendor ID|Model name' || true
    echo; echo "===== BOOT METHOD ====="; boot_method_detect
    echo; echo "===== KERNEL CMDLINE ====="; cat /proc/cmdline || true
    echo; echo "===== IOMMU GROUPS ====="
    if [[ -d /sys/kernel/iommu_groups ]]; then
      find /sys/kernel/iommu_groups -type l 2>/dev/null | sort -V || true
    else
      echo "(no IOMMU groups directory — IOMMU likely not active)"
    fi
    echo; echo "===== GPU ====="; echo "${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
    echo; echo "===== GPU FUNCS + DRIVER ====="
    for f in "${FUNCS[@]}"; do echo "${f#0000:} driver: $(driver_in_use "$f" || echo none)"; done
    echo; echo "===== GPU IOMMU GROUP ====="
    local glink="/sys/bus/pci/devices/${gpu}/iommu_group"
    if [[ -L "$glink" ]]; then
      ls "$(readlink -f "$glink")/devices/" 2>/dev/null || true
    else
      echo "(not available)"
    fi
    echo; echo "===== LOADED NVIDIA/VFIO MODULES ====="
    lsmod | grep -iE 'nvidia|nouveau|vfio' || echo "(none loaded)"
    echo; echo "===== SCRIPT MODPROBE FILES ====="
    for f in "$MODPROBE_VFIO" "$MODPROBE_BL_NOUVEAU" "$MODPROBE_BL_NVIDIA"; do
      [[ -f "$f" ]] && { echo "--- $f ---"; cat "$f"; } || echo "(missing) $f"
    done
    echo; echo "===== /etc/modules ====="; cat /etc/modules 2>/dev/null || true
    echo; echo "===== VM hostpci lines ====="
    local found=0
    for vm in $(list_vms); do
      local lines
      lines="$(qm config "$vm" 2>/dev/null | grep -E '^hostpci[0-9]+:' || true)"
      if [[ -n "$lines" ]]; then
        echo "VMID $vm:"
        echo "$lines"
        found=1
      fi
    done
    [[ $found -eq 0 ]] && echo "(no VMs have hostpci entries)"
    echo; echo "===== STATE FILE ====="
    [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "(no state file)"
  } >"$out" 2>&1

  say "Saved snapshot to: $out"
  info "Share this file if you need help troubleshooting."
}

mode_enable() {
  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  echo
  echo "═══════════════════════════════════"
  echo " GPU Passthrough — Enable"
  echo "═══════════════════════════════════"
  echo
  say "NVIDIA GPU: ${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
  info "Functions: ${FUNCS[*]}"

  if host_has_nvidia_modules_loaded; then
    echo
    err "Host currently has NVIDIA or nouveau kernel modules loaded."
    err "This means the host is using the GPU. Passthrough requires the"
    err "host to NOT use the GPU."
    echo
    info "If you just installed Proxmox and haven't installed NVIDIA drivers"
    info "on the host, try rebooting first. If the modules are still loaded"
    info "after reboot, you may need to remove the host NVIDIA driver package."
    die "Cannot proceed while host NVIDIA/nouveau modules are loaded."
  fi

  # Pre-flight summary
  echo
  info "This will make the following changes:"
  echo "  1. Add IOMMU kernel flags (if missing)"
  echo "  2. Add VFIO modules to /etc/modules (if missing)"
  echo "  3. Create modprobe configs to bind GPU to vfio-pci"
  echo "  4. Blacklist nvidia/nouveau drivers on host"
  echo "  5. Rebuild initramfs"
  echo
  if ! prompt_yn "Proceed?"; then
    say "No changes made."
    return 0
  fi

  ensure_state; load_state
  GPU_PCI_FUNCS="${FUNCS[*]}"; write_state

  local changes=0

  local flags_changed
  flags_changed="$(enable_iommu_kernel_flags_if_missing)"
  [[ "$flags_changed" == "1" ]] && changes=1

  if ! iommu_active; then
    warn "IOMMU is not active yet."
    if [[ "$flags_changed" == "1" ]]; then
      warn "Reboot required to activate IOMMU after adding kernel flags."
      echo
      info "After reboot, run: gpu-setup enable"
      exit 0
    fi
    echo
    err "IOMMU is not active and no kernel flags were missing."
    err "This usually means VT-d (Intel) or AMD-Vi is disabled in BIOS."
    echo
    info "Steps to fix:"
    info "  1. Reboot into BIOS/UEFI setup"
    info "  2. Enable VT-d (Intel) or IOMMU/AMD-Vi (AMD)"
    info "  3. Save and reboot"
    info "  4. Run: gpu-setup enable"
    die "IOMMU is not active."
  fi
  say "IOMMU is active"

  # Check IOMMU group isolation
  check_iommu_group_isolation "$gpu"

  local mod_changed
  mod_changed="$(ensure_vfio_modules_boot)"
  [[ "$mod_changed" == "1" ]] && changes=1

  local wrote=0
  if [[ ! -f "$MODPROBE_VFIO" || ! -f "$MODPROBE_BL_NOUVEAU" || ! -f "$MODPROBE_BL_NVIDIA" ]]; then
    wrote=1
  fi
  write_vfio_and_blacklist_files "${FUNCS[@]}"
  [[ "$wrote" == "1" ]] && changes=1

  update-initramfs -u
  say "initramfs updated"

  echo
  if [[ $changes -eq 1 ]]; then
    warn "═══════════════════════════════════════════"
    warn " REBOOT REQUIRED to complete GPU setup"
    warn "═══════════════════════════════════════════"
    echo
    info "After reboot, run: gpu-setup bind"
  else
    say "Host is already configured for GPU passthrough."
    say "No reboot required. You can run: gpu-setup bind"
  fi
}

mode_bind() {
  local target_vmid="${1:-}"

  if ! iommu_active; then
    die "IOMMU is not active. Run: gpu-setup enable (and reboot if instructed)."
  fi

  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  echo
  echo "═══════════════════════════════════"
  echo " GPU Passthrough — Bind to VM"
  echo "═══════════════════════════════════"
  echo

  # Verify GPU functions are bound to vfio-pci
  local all_vfio=1
  local f
  for f in "${FUNCS[@]}"; do
    local drv
    drv="$(driver_in_use "$f" || echo "none")"
    if [[ "$drv" != "vfio-pci" ]]; then
      all_vfio=0
      warn "${f#0000:} is bound to '$drv' instead of 'vfio-pci'."
    fi
  done
  if [[ $all_vfio -eq 0 ]]; then
    echo
    warn "Not all GPU functions are bound to vfio-pci."
    info "Did you run 'gpu-setup enable' and reboot?"
    info "Try: gpu-setup enable → reboot → gpu-setup bind"
    if ! prompt_yn "Continue anyway (advanced users only)?"; then
      die "Aborted. Run 'gpu-setup enable' first."
    fi
  else
    say "All GPU functions bound to vfio-pci."
  fi

  # FIX: filter empty entries from REF_VMS
  local raw_vms=()
  mapfile -t raw_vms < <(
    for f in "${FUNCS[@]}"; do
      find_vm_assignments_for_addr "$f" | awk '{print $1}'
    done | sort -u
  )
  local REF_VMS=()
  local v
  for v in "${raw_vms[@]}"; do
    [[ -n "$v" ]] && REF_VMS+=("$v")
  done

  if [[ ${#REF_VMS[@]} -gt 0 ]]; then
    say "GPU is currently assigned to VM(s): ${REF_VMS[*]}"
  else
    info "GPU is not currently assigned to any VM."
  fi

  local target
  if [[ -n "$target_vmid" ]]; then
    # Non-interactive: VMID passed as argument
    if [[ "$target_vmid" == "free" || "$target_vmid" == "FREE" ]]; then
      target="__FREE__"
    else
      vm_exists "$target_vmid" || die "VM $target_vmid does not exist."
      target="$target_vmid"
    fi
    info "Target: ${target//__FREE__/Free GPU (unbind)}"
  else
    target="$(prompt_vmid_menu "What do you want to do with the GPU?")"
  fi

  if [[ "$target" == "__EXIT__" ]]; then
    say "No changes made."
    return 0
  fi

  # Collect all VMs that need to be stopped before we can proceed
  local vms_to_stop=()
  local vms_were_running=()  # track which VMs to restart after changes
  local vmid

  # Running VMs that currently reference the GPU
  for vmid in "${REF_VMS[@]}"; do
    vm_running "$vmid" && vms_to_stop+=("$vmid")
  done

  # Target VM (if assigning, not freeing) may also be running
  if [[ "$target" != "__FREE__" ]] && [[ "$target" != "__EXIT__" ]]; then
    if vm_running "$target"; then
      # Avoid duplicates
      local already=0
      for vmid in "${vms_to_stop[@]+"${vms_to_stop[@]}"}"; do
        [[ "$vmid" == "$target" ]] && already=1
      done
      [[ $already -eq 0 ]] && vms_to_stop+=("$target")
    fi
  fi

  # If any VMs need stopping, offer to do it
  if [[ ${#vms_to_stop[@]} -gt 0 ]]; then
    echo
    warn "The following VM(s) must be stopped first: ${vms_to_stop[*]}"
    info "PCI passthrough changes require a full VM stop+start (a guest reboot won't work)."
    info "VMs will be automatically restarted after changes are applied."
    echo
    if prompt_yn "Stop VM(s) ${vms_to_stop[*]}, apply changes, and restart?"; then
      for vmid in "${vms_to_stop[@]}"; do
        stop_vm_with_wait "$vmid" || die "Could not stop VM $vmid. Please stop it manually and try again."
        vms_were_running+=("$vmid")
      done
    else
      die "Cannot proceed while VM(s) are running. Stop them manually and try again."
    fi
  fi

  # ---- FREE path ----
  if [[ "$target" == "__FREE__" ]]; then
    if [[ ${#REF_VMS[@]} -eq 0 ]]; then
      say "GPU is already free (not assigned to any VM)."
      return 0
    fi
    for vmid in "${REF_VMS[@]}"; do
      remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
    done
    say "GPU freed (no VM references remain)."

    # Restart VMs that were running (they'll now run without the GPU)
    if [[ ${#vms_were_running[@]} -gt 0 ]]; then
      echo
      info "Restarting VM(s) that were running before (now without GPU)..."
      for vmid in "${vms_were_running[@]}"; do
        start_vm_with_wait "$vmid" || warn "Could not restart VM $vmid. Start it manually: qm start $vmid"
      done
    fi
    return 0
  fi

  # ---- ASSIGN path ----

  # Switch: remove from other VMs, then add to target
  for vmid in "${REF_VMS[@]}"; do
    [[ "$vmid" == "$target" ]] && continue
    remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
  done
  # Avoid duplicates in target
  remove_from_vm_if_present "$target" "${FUNCS[@]}" || true
  add_funcs_to_vm "$target" "${FUNCS[@]}"

  echo
  say "═══════════════════════════════════════"
  say " GPU bound to VM $target successfully!"
  say "═══════════════════════════════════════"
  echo

  # Restart VMs that were running
  # Target VM always gets restarted (it now has the GPU)
  # Other VMs that were running get restarted too (without GPU)

  # Start target VM
  local target_was_running=0
  for vmid in "${vms_were_running[@]+"${vms_were_running[@]}"}"; do
    [[ "$vmid" == "$target" ]] && target_was_running=1
  done

  if [[ $target_was_running -eq 1 ]]; then
    info "Restarting VM $target with GPU passthrough..."
    start_vm_with_wait "$target" || warn "Could not start VM $target. Start it manually: qm start $target"
  else
    info "GPU passthrough requires starting the VM from Proxmox (not from inside the guest)."
    echo
    if prompt_yn "Start VM $target now?"; then
      start_vm_with_wait "$target"
    else
      echo
      info "When you're ready, start the VM with:"
      echo "  qm start $target"
      echo "  (or use the Proxmox web UI)"
    fi
  fi

  # Restart other VMs that were running (without GPU)
  for vmid in "${vms_were_running[@]+"${vms_were_running[@]}"}"; do
    [[ "$vmid" == "$target" ]] && continue
    echo
    info "Restarting VM $vmid (without GPU)..."
    start_vm_with_wait "$vmid" || warn "Could not restart VM $vmid. Start it manually: qm start $vmid"
  done

  echo
  info "Once the VM is running, install NVIDIA drivers inside the VM."
}

mode_revert() {
  ensure_state
  load_state

  echo
  echo "═══════════════════════════════════"
  echo " GPU Passthrough — Revert"
  echo "═══════════════════════════════════"
  echo
  warn "This will undo ONLY what gpu-setup added:"
  echo "  • Remove script VFIO binding + blacklists"
  echo "  • Remove VFIO boot module lines that gpu-setup added"
  echo "  • Remove IOMMU kernel flags that gpu-setup added (if any)"
  echo "  • Rebuild initramfs"
  echo

  if ! prompt_yn "Proceed with revert?"; then
    say "No changes made."
    return 0
  fi

  # Optional: remove GPU from VMs
  if prompt_yn "Also remove GPU from all VMs (hostpci entries)?"; then
    local gpu; gpu="$(choose_gpu)"
    mapfile -t FUNCS < <(sibling_functions "$gpu")

    # FIX: filter empties
    local raw_vms=()
    mapfile -t raw_vms < <(
      for f in "${FUNCS[@]}"; do
        find_vm_assignments_for_addr "$f" | awk '{print $1}'
      done | sort -u
    )
    local REF_VMS=()
    local v
    for v in "${raw_vms[@]}"; do
      [[ -n "$v" ]] && REF_VMS+=("$v")
    done

    local vmid
    local vms_to_stop=()
    for vmid in "${REF_VMS[@]}"; do
      vm_running "$vmid" && vms_to_stop+=("$vmid")
    done
    if [[ ${#vms_to_stop[@]} -gt 0 ]]; then
      warn "Running VM(s) reference the GPU: ${vms_to_stop[*]}"
      if prompt_yn "Stop them now to proceed?"; then
        for vmid in "${vms_to_stop[@]}"; do
          stop_vm_with_wait "$vmid" || die "Could not stop VM $vmid. Stop it manually and try again."
        done
      else
        die "Cannot remove GPU from running VMs. Stop them manually and try again."
      fi
    fi
    for vmid in "${REF_VMS[@]}"; do
      remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
    done
    [[ ${#REF_VMS[@]} -gt 0 ]] && say "GPU removed from VMs."
  fi

  remove_vfio_and_blacklist_files
  say "Removed script VFIO binding + blacklists"

  remove_vfio_module_lines_we_added >/dev/null || true
  remove_iommu_kernel_flags_we_added >/dev/null || true

  update-initramfs -u
  say "initramfs updated"

  echo
  warn "═══════════════════════════════════════════"
  warn " REBOOT RECOMMENDED"
  warn "═══════════════════════════════════════════"
  info "Reboot to fully return to default host behavior."

  # Clear state dir if nothing left to track
  load_state
  if [[ -z "${IOMMU_FLAGS_ADDED:-}" && -z "${VFIO_MODULE_LINES_ADDED:-}" ]]; then
    rm -f "$STATE_FILE" || true
    rmdir "$STATE_DIR" 2>/dev/null || true
    say "State cleared."
  else
    warn "State retained (some tracked items remain)."
  fi
}

# Interactive menu
interactive_menu() {
  echo
  echo "═══════════════════════════════════════"
  echo "  gpu-setup v${SCRIPT_VERSION}"
  echo "  NVIDIA GPU Setup"
  echo "═══════════════════════════════════════"

  if is_proxmox_host; then
    echo
    echo "  Detected: Proxmox host"
    while true; do
      echo
      echo "  1) Status    — show current state"
      echo "  2) Enable    — prepare host for passthrough"
      echo "  3) Bind      — assign GPU to a VM"
      echo "  4) Snapshot  — save diagnostics"
      echo "  5) Revert    — undo all changes"
      echo "  0) Exit"
      echo
      read -r -p "Choose [0-5]: " choice
      case "${choice:-}" in
        1) mode_status ;;
        2) mode_enable ;;
        3) mode_bind ;;
        4) mode_snapshot ;;
        5) mode_revert ;;
        0|q|Q|exit) say "Goodbye."; exit 0 ;;
        *) warn "Invalid option. Enter 0-5." ;;
      esac
    done
  else
    echo
    echo "  Detected: VM / guest"
    echo
    echo "  1) Install NVIDIA driver"
    echo "  2) Uninstall NVIDIA driver"
    echo "  0) Exit"
    echo
    read -r -p "Choose [0-2]: " choice
    case "${choice:-}" in
      1) mode_driver_install ;;
      2) mode_driver_uninstall ;;
      0|q|Q|exit) say "Goodbye."; exit 0 ;;
      *) warn "Invalid option."; exit 1 ;;
    esac
  fi
}

# =============================================================================
# Driver functions (run on VM only)
# =============================================================================

require_vm() {
  if is_proxmox_host; then
    echo ""
    err "This command runs inside a VM, not on the Proxmox host."
    echo ""
    echo "  On the Proxmox host, use:"
    echo "    gpu-setup enable    — configure GPU passthrough"
    echo "    gpu-setup bind      — assign GPU to a VM"
    echo ""
    echo "  Then inside the VM, use:"
    echo "    gpu-setup driver    — install NVIDIA driver"
    echo ""
    exit 1
  fi
}

require_host() {
  if ! is_proxmox_host; then
    echo ""
    err "This command runs on the Proxmox host, not inside a VM."
    echo ""
    echo "  Inside a VM, use:"
    echo "    gpu-setup driver             — install NVIDIA driver"
    echo "    gpu-setup driver --uninstall — remove NVIDIA driver"
    echo ""
    exit 1
  fi
}

mode_driver_install() {
  require_vm

  echo ""
  echo "NVIDIA GPU Driver — Install"
  echo "================================================="
  echo ""

  # Check for NVIDIA GPU
  info "Checking for NVIDIA GPU..."
  if ! lspci | grep -qi nvidia; then
    die "No NVIDIA GPU detected. Is GPU passthrough configured?"
  fi
  local GPU_MODEL
  GPU_MODEL=$(lspci | grep -i nvidia | head -1 | sed 's/.*: //')
  say "Found: ${GPU_MODEL}"

  # Install prerequisites
  info "Installing prerequisites..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ubuntu-drivers-common curl gnupg2 ca-certificates > /dev/null 2>&1
  say "Prerequisites installed."

  # Install NVIDIA driver
  local NEEDS_REBOOT=false
  local CURRENT_DRIVER=""
  local DRIVER_PKG=""
  local UTILS_PKG=""

  if has_cmd nvidia-smi && nvidia-smi &> /dev/null; then
    CURRENT_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    say "NVIDIA driver already installed (version: ${CURRENT_DRIVER}). Skipping driver install."
  else
    info "Installing NVIDIA driver..."

    add-apt-repository -y ppa:graphics-drivers/ppa > /dev/null 2>&1
    apt-get update -qq

    if [[ -n "${NVIDIA_DRIVER_VERSION:-}" ]]; then
      DRIVER_PKG="nvidia-headless-${NVIDIA_DRIVER_VERSION}"
      UTILS_PKG="nvidia-utils-${NVIDIA_DRIVER_VERSION}"
      info "Using specified driver branch: ${NVIDIA_DRIVER_VERSION}"
    else
      info "Detecting recommended driver..."
      local DRIVER_LIST
      DRIVER_LIST=$(ubuntu-drivers list 2>/dev/null || true)

      local DRIVER_BRANCH
      DRIVER_BRANCH=$(echo "$DRIVER_LIST" \
        | grep -oP 'nvidia-driver-\K[0-9]+(?=-server)' \
        | sort -n | tail -1)

      if [[ -z "$DRIVER_BRANCH" ]]; then
        DRIVER_BRANCH=$(echo "$DRIVER_LIST" \
          | grep -oP 'nvidia-driver-\K[0-9]+' \
          | sort -n | tail -1)
      fi

      [[ -n "$DRIVER_BRANCH" ]] || die "Could not detect a suitable NVIDIA driver. Try setting NVIDIA_DRIVER_VERSION manually."

      DRIVER_PKG="nvidia-headless-${DRIVER_BRANCH}"
      UTILS_PKG="nvidia-utils-${DRIVER_BRANCH}"
      info "Recommended driver branch: ${DRIVER_BRANCH}"
    fi

    apt-get install -y -qq "${DRIVER_PKG}" "${UTILS_PKG}" > /dev/null 2>&1 \
      || die "Failed to install ${DRIVER_PKG}. Try a different NVIDIA_DRIVER_VERSION."

    say "NVIDIA driver installed (${DRIVER_PKG})."
    NEEDS_REBOOT=true
  fi

  # Docker integration (optional)
  local HAS_DOCKER=false
  local HAS_CONTAINER_TK=false

  if has_cmd docker; then
    HAS_DOCKER=true
    info "Docker detected. Installing NVIDIA Container Toolkit..."

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq nvidia-container-toolkit > /dev/null 2>&1
    say "NVIDIA Container Toolkit installed."

    info "Configuring Docker to use NVIDIA runtime..."
    nvidia-ctk runtime configure --runtime=docker > /dev/null 2>&1
    say "Docker NVIDIA runtime configured."

    info "Restarting Docker..."
    systemctl restart docker
    say "Docker restarted."
    HAS_CONTAINER_TK=true

    # Restart Kasm agent if it happens to be running
    if docker ps --format '{{.Names}}' | grep -q kasm_agent; then
      info "Kasm agent detected. Restarting..."
      docker restart kasm_agent > /dev/null 2>&1
      say "Kasm agent restarted."
    fi
  else
    info "Docker not found. Skipping container toolkit setup."
    info "If you install Docker later, re-run this script to add GPU support."
  fi

  # Summary
  echo ""
  echo "Install Complete"
  echo "================================================="
  echo ""
  echo "  GPU             ${GPU_MODEL}"
  if [[ "${NEEDS_REBOOT}" == "true" ]]; then
    echo "  Driver          ${DRIVER_PKG} (REBOOT REQUIRED)"
  else
    echo "  Driver          ${CURRENT_DRIVER:-installed}"
  fi
  if [[ "${HAS_CONTAINER_TK}" == "true" ]]; then
    echo "  Container TK    installed"
    echo "  Docker runtime  nvidia"
  else
    echo "  Container TK    skipped (no Docker)"
  fi

  if [[ "${NEEDS_REBOOT}" == "true" ]]; then
    echo ""
    echo "  REBOOT REQUIRED to load the NVIDIA kernel module."
    echo "  After reboot, verify with: nvidia-smi"
  else
    echo ""
    echo "  Verify with: nvidia-smi"
    if [[ "${HAS_DOCKER}" == "true" ]]; then
      echo "  Test Docker GPU access with:"
      echo "    docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi"
    fi
  fi
  echo ""
}

mode_driver_uninstall() {
  require_vm

  echo ""
  echo "NVIDIA GPU Driver — Uninstall"
  echo "================================================="
  echo ""

  local removed_something=false

  # Remove NVIDIA Container Toolkit
  if dpkg -s nvidia-container-toolkit &>/dev/null; then
    info "Removing NVIDIA Container Toolkit..."
    apt-get remove -y -qq nvidia-container-toolkit > /dev/null 2>&1
    rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>/dev/null
    rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
    say "NVIDIA Container Toolkit removed."
    removed_something=true

    # Reconfigure Docker runtime if Docker is present
    if has_cmd docker; then
      info "Resetting Docker runtime config..."
      if [[ -f /etc/docker/daemon.json ]]; then
        # Remove nvidia runtime from daemon.json
        python3 -c "
import json, sys
try:
    with open('/etc/docker/daemon.json') as f:
        cfg = json.load(f)
    cfg.pop('default-runtime', None)
    cfg.get('runtimes', {}).pop('nvidia', None)
    if not cfg.get('runtimes'):
        cfg.pop('runtimes', None)
    with open('/etc/docker/daemon.json', 'w') as f:
        json.dump(cfg, f, indent=2)
except:
    pass
" 2>/dev/null || true
      fi
      systemctl restart docker 2>/dev/null || true
      say "Docker runtime reset."
    fi
  fi

  # Remove NVIDIA driver packages
  local nvidia_pkgs
  nvidia_pkgs=$(dpkg -l | grep -E '^ii\s+(nvidia-headless|nvidia-utils|nvidia-driver|nvidia-dkms|nvidia-kernel)' | awk '{print $2}' || true)
  if [[ -n "$nvidia_pkgs" ]]; then
    info "Removing NVIDIA driver packages..."
    # shellcheck disable=SC2086
    apt-get remove -y -qq $nvidia_pkgs > /dev/null 2>&1
    apt-get autoremove -y -qq > /dev/null 2>&1
    say "NVIDIA driver packages removed."
    removed_something=true
  fi

  # Remove PPA if added
  if [[ -f /etc/apt/sources.list.d/graphics-drivers-ubuntu-ppa-*.list ]] || \
     ls /etc/apt/sources.list.d/graphics-drivers-* &>/dev/null 2>&1; then
    info "Removing graphics-drivers PPA..."
    add-apt-repository -y --remove ppa:graphics-drivers/ppa > /dev/null 2>&1 || true
    say "PPA removed."
  fi

  if [[ "$removed_something" == "true" ]]; then
    echo ""
    echo "Uninstall Complete"
    echo "================================================="
    echo ""
    echo "  REBOOT RECOMMENDED to fully unload NVIDIA kernel modules."
    echo ""
  else
    echo "Nothing to remove — no NVIDIA driver or toolkit found."
  fi
}

# =============================================================================
# Main
# =============================================================================

# Parse -y/--yes flag from any position
ARGS=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes) NONINTERACTIVE=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

MODE="${1:-}"
case "$MODE" in
  "")        interactive_menu ;;
  # Host commands
  status)    require_host; mode_status ;;
  snapshot)  require_host; mode_snapshot ;;
  enable)    require_host; mode_enable ;;
  bind)      require_host; mode_bind "${2:-}" ;;
  revert)    require_host; mode_revert ;;
  # VM commands
  driver)
    if [[ "${2:-}" == "--uninstall" ]]; then
      mode_driver_uninstall
    else
      mode_driver_install
    fi
    ;;
  --version|-v) echo "gpu-setup v${SCRIPT_VERSION}" ;;
  --help|-h)
    echo "Usage: gpu-setup [OPTIONS] COMMAND [ARGS]"
    echo
    echo "Host commands (Proxmox only):"
    echo "  status              Show current GPU passthrough state"
    echo "  snapshot            Save full diagnostics to /root/"
    echo "  enable              Configure host for GPU passthrough (may need reboot)"
    echo "  bind [VMID|free]    Assign GPU to a VM (or free it)"
    echo "  revert              Undo all changes made by this script"
    echo
    echo "VM commands:"
    echo "  driver              Install NVIDIA driver + container toolkit"
    echo "  driver --uninstall  Remove NVIDIA driver + container toolkit"
    echo
    echo "Options:"
    echo "  -y, --yes           Non-interactive mode (auto-confirm all prompts)"
    echo
    echo "Examples:"
    echo "  gpu-setup                          # Interactive menu (auto-detects host/VM)"
    echo "  gpu-setup enable                   # Configure host for passthrough"
    echo "  gpu-setup bind 200                 # Bind GPU to VM 200"
    echo "  gpu-setup bind 200 -y              # Non-interactive bind (for Webmin)"
    echo "  gpu-setup bind free -y             # Unbind GPU from all VMs"
    echo "  gpu-setup driver                   # Install NVIDIA driver in VM"
    echo "  gpu-setup driver --uninstall       # Remove NVIDIA driver from VM"
    echo
    echo "The script auto-detects whether it's running on a Proxmox host or VM."
    ;;
  *)
    err "Unknown command: $MODE"
    echo "Usage: gpu-setup {status|snapshot|enable|bind|revert|driver}"
    echo "Run with no arguments for interactive menu."
    echo "Run with --help for full usage."
    exit 1
    ;;
esac