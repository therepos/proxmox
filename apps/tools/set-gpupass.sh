#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/set-gpupass.sh?$(date +%s))"
# purpose: set gpu passthrough
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
SCRIPT_VERSION="1.1.0"

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
for c in qm awk grep sed tee find date lsmod lscpu cat sort paste tail tr cut readlink; do
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

# ======================= Optional VM optimization (opt-in, tracked) =======================
vm_get_key_value() {
  local vmid="$1" key="$2"
  qm config "$vmid" 2>/dev/null | awk -v k="$key" '$1==k":" {sub("^"k":",""); sub(/^ /,""); print; exit}'
}

vm_has_args() {
  local vmid="$1"
  qm config "$vmid" 2>/dev/null | grep -qE '^args:'
}

vm_has_efidisk() {
  local vmid="$1"
  qm config "$vmid" 2>/dev/null | grep -qE '^efidisk[0-9]+:'
}

maybe_optimize_vm_for_gpu() {
  local vmid="$1"
  vm_running "$vmid" && return 0

  local bios machine
  bios="$(vm_get_key_value "$vmid" "bios")"
  machine="$(vm_get_key_value "$vmid" "machine")"

  local need=0
  [[ "${bios:-}" != "ovmf" ]] && need=1
  if [[ -n "${machine:-}" ]]; then
    echo "$machine" | grep -qi 'q35' || need=1
  else
    need=1
  fi

  if [[ $need -eq 1 ]]; then
    echo
    warn "VM $vmid may need compatibility settings for best GPU passthrough."
    echo "Current:"
    echo "  BIOS:    ${bios:-"(default/SeaBIOS)"}"
    echo "  Machine: ${machine:-"(default/i440fx)"}"
    echo "Recommended:"
    echo "  BIOS:    ovmf (UEFI)"
    echo "  Machine: q35"

    # FIX: check for EFI disk before offering OVMF switch
    if ! vm_has_efidisk "$vmid"; then
      echo
      warn "VM $vmid has NO EFI disk. Switching to OVMF without an EFI disk will"
      warn "prevent the VM from booting. You should add one first via Proxmox UI:"
      info "  VM → Hardware → Add → EFI Disk"
      echo
      if ! prompt_yn "I have an EFI disk or will add one. Apply settings anyway?"; then
        info "Skipping BIOS/machine change."
        # Still offer kvm=off below
        _maybe_apply_kvm_off "$vmid" "$bios" "$machine"
        return 0
      fi
    fi

    if prompt_yn "Apply recommended VM settings (OVMF + q35)?"; then
      ensure_state; load_state
      if [[ -z "${VM_OPTIMIZED_VMID:-}" ]]; then
        VM_OPTIMIZED_VMID="$vmid"
        VM_PREV_BIOS="${bios:-}"
        VM_PREV_MACHINE="${machine:-}"
        VM_PREV_ARGS_PRESENT="$(vm_has_args "$vmid" && echo yes || echo no)"
        VM_PREV_ARGS_VALUE="$(vm_get_key_value "$vmid" "args")"
        write_state
      fi
      run_qm set "$vmid" --bios ovmf
      run_qm set "$vmid" --machine q35
      say "Applied VM settings (OVMF + q35)."
    fi
  fi

  _maybe_apply_kvm_off "$vmid" "$bios" "$machine"
}

_maybe_apply_kvm_off() {
  local vmid="$1" bios="$2" machine="$3"
  echo
  # FIX: updated guidance — kvm=off is rarely needed with modern NVIDIA drivers (535+)
  info "Note: Modern NVIDIA drivers (535+) usually do NOT need the kvm=off workaround."
  info "Only apply this if the VM fails to install NVIDIA drivers without it."
  if prompt_yn "Apply Windows/NVIDIA workaround (hide KVM: -cpu host,kvm=off)?"; then
    ensure_state; load_state
    if [[ -z "${VM_OPTIMIZED_VMID:-}" ]]; then
      VM_OPTIMIZED_VMID="$vmid"
      VM_PREV_BIOS="${bios:-}"
      VM_PREV_MACHINE="${machine:-}"
      VM_PREV_ARGS_PRESENT="$(vm_has_args "$vmid" && echo yes || echo no)"
      VM_PREV_ARGS_VALUE="$(vm_get_key_value "$vmid" "args")"
    fi
    run_qm set "$vmid" --args "-cpu host,kvm=off"
    write_state
    say "Applied KVM-hiding args."
  fi
}

