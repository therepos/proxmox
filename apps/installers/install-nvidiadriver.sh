#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/set-gpupass.sh?$(date +%s))"
# purpose: set gpu passthrough (and optionally remove host nvidia driver)
# version: pve9
#
# set-gpupass — Safe, reversible NVIDIA GPU passthrough helper for Proxmox VE
#
# Core modes:
#   set-gpupass status
#   set-gpupass snapshot
#   set-gpupass enable
#   set-gpupass bind
#   set-gpupass revert
#   set-gpupass oneclick
#   set-gpupass hostdriver   (optional: remove host NVIDIA driver packages)
#
# If run with no args (e.g. via wget|bash), shows an interactive menu.
#
# Key safety goals:
# - Never edit VM config files directly (no sed on /etc/pve/qemu-server/*.conf)
# - Never hide qm errors (non-technical users must see failures)
# - Only create script-owned modprobe files (does not touch vfio.conf or other user files)
# - IOMMU kernel flags: only add missing tokens; revert removes only tokens it added (tracked in state file)
# - Revert removes only what this script added/changed
#
set -euo pipefail

# ======================= version =======================
SCRIPT_VERSION="1.2.0"

# ======================= UI =======================
say()  { echo -e "\033[1;32m✔\033[0m $*"; }
warn() { echo -e "\033[1;33m⚠\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m✘\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }
info() { echo -e "\033[1;36mℹ\033[0m $*"; }

prompt_yn() {
  local q="$1" default="${2:-n}"
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

# ======================= prereqs =======================
[[ $EUID -eq 0 ]] || die "Run as root (use: sudo $0)"

# Verify we are on Proxmox
if [[ ! -f /etc/pve/.version ]] && ! has_cmd qm; then
  die "This does not appear to be a Proxmox VE host."
fi

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

# Safe tiny prereqs
apt_install_if_missing lspci pciutils
apt_install_if_missing update-initramfs initramfs-tools

# Hard requirements on Proxmox host
for c in qm awk grep sed tee find date lsmod lscpu cat sort paste tail tr cut readlink dpkg; do
  has_cmd "$c" || die "Missing required command '$c'. This does not look like a standard Proxmox host."
done

# Boot refresh tooling
if [[ -f /etc/kernel/cmdline ]]; then
  has_cmd proxmox-boot-tool || die "Missing 'proxmox-boot-tool' but systemd-boot detected."
else
  has_cmd update-grub || warn "GRUB detected but 'update-grub' missing; IOMMU enable/revert may fail."
fi

# ======================= constants/state =======================
STATE_DIR="/var/lib/set-gpupass"
STATE_FILE="$STATE_DIR/state.env"
TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STATE_DIR"

# Script-owned modprobe files (do not touch user generic vfio.conf etc.)
MODPROBE_VFIO="/etc/modprobe.d/set-gpupass-vfio.conf"
MODPROBE_BL_NOUVEAU="/etc/modprobe.d/set-gpupass-blacklist-nouveau.conf"
MODPROBE_BL_NVIDIA="/etc/modprobe.d/set-gpupass-blacklist-nvidia.conf"

# ======================= state helpers =======================
load_state() {
  # Reset all state vars to empty before sourcing to prevent stale data
  STATE_VERSION=""
  STATE_CREATED_AT=""
  BOOT_METHOD=""
  IOMMU_FLAGS_ADDED=""
  VFIO_MODULE_LINES_ADDED=""
  GPU_PCI_FUNCS=""
  VM_OPTIMIZED_VMID=""
  VM_PREV_BIOS=""
  VM_PREV_MACHINE=""
  VM_PREV_ARGS_PRESENT=""
  VM_PREV_ARGS_VALUE=""

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

write_state() {
  cat >"$STATE_FILE" <<EOF
# set-gpupass state (auto-generated). Remove only via: set-gpupass revert
STATE_VERSION="1"
STATE_CREATED_AT="${STATE_CREATED_AT:-$TS}"

BOOT_METHOD="${BOOT_METHOD:-}"                 # systemd-boot | grub
IOMMU_FLAGS_ADDED="${IOMMU_FLAGS_ADDED:-}"     # exact tokens added by script
VFIO_MODULE_LINES_ADDED="${VFIO_MODULE_LINES_ADDED:-}"  # exact lines added to /etc/modules
GPU_PCI_FUNCS="${GPU_PCI_FUNCS:-}"             # space-separated, e.g. "0000:01:00.0 0000:01:00.1"

# Optional VM optimization tracking (only if user opts in)
VM_OPTIMIZED_VMID="${VM_OPTIMIZED_VMID:-}"
VM_PREV_BIOS="${VM_PREV_BIOS:-}"
VM_PREV_MACHINE="${VM_PREV_MACHINE:-}"
VM_PREV_ARGS_PRESENT="${VM_PREV_ARGS_PRESENT:-}"  # yes|no
VM_PREV_ARGS_VALUE="${VM_PREV_ARGS_VALUE:-}"
EOF
}

ensure_state() {
  load_state
  [[ -f "$STATE_FILE" ]] || { STATE_CREATED_AT="$TS"; write_state; }
}

# ======================= detection helpers =======================
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

host_has_any_nvidia_gpu() {
  [[ -n "$(detect_nvidia_gpu_addrs | head -1)" ]]
}

choose_gpu() {
  mapfile -t GPUS < <(detect_nvidia_gpu_addrs)
  [[ ${#GPUS[@]} -gt 0 ]] || die "No NVIDIA GPU found on this host."
  if [[ ${#GPUS[@]} -eq 1 ]]; then
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

host_nvidia_userspace_present() {
  has_cmd nvidia-smi
}

host_nvidia_pkgs_installed() {
  # Broad catch (covers pve-nvidia-driver, nvidia-driver, cuda-drivers, etc.)
  # Return 0 if any matching packages are installed.
  dpkg -l 2>/dev/null | awk '$1=="ii"{print $2}' | grep -Eq \
    '^(pve-nvidia-driver|nvidia-driver|nvidia-headless|nvidia-kernel-dkms|cuda-drivers|cuda)$|^nvidia-'
}

host_driver_summary() {
  local pkgs="no" smi="no" mods="no"
  host_nvidia_pkgs_installed && pkgs="yes"
  host_nvidia_userspace_present && smi="yes"
  host_has_nvidia_modules_loaded && mods="yes"
  echo "packages=${pkgs}, nvidia-smi=${smi}, modules_loaded=${mods}"
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

# ======================= IOMMU group isolation check =======================
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

# ======================= file helpers =======================
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

# ======================= IOMMU kernel flags (tracked) =======================
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

# ======================= VFIO host config (tracked) =======================
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

  # vfio_virqfd merged into vfio in kernel 5.16+; only add if it exists as a module
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
# managed by set-gpupass — do not edit manually
options vfio-pci ids=${ids_csv} disable_vga=1
EOF

  write_file_atomic "$MODPROBE_BL_NOUVEAU" <<'EOF'
# managed by set-gpupass — do not edit manually
blacklist nouveau
options nouveau modeset=0
EOF

  write_file_atomic "$MODPROBE_BL_NVIDIA" <<'EOF'
# managed by set-gpupass — do not edit manually
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

# ======================= VM menu (always prints; single-VM UX) =======================
prompt_vmid_menu() {
  local q="$1"
  mapfile -t MENU < <(qm list 2>/dev/null | tail -n +2 | while read -r vmid name status _; do
    [[ -n "$vmid" ]] && echo "$vmid|$name|$status"
  done)

  # filter out any empty entries
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

# ======================= VM bind/switch helpers =======================
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

# ======================= VM stop/start helpers =======================
stop_vm_with_wait() {
  local vmid="$1"
  local interval=3

  if ! vm_running "$vmid"; then
    say "VM $vmid is already stopped."
    return 0
  fi

  local has_agent=0
  if qm config "$vmid" 2>/dev/null | grep -qE '^agent:.*1'; then
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
  sleep 2
  return 0
}

start_vm_with_wait() {
  local vmid="$1"

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
    info "Run 'set-gpupass snapshot' and check the output for clues."
    return 1
  fi

  sleep 3
  if vm_running "$vmid"; then
    say "VM $vmid is running with GPU passthrough!"
  else
    warn "VM $vmid was started but doesn't appear to be running."
    warn "Check the Proxmox UI or run: qm status $vmid"
  fi
}

# ======================= host driver removal (optional) =======================
mode_hostdriver() {
  echo
  echo "═══════════════════════════════════"
  echo " Host NVIDIA Driver (optional)"
  echo "═══════════════════════════════════"
  echo

  if ! host_has_any_nvidia_gpu; then
    say "No NVIDIA GPU detected. Nothing to do."
    return 0
  fi

  local summary; summary="$(host_driver_summary)"
  info "Detected: $summary"
  echo
  warn "GPU passthrough requires the HOST to NOT use the NVIDIA GPU."
  warn "Removing host NVIDIA drivers is OPTIONAL and only needed if the host is using the GPU."
  echo

  if ! prompt_yn "Remove/Purge NVIDIA driver packages from the host now?"; then
    say "No changes made."
    return 0
  fi

  warn "This will run: apt-get purge nvidia* pve-nvidia-driver* cuda*"
  warn "If you use this GPU on the host for console/compute, you will lose that capability."
  echo
  if ! prompt_yn "Final confirmation: purge host NVIDIA drivers?"; then
    say "No changes made."
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || die "apt-get update failed."

  # Purge broad patterns; ignore errors if packages don't exist
  apt-get purge -y 'pve-nvidia-driver*' 'nvidia*' 'cuda*' >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true

  update-initramfs -u
  say "Host NVIDIA driver purge complete + initramfs updated."
  warn "Reboot recommended."
}

# ======================= modes =======================
mode_status() {
  echo
  echo "═══════════════════════════════════"
  echo " GPU Passthrough Status"
  echo "═══════════════════════════════════"
  echo

  echo "  CPU vendor : $(cpu_vendor || echo unknown)"
  echo "  Boot method: $(boot_method_detect)"
  echo "  IOMMU      : $(iommu_active && echo "ACTIVE ✔" || echo "NOT ACTIVE ✘")"

  if host_has_any_nvidia_gpu; then
    local gpu; gpu="$(choose_gpu)"
    mapfile -t FUNCS < <(sibling_functions "$gpu")
    echo "  NVIDIA GPU : ${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
    echo "  Host driver: $(host_driver_summary)"

    local f
    for f in "${FUNCS[@]}"; do
      local drv marker=""
      drv="$(driver_in_use "$f" || echo "none")"
      [[ "$drv" == "vfio-pci" ]] && marker=" (ready for passthrough)"
      echo "    ${f#0000:} → driver: ${drv}${marker}"
    done

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
  else
    echo "  NVIDIA GPU : none detected"
  fi

  echo
  if [[ -f "$STATE_FILE" ]]; then
    echo "  State file: $STATE_FILE (set-gpupass has been run before)"
  else
    echo "  State file: none (set-gpupass has not configured anything yet)"
  fi
}

mode_snapshot() {
  local out="/root/gpu-preflight-${TS}.txt"

  local gpu=""
  local FUNCS=()
  if host_has_any_nvidia_gpu; then
    gpu="$(choose_gpu)"
    mapfile -t FUNCS < <(sibling_functions "$gpu")
  fi

  {
    echo "===== set-gpupass snapshot ====="
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

    echo; echo "===== HOST NVIDIA DRIVER ====="
    if host_has_any_nvidia_gpu; then
      echo "$(host_driver_summary)"
    else
      echo "(no NVIDIA GPU detected)"
    fi

    if [[ -n "${gpu:-}" ]]; then
      echo; echo "===== GPU ====="; echo "${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
      echo; echo "===== GPU FUNCS + DRIVER ====="
      local f
      for f in "${FUNCS[@]}"; do echo "${f#0000:} driver: $(driver_in_use "$f" || echo none)"; done
      echo; echo "===== GPU IOMMU GROUP ====="
      local glink="/sys/bus/pci/devices/${gpu}/iommu_group"
      if [[ -L "$glink" ]]; then
        ls "$(readlink -f "$glink")/devices/" 2>/dev/null || true
      else
        echo "(not available)"
      fi
    fi

    echo; echo "===== LOADED NVIDIA/VFIO MODULES ====="
    lsmod | grep -iE 'nvidia|nouveau|vfio' || echo "(none loaded)"

    echo; echo "===== SCRIPT MODPROBE FILES ====="
    local ff
    for ff in "$MODPROBE_VFIO" "$MODPROBE_BL_NOUVEAU" "$MODPROBE_BL_NVIDIA"; do
      [[ -f "$ff" ]] && { echo "--- $ff ---"; cat "$ff"; } || echo "(missing) $ff"
    done

    echo; echo "===== /etc/modules ====="; cat /etc/modules 2>/dev/null || true
    echo; echo "===== VM hostpci lines ====="
    local found=0
    local vm lines
    for vm in $(list_vms); do
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
  info "Host driver: $(host_driver_summary)"

  if host_has_nvidia_modules_loaded; then
    echo
    err "Host currently has NVIDIA or nouveau kernel modules loaded."
    err "This means the host is using the GPU. Passthrough requires the"
    err "host to NOT use the GPU."
    echo
    info "Option: run 'set-gpupass hostdriver' to purge host NVIDIA drivers (optional)."
    die "Cannot proceed while host NVIDIA/nouveau modules are loaded."
  fi

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
      info "After reboot, run: set-gpupass enable"
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
    info "  4. Run: set-gpupass enable"
    die "IOMMU is not active."
  fi
  say "IOMMU is active"

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
    info "After reboot, run: set-gpupass bind"
  else
    say "Host is already configured for GPU passthrough."
    say "No reboot required. You can run: set-gpupass bind"
  fi
}

mode_bind() {
  if ! iommu_active; then
    die "IOMMU is not active. Run: set-gpupass enable (and reboot if instructed)."
  fi

  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  echo
  echo "═══════════════════════════════════"
  echo " GPU Passthrough — Bind to VM"
  echo "═══════════════════════════════════"
  echo

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
    info "Did you run 'set-gpupass enable' and reboot?"
    info "Try: set-gpupass enable → reboot → set-gpupass bind"
    if ! prompt_yn "Continue anyway (advanced users only)?"; then
      die "Aborted. Run 'set-gpupass enable' first."
    fi
  else
    say "All GPU functions bound to vfio-pci."
  fi

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
  target="$(prompt_vmid_menu "What do you want to do with the GPU?")"

  if [[ "$target" == "__EXIT__" ]]; then
    say "No changes made."
    return 0
  fi

  local vms_to_stop=()
  local vms_were_running=()
  local vmid

  for vmid in "${REF_VMS[@]}"; do
    vm_running "$vmid" && vms_to_stop+=("$vmid")
  done

  if [[ "$target" != "__FREE__" ]] && [[ "$target" != "__EXIT__" ]]; then
    if vm_running "$target"; then
      local already=0
      for vmid in "${vms_to_stop[@]+"${vms_to_stop[@]}"}"; do
        [[ "$vmid" == "$target" ]] && already=1
      done
      [[ $already -eq 0 ]] && vms_to_stop+=("$target")
    fi
  fi

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

  # FREE path
  if [[ "$target" == "__FREE__" ]]; then
    if [[ ${#REF_VMS[@]} -eq 0 ]]; then
      say "GPU is already free (not assigned to any VM)."
      return 0
    fi
    for vmid in "${REF_VMS[@]}"; do
      remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
    done
    say "GPU freed (no VM references remain)."

    if [[ ${#vms_were_running[@]} -gt 0 ]]; then
      echo
      info "Restarting VM(s) that were running before (now without GPU)..."
      for vmid in "${vms_were_running[@]}"; do
        start_vm_with_wait "$vmid" || warn "Could not restart VM $vmid. Start it manually: qm start $vmid"
      done
    fi
    return 0
  fi

  # ASSIGN path
  for vmid in "${REF_VMS[@]}"; do
    [[ "$vmid" == "$target" ]] && continue
    remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
  done
  remove_from_vm_if_present "$target" "${FUNCS[@]}" || true
  add_funcs_to_vm "$target" "${FUNCS[@]}"

  echo
  say "═══════════════════════════════════════"
  say " GPU bound to VM $target successfully!"
  say "═══════════════════════════════════════"
  echo

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
  warn "This will undo ONLY what set-gpupass added:"
  echo "  • Remove script VFIO binding + blacklists"
  echo "  • Remove VFIO boot module lines that set-gpupass added"
  echo "  • Remove IOMMU kernel flags that set-gpupass added (if any)"
  echo "  • Rebuild initramfs"
  echo

  if ! prompt_yn "Proceed with revert?"; then
    say "No changes made."
    return 0
  fi

  if prompt_yn "Also remove GPU from all VMs (hostpci entries)?"; then
    local gpu; gpu="$(choose_gpu)"
    mapfile -t FUNCS < <(sibling_functions "$gpu")

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

  load_state
  if [[ -z "${IOMMU_FLAGS_ADDED:-}" && -z "${VFIO_MODULE_LINES_ADDED:-}" ]]; then
    rm -f "$STATE_FILE" || true
    rmdir "$STATE_DIR" 2>/dev/null || true
    say "State cleared."
  else
    warn "State retained (some tracked items remain)."
  fi
}

mode_oneclick() {
  echo
  echo "═══════════════════════════════════"
  echo " One-Click GPU Passthrough"
  echo "═══════════════════════════════════"
  echo

  if ! host_has_any_nvidia_gpu; then
    die "No NVIDIA GPU found on this host."
  fi

  info "Host driver: $(host_driver_summary)"
  if host_has_nvidia_modules_loaded; then
    warn "Host is currently using the NVIDIA GPU (kernel modules loaded)."
    info "You can:"
    echo "  1) Try rebooting first (if this is a fresh install)"
    echo "  2) Or run: set-gpupass hostdriver (optional purge), then reboot"
    echo
    if prompt_yn "Run host driver purge now (optional)?"; then
      mode_hostdriver
      echo
      warn "Reboot recommended after purging drivers."
      return 0
    fi
    die "Cannot continue while host NVIDIA/nouveau modules are loaded."
  fi

  # Step 1: Enable
  mode_enable

  # If enable asked for reboot, stop here (it exits 0 in that case).
  if ! iommu_active; then
    return 0
  fi

  echo
  if prompt_yn "Proceed to Bind/Unbind GPU to a VM now?"; then
    mode_bind
  else
    info "You can run later: set-gpupass bind"
  fi
}

# ======================= interactive menu =======================
interactive_menu() {
  echo
  echo "═══════════════════════════════════════"
  echo "  set-gpupass v${SCRIPT_VERSION}"
  echo "  NVIDIA GPU Passthrough for Proxmox"
  echo "═══════════════════════════════════════"

  if host_has_any_nvidia_gpu; then
    info "Precheck: NVIDIA GPU detected; Host driver: $(host_driver_summary)"
  else
    info "Precheck: No NVIDIA GPU detected"
  fi

  while true; do
    echo
    echo "┌────────────────────────────────────────────┐"
    echo "│  1) One-Click  — enable + bind/unbind       │"
    echo "│  2) Status     — show current state         │"
    echo "│  3) Enable     — prepare host               │"
    echo "│  4) Bind       — assign/free GPU to a VM    │"
    echo "│  5) Snapshot   — save diagnostics           │"
    echo "│  6) Revert     — undo all changes           │"
    echo "│  7) HostDriver — optional purge NVIDIA      │"
    echo "│  0) Exit                                     │"
    echo "└────────────────────────────────────────────┘"
    echo
    read -r -p "Choose [0-7]: " choice
    case "${choice:-}" in
      1) mode_oneclick ;;
      2) mode_status ;;
      3) mode_enable ;;
      4) mode_bind ;;
      5) mode_snapshot ;;
      6) mode_revert ;;
      7) mode_hostdriver ;;
      0|q|Q|exit) say "Goodbye."; exit 0 ;;
      *) warn "Invalid option. Enter 0-7." ;;
    esac
  done
}

# ======================= main =======================
MODE="${1:-}"
case "$MODE" in
  "")        interactive_menu ;;
  oneclick)  mode_oneclick ;;
  status)    mode_status ;;
  snapshot)  mode_snapshot ;;
  enable)    mode_enable ;;
  bind)      mode_bind ;;
  revert)    mode_revert ;;
  hostdriver) mode_hostdriver ;;
  --version|-v) echo "set-gpupass v${SCRIPT_VERSION}" ;;
  --help|-h)
    echo "Usage: set-gpupass [oneclick|status|snapshot|enable|bind|revert|hostdriver]"
    echo
    echo "  oneclick    Enable + then bind/unbind"
    echo "  status      Show current GPU passthrough state"
    echo "  snapshot    Save full diagnostics to /root/"
    echo "  enable      Configure host for GPU passthrough (may need reboot)"
    echo "  bind        Assign/switch/free GPU to a VM"
    echo "  revert      Undo all changes made by this script"
    echo "  hostdriver  Optional: purge host NVIDIA drivers"
    echo
    echo "Run with no arguments for interactive menu."
    ;;
  *)
    err "Unknown command: $MODE"
    echo "Usage: set-gpupass {oneclick|status|snapshot|enable|bind|revert|hostdriver}"
    echo "Run with no arguments for interactive menu."
    exit 1
    ;;
esac