revert_vm_optimizations_if_any() {
  ensure_state; load_state
  [[ -n "${VM_OPTIMIZED_VMID:-}" ]] || return 0
  local vmid="$VM_OPTIMIZED_VMID"

  # FIX: verify VM still exists before trying to revert
  if ! vm_exists "$vmid"; then
    warn "VM $vmid no longer exists. Clearing tracked optimization state."
    VM_OPTIMIZED_VMID=""; VM_PREV_BIOS=""; VM_PREV_MACHINE=""; VM_PREV_ARGS_PRESENT=""; VM_PREV_ARGS_VALUE=""
    write_state
    return 0
  fi

  vm_running "$vmid" && die "VM $vmid is running. Stop it first to revert VM settings."

  warn "Reverting VM settings for VM $vmid (only what set-gpupass changed)."
  if [[ -n "${VM_PREV_BIOS:-}" ]]; then run_qm set "$vmid" --bios "$VM_PREV_BIOS"; fi
  if [[ -n "${VM_PREV_MACHINE:-}" ]]; then run_qm set "$vmid" --machine "$VM_PREV_MACHINE"; fi

  if [[ "${VM_PREV_ARGS_PRESENT:-no}" == "yes" ]]; then
    run_qm set "$vmid" --args "$VM_PREV_ARGS_VALUE"
  else
    # FIX: --delete args can fail if args doesn't exist; suppress gracefully
    qm set "$vmid" --delete args 2>/dev/null || true
  fi

  VM_OPTIMIZED_VMID=""; VM_PREV_BIOS=""; VM_PREV_MACHINE=""; VM_PREV_ARGS_PRESENT=""; VM_PREV_ARGS_VALUE=""
  write_state
  say "VM settings reverted."
}

# ======================= VM stop/start helpers =======================
stop_vm_with_wait() {
  local vmid="$1"
  local timeout=90
  local interval=3

  if ! vm_running "$vmid"; then
    say "VM $vmid is already stopped."
    return 0
  fi

  info "Sending shutdown to VM $vmid..."
  # Try graceful shutdown first (sends ACPI shutdown to guest)
  qm shutdown "$vmid" 2>/dev/null || true

  local waited=0
  while vm_running "$vmid" && (( waited < 30 )); do
    printf "."
    sleep "$interval"
    waited=$((waited + interval))
  done
  echo  # newline after dots

  # If graceful didn't work, use stop (pulls the plug)
  if vm_running "$vmid"; then
    warn "Graceful shutdown timed out. Stopping VM $vmid..."
    qm stop "$vmid" 2>&1 || true

    waited=0
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
      err "Could not stop VM $vmid after ${timeout}s."
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
    info "Run 'set-gpupass snapshot' and check the output for clues."
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

# ======================= modes =======================
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
  echo "  IOMMU      : $(iommu_active && echo "ACTIVE ✔" || echo "NOT ACTIVE ✘")"
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
    echo "  State file: $STATE_FILE (set-gpupass has been run before)"
  else
    echo "  State file: none (set-gpupass has not configured anything yet)"
  fi
}

mode_snapshot() {
  local out="/root/gpu-preflight-${TS}.txt"
  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

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
    info "Did you run 'set-gpupass enable' and reboot?"
    info "Try: set-gpupass enable → reboot → set-gpupass bind"
    if ! prompt_yn "Continue anyway (advanced users only)?"; then
      die "Aborted. Run 'set-gpupass enable' first."
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
  target="$(prompt_vmid_menu "What do you want to do with the GPU?")"

  if [[ "$target" == "__EXIT__" ]]; then
    say "No changes made."
    return 0
  fi

  # Collect all VMs that need to be stopped before we can proceed
  local vms_to_stop=()
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
    info "GPU bindings cannot be changed while VMs using the GPU are running."
    echo
    if prompt_yn "Stop VM(s) ${vms_to_stop[*]} now?"; then
      for vmid in "${vms_to_stop[@]}"; do
        stop_vm_with_wait "$vmid" || die "Could not stop VM $vmid. Please stop it manually and try again."
      done
    else
      die "Cannot proceed while VM(s) are running. Stop them manually and try again."
    fi
  fi

  if [[ "$target" == "__FREE__" ]]; then
    if [[ ${#REF_VMS[@]} -eq 0 ]]; then
      say "GPU is already free (not assigned to any VM)."
      return 0
    fi
    for vmid in "${REF_VMS[@]}"; do
      remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
    done
    say "GPU freed (no VM references remain)."
    return 0
  fi

  # Optional prompts (opt-in)
  maybe_optimize_vm_for_gpu "$target"

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

  # Offer to start the VM (passthrough requires a Proxmox-level start)
  info "GPU passthrough requires starting the VM from Proxmox (not from inside the guest)."
  info "A guest-level reboot will NOT pick up the new GPU."
  echo
  if prompt_yn "Start VM $target now?"; then
    start_vm_with_wait "$target"
  else
    echo
    info "When you're ready, start the VM with:"
    echo "  qm start $target"
    echo "  (or use the Proxmox web UI)"
  fi
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

  # Optional: revert VM optimization changes (if we tracked any)
  if [[ -n "${VM_OPTIMIZED_VMID:-}" ]]; then
    if prompt_yn "Also revert VM settings set-gpupass applied (OVMF/q35/kvm=off)?"; then
      revert_vm_optimizations_if_any
    fi
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
  if [[ -z "${IOMMU_FLAGS_ADDED:-}" && -z "${VFIO_MODULE_LINES_ADDED:-}" && -z "${VM_OPTIMIZED_VMID:-}" ]]; then
    rm -f "$STATE_FILE" || true
    rmdir "$STATE_DIR" 2>/dev/null || true
    say "State cleared."
  else
    warn "State retained (some tracked items remain)."
  fi
}

# ======================= interactive menu =======================
interactive_menu() {
  echo
  echo "═══════════════════════════════════════"
  echo "  set-gpupass v${SCRIPT_VERSION}"
  echo "  NVIDIA GPU Passthrough for Proxmox"
  echo "═══════════════════════════════════════"

  while true; do
    echo
    echo "┌─────────────────────────────────────┐"
    echo "│  1) Status    — show current state   │"
    echo "│  2) Enable    — prepare host          │"
    echo "│  3) Bind      — assign GPU to a VM    │"
    echo "│  4) Snapshot  — save diagnostics       │"
    echo "│  5) Revert    — undo all changes       │"
    echo "│  0) Exit                               │"
    echo "└─────────────────────────────────────┘"
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
}

# ======================= main =======================
MODE="${1:-}"
case "$MODE" in
  "")        interactive_menu ;;
  status)    mode_status ;;
  snapshot)  mode_snapshot ;;
  enable)    mode_enable ;;
  bind)      mode_bind ;;
  revert)    mode_revert ;;
  --version|-v) echo "set-gpupass v${SCRIPT_VERSION}" ;;
  --help|-h)
    echo "Usage: set-gpupass [status|snapshot|enable|bind|revert]"
    echo
    echo "  status    Show current GPU passthrough state"
    echo "  snapshot  Save full diagnostics to /root/"
    echo "  enable    Configure host for GPU passthrough (may need reboot)"
    echo "  bind      Assign/switch GPU to a VM"
    echo "  revert    Undo all changes made by this script"
    echo
    echo "Run with no arguments for interactive menu."
    ;;
  *)
    err "Unknown command: $MODE"
    echo "Usage: set-gpupass {status|snapshot|enable|bind|revert}"
    echo "Run with no arguments for interactive menu."
    exit 1
    ;;
esac