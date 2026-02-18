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
# Design:
# - Minimal, safe defaults (host VFIO + bind/switch GPU)
# - Optional VM "GPU-ready" tweaks (OVMF + q35 + optional kvm=off) ONLY if user opts in
# - No full backups; state-file tracks ONLY what this script added/changed
# - Revert removes ONLY what this script added/changed
# - Never edits VM conf with sed; uses qm set/--delete
# - Refuses to change bindings while VMs are running
#
set -euo pipefail

# ---------------- UI ----------------
say()  { echo -e "\033[1;32m✔\033[0m $*"; }
warn() { echo -e "\033[1;33m!\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m✘\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }

prompt_yn() {
  local q="$1"
  read -r -p "$q [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------- prereqs (safe) ----------------
[[ $EUID -eq 0 ]] || die "Run as root."

apt_install_if_missing() {
  local bin="$1" pkg="$2"
  if has_cmd "$bin"; then return 0; fi
  warn "Missing '$bin'. Installing: $pkg"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$pkg"
  has_cmd "$bin" || die "Tried to install $pkg but '$bin' is still missing."
  say "Installed $pkg"
}

# Safe tiny prereqs
apt_install_if_missing lspci pciutils
apt_install_if_missing update-initramfs initramfs-tools

# Hard requirements for Proxmox host (do not auto-install)
for c in qm awk grep sed tee find date lsmod lscpu cat sort paste head tail tr cut; do
  has_cmd "$c" || die "Missing required command '$c'. This does not look like a standard Proxmox host."
done
# Boot refresh tooling (systemd-boot typical on PVE9; grub possible)
if [[ -f /etc/kernel/cmdline ]]; then
  has_cmd proxmox-boot-tool || die "Missing 'proxmox-boot-tool' but systemd-boot detected."
else
  has_cmd update-grub || warn "GRUB detected but 'update-grub' missing; enable/revert of IOMMU flags may fail."
fi

# ---------------- constants/state ----------------
STATE_DIR="/var/lib/set-gpupass"
STATE_FILE="$STATE_DIR/state.env"
mkdir -p "$STATE_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

# Script-owned config files (never touch user generic ones)
MODPROBE_VFIO="/etc/modprobe.d/set-gpupass-vfio.conf"
MODPROBE_BL_NOUVEAU="/etc/modprobe.d/set-gpupass-blacklist-nouveau.conf"
MODPROBE_BL_NVIDIA="/etc/modprobe.d/set-gpupass-blacklist-nvidia.conf"

# ---------------- state helpers ----------------
# state.env is sourced; write only simple quoted values
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

write_state() {
  # Preserve all known keys (and allow empty)
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

ensure_state_loaded_and_initialized() {
  load_state
  [[ -f "$STATE_FILE" ]] || { STATE_CREATED_AT="$TS"; write_state; }
}

# ---------------- detection helpers ----------------
boot_method_detect() {
  if [[ -f /etc/kernel/cmdline ]]; then echo "systemd-boot"; else echo "grub"; fi
}

iommu_active() {
  [[ -d /sys/kernel/iommu_groups ]] && find /sys/kernel/iommu_groups -type l -maxdepth 3 >/dev/null 2>&1
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

detect_nvidia_gpu_addrs() {
  # NVIDIA VGA or 3D controllers
  lspci -Dn | awk '$0 ~ /10de:/ && $0 ~ /(VGA compatible controller|3D controller)/ {print $1}'
}

gpu_model_for_addr() {
  local addr="$1"
  lspci -s "${addr#0000:}" 2>/dev/null | sed -E 's/^[0-9a-fA-F:.]+ //'
}

sibling_functions() {
  # input: 0000:01:00.0 -> outputs all functions 0000:01:00.x
  local addr="$1"
  local prefix="${addr%.*}"
  lspci -Dn | awk -v pfx="$prefix" '$1 ~ ("^" pfx "\\.") {print $1}' | sort
}

driver_in_use() {
  local addr="$1"
  lspci -s "${addr#0000:}" -k 2>/dev/null | awk -F': ' '/Kernel driver in use:/ {print $2; exit}'
}

list_vms() {
  qm list | awk 'NR>1 {print $1}' | sort -n
}

vm_running() {
  local vmid="$1"
  qm status "$vmid" 2>/dev/null | grep -q 'status: running'
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

# If only 1 NVIDIA GPU, auto-select; if multiple, show menu
choose_gpu() {
  mapfile -t GPUS < <(detect_nvidia_gpu_addrs)
  [[ ${#GPUS[@]} -gt 0 ]] || die "No NVIDIA GPU found on this host."
  if [[ ${#GPUS[@]} -eq 1 ]]; then
    echo "${GPUS[0]}"
    return
  fi

  echo
  echo "Detected NVIDIA GPU(s):"
  local i=1 g
  for g in "${GPUS[@]}"; do
    echo "  [$i] ${g#0000:} ($(gpu_model_for_addr "$g")) (driver: $(driver_in_use "$g" || true))"
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

# ---------------- file edit helpers ----------------
ensure_line_in_file() {
  local file="$1" line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

remove_exact_line_from_file() {
  local file="$1" line="$2"
  [[ -f "$file" ]] || return 0
  grep -qxF "$line" "$file" || return 0
  awk -v l="$line" '$0 != l' "$file" > "${file}.tmp.$$" && mv "${file}.tmp.$$" "$file"
}

write_file_atomic() {
  local path="$1" tmp="${path}.tmp.$$"
  cat >"$tmp"
  mv "$tmp" "$path"
}

# ---------------- IOMMU flag management ----------------
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
      proxmox-boot-tool refresh >/dev/null
      IOMMU_FLAGS_ADDED="${added_tokens[*]}"
      write_state
      say "Enabled IOMMU kernel flags (systemd-boot): ${IOMMU_FLAGS_ADDED}"
    fi
  else
    local f="/etc/default/grub"
    [[ -f "$f" ]] || die "GRUB config not found at /etc/default/grub"
    local cur_line cur_val new_val
    cur_line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f" || true)"
    if [[ -z "$cur_line" ]]; then
      cur_line="$(grep -E '^GRUB_CMDLINE_LINUX=' "$f" || true)"
    fi
    if [[ -z "$cur_line" ]]; then
      die "Could not find GRUB_CMDLINE_LINUX_DEFAULT or GRUB_CMDLINE_LINUX in /etc/default/grub"
    fi
    cur_val="$(echo "$cur_line" | sed -E 's/^[A-Z0-9_]+=//;s/^"//;s/"$//')"
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
      # Replace only the matched variable line (prefer DEFAULT if present)
      if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
        sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${new_val//|/\\|}\"|" "$f"
      else
        sed -i -E "s|^GRUB_CMDLINE_LINUX=\".*\"|GRUB_CMDLINE_LINUX=\"${new_val//|/\\|}\"|" "$f"
      fi
      update-grub >/dev/null || warn "update-grub failed; check GRUB setup."
      IOMMU_FLAGS_ADDED="${added_tokens[*]}"
      write_state
      say "Enabled IOMMU kernel flags (GRUB): ${IOMMU_FLAGS_ADDED}"
    fi
  fi

  echo "$changed"
}

remove_iommu_kernel_flags_we_added() {
  ensure_state_loaded_and_initialized
  load_state
  [[ -n "${IOMMU_FLAGS_ADDED:-}" ]] || { say "No IOMMU flags to remove (none were added by set-gpupass)."; echo 0; return; }

  local method="${BOOT_METHOD:-}"
  [[ -n "$method" ]] || method="$(boot_method_detect)"

  local changed=0
  local tokens="$IOMMU_FLAGS_ADDED"

  if [[ "$method" == "systemd-boot" ]]; then
    local f="/etc/kernel/cmdline"
    [[ -f "$f" ]] || die "Missing /etc/kernel/cmdline"
    local cur; cur="$(cat "$f")"
    local t
    for t in $tokens; do
      cur="$(echo " $cur " | sed -E "s/[[:space:]]${t}[[:space:]]/ /g" | sed 's/^ //;s/ $//')"
    done
    cur="$(echo "$cur" | tr -s ' ')"
    write_file_atomic "$f" <<<"$cur"
    proxmox-boot-tool refresh >/dev/null
    changed=1
  else
    local f="/etc/default/grub"
    [[ -f "$f" ]] || die "Missing /etc/default/grub"
    local line var cur_val new_val
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
    update-grub >/dev/null || warn "update-grub failed; check GRUB setup."
    changed=1
  fi

  # clear state
  IOMMU_FLAGS_ADDED=""
  BOOT_METHOD="$method"
  write_state
  echo "$changed"
}

# ---------------- VFIO host config ----------------
host_has_nvidia_modules_loaded() {
  lsmod | grep -Eq '(^| )nvidia|nouveau( |$)'
}

compute_ids_csv_for_funcs() {
  local funcs=("$@")
  local ids
  ids="$(
    for f in "${funcs[@]}"; do
      lspci -Dnns "${f#0000:}" | awk -F'[][]' '{print $3}'
    done | sort -u | paste -sd, -
  )"
  [[ -n "$ids" ]] || die "Could not compute PCI IDs for GPU."
  echo "$ids"
}

ensure_vfio_modules_boot() {
  ensure_state_loaded_and_initialized
  load_state

  local f="/etc/modules"
  touch "$f"
  local added=()
  local m
  for m in vfio vfio_pci vfio_iommu_type1 vfio_virqfd; do
    if ! grep -qxF "$m" "$f" 2>/dev/null; then
      echo "$m" >> "$f"
      added+=("$m")
    fi
  done

  if [[ ${#added[@]} -gt 0 ]]; then
    VFIO_MODULE_LINES_ADDED="${added[*]}"
    write_state
    say "Enabled VFIO modules at boot"
    echo 1
  else
    echo 0
  fi
}

write_vfio_and_blacklist_files() {
  ensure_state_loaded_and_initialized
  load_state

  local funcs=("$@")
  local ids_csv; ids_csv="$(compute_ids_csv_for_funcs "${funcs[@]}")"

  # Write script-owned vfio binding
  write_file_atomic "$MODPROBE_VFIO" <<EOF
# managed by set-gpupass
options vfio-pci ids=${ids_csv} disable_vga=1
EOF

  # Blacklist to prevent host claiming GPU
  write_file_atomic "$MODPROBE_BL_NOUVEAU" <<'EOF'
# managed by set-gpupass
blacklist nouveau
options nouveau modeset=0
EOF

  write_file_atomic "$MODPROBE_BL_NVIDIA" <<'EOF'
# managed by set-gpupass
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF

  say "Configured vfio binding + driver blacklists"
}

remove_vfio_and_blacklist_files() {
  rm -f "$MODPROBE_VFIO" "$MODPROBE_BL_NOUVEAU" "$MODPROBE_BL_NVIDIA" || true
}

remove_vfio_module_lines_we_added() {
  ensure_state_loaded_and_initialized
  load_state
  [[ -n "${VFIO_MODULE_LINES_ADDED:-}" ]] || { say "No VFIO module lines to remove (none were added by set-gpupass)."; echo 0; return; }

  local f="/etc/modules"
  local m
  for m in $VFIO_MODULE_LINES_ADDED; do
    remove_exact_line_from_file "$f" "$m"
  done
  VFIO_MODULE_LINES_ADDED=""
  write_state
  echo 1
}

# ---------------- VM selection menu ----------------
prompt_vmid_menu() {
  local q="$1"
  mapfile -t MENU < <(qm list | awk 'NR>1 {print $1 "|" $2 "|" $3}')
  echo
  echo "$q"
  echo "Select an option:"
  echo "  0) Do nothing (exit)"
  echo "  F) Free/Unbind GPU from any VM"
  echo
  echo "Or select a VM:"
  echo "  #  VMID   Status    Name"
  echo "  -- -----  --------  -------------------------"

  local i=1 row vmid name status rest
  for row in "${MENU[@]}"; do
    vmid="${row%%|*}"
    rest="${row#*|}"
    name="${rest%%|*}"
    status="${rest#*|}"
    printf "  %-2s %-5s  %-8s  %s\n" "$i" "$vmid" "$status" "$name"
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

# ---------------- VM bind/switch helpers ----------------
remove_from_vm_if_present() {
  local vmid="$1"; shift
  local addr
  for addr in "$@"; do
    while read -r _ rest; do
      local key
      key="$(echo "$rest" | awk -F: '{print $1}')" # hostpci0
      warn "Removing $key from VM $vmid (was referencing ${addr#0000:})"
      qm set "$vmid" --delete "$key" >/dev/null
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
    [[ ${#slots[@]} -gt $idx ]] || die "No free hostpci slots on VM $vmid."
    short="${f#0000:}"
    warn "Adding $short to VM $vmid as hostpci${slots[$idx]} (pcie=1)"
    qm set "$vmid" --"hostpci${slots[$idx]}" "${short},pcie=1" >/dev/null
    idx=$((idx+1))
  done
  say "GPU added to VM $vmid"
}

# ---------------- Optional VM optimization (opt-in) ----------------
vm_get_key_value() {
  local vmid="$1" key="$2"
  qm config "$vmid" 2>/dev/null | awk -v k="$key" '$1==k":" {sub("^"k":",""); sub(/^ /,""); print; exit}'
}

vm_has_args() {
  local vmid="$1"
  qm config "$vmid" 2>/dev/null | grep -qE '^args:'
}

maybe_optimize_vm_for_gpu() {
  local vmid="$1"
  [[ -n "$vmid" ]] || return 0
  vm_running "$vmid" && return 0  # already checked elsewhere; keep safe

  local bios machine
  bios="$(vm_get_key_value "$vmid" "bios")"
  machine="$(vm_get_key_value "$vmid" "machine")"

  local need_reco=0
  [[ "${bios:-}" != "ovmf" ]] && need_reco=1
  # q35 is represented as "q35" in qm set; existing may be "pc-q35-..." or empty
  if [[ -n "${machine:-}" ]]; then
    echo "$machine" | grep -qi 'q35' || need_reco=1
  else
    # if empty, may default; still recommend q35 for passthrough
    need_reco=1
  fi

  if [[ $need_reco -eq 1 ]]; then
    echo
    warn "VM $vmid settings may reduce GPU passthrough compatibility."
    echo "Current:"
    echo "  BIOS:    ${bios:-"(default)"}"
    echo "  Machine: ${machine:-"(default)"}"
    echo
    echo "Recommended:"
    echo "  BIOS:    ovmf"
    echo "  Machine: q35"
    if prompt_yn "Apply recommended VM settings now?"; then
      ensure_state_loaded_and_initialized
      load_state
      # Track previous only once (first time we optimize)
      if [[ -z "${VM_OPTIMIZED_VMID:-}" ]]; then
        VM_OPTIMIZED_VMID="$vmid"
        VM_PREV_BIOS="${bios:-}"
        VM_PREV_MACHINE="${machine:-}"
        VM_PREV_ARGS_PRESENT="$(vm_has_args "$vmid" && echo yes || echo no)"
        VM_PREV_ARGS_VALUE="$(vm_get_key_value "$vmid" "args")"
      fi
      qm set "$vmid" --bios ovmf >/dev/null || warn "Failed to set BIOS to OVMF (may require EFI disk configured in UI)."
      qm set "$vmid" --machine q35 >/dev/null || warn "Failed to set machine to q35."
      write_state
      say "Applied recommended VM settings (as possible)."
    fi
  fi

  echo
  if prompt_yn "Apply Windows/NVIDIA workaround (hide KVM: -cpu host,kvm=off)?"; then
    ensure_state_loaded_and_initialized
    load_state
    if [[ -z "${VM_OPTIMIZED_VMID:-}" ]]; then
      VM_OPTIMIZED_VMID="$vmid"
      VM_PREV_BIOS="${bios:-}"
      VM_PREV_MACHINE="${machine:-}"
      VM_PREV_ARGS_PRESENT="$(vm_has_args "$vmid" && echo yes || echo no)"
      VM_PREV_ARGS_VALUE="$(vm_get_key_value "$vmid" "args")"
    fi
    qm set "$vmid" --args "-cpu host,kvm=off" >/dev/null || warn "Failed to set args."
    write_state
    say "Applied KVM-hiding args."
  fi
}

revert_vm_optimizations_if_any() {
  ensure_state_loaded_and_initialized
  load_state
  [[ -n "${VM_OPTIMIZED_VMID:-}" ]] || return 0
  local vmid="$VM_OPTIMIZED_VMID"
  qm status "$vmid" >/dev/null 2>&1 || { warn "Optimized VM $vmid no longer exists; skipping VM revert."; return 0; }
  vm_running "$vmid" && die "VM $vmid is running. Stop it first to revert VM settings safely."

  warn "Reverting VM settings for VM $vmid (only what set-gpupass changed)."

  # Restore BIOS if we had one; if empty, remove key by setting default isn't straightforward;
  # safest: set back if non-empty, otherwise leave (still safe).
  if [[ -n "${VM_PREV_BIOS:-}" ]]; then
    qm set "$vmid" --bios "$VM_PREV_BIOS" >/dev/null || warn "Failed to restore BIOS."
  fi

  if [[ -n "${VM_PREV_MACHINE:-}" ]]; then
    # If previous had explicit machine, restore it; otherwise leave.
    qm set "$vmid" --machine "$VM_PREV_MACHINE" >/dev/null || warn "Failed to restore machine."
  fi

  if [[ "${VM_PREV_ARGS_PRESENT:-no}" == "yes" ]]; then
    qm set "$vmid" --args "$VM_PREV_ARGS_VALUE" >/dev/null || warn "Failed to restore args."
  else
    # args did not exist before; remove it
    qm set "$vmid" --delete args >/dev/null || warn "Failed to remove args."
  fi

  # Clear VM optimization tracking
  VM_OPTIMIZED_VMID=""
  VM_PREV_BIOS=""
  VM_PREV_MACHINE=""
  VM_PREV_ARGS_PRESENT=""
  VM_PREV_ARGS_VALUE=""
  write_state
  say "VM settings reverted (where possible)."
}

# ---------------- modes ----------------
mode_status() {
  local gpu vendor
  vendor="$(cpu_vendor || true)"
  gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  echo
  echo "GPU Passthrough Status"
  echo "- CPU vendor: ${vendor:-unknown}"
  echo "- IOMMU:      $(iommu_active && echo ACTIVE || echo NOT ACTIVE)"
  echo "- NVIDIA GPU: ${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
  local f
  for f in "${FUNCS[@]}"; do
    echo "  - ${f#0000:} driver: $(driver_in_use "$f" || echo unknown)"
  done

  echo
  echo "VM usage:"
  local any=0 assigns
  for f in "${FUNCS[@]}"; do
    assigns="$(find_vm_assignments_for_addr "$f" || true)"
    if [[ -n "$assigns" ]]; then
      any=1
      echo "$assigns" | awk '{vm=$1; $1=""; sub(/^ /,""); print "- VM " vm ": " $0}'
    fi
  done
  [[ $any -eq 0 ]] && echo "- Not assigned to any VM"
}

mode_snapshot() {
  local out="/root/gpu-preflight-${TS}.txt"
  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  {
    echo "===== DATE ====="; date
    echo; echo "===== CPU ====="; lscpu | grep -i 'Vendor ID' || true
    echo; echo "===== BOOT METHOD ====="; boot_method_detect
    echo; echo "===== KERNEL CMDLINE ====="; cat /proc/cmdline || true
    echo; echo "===== IOMMU GROUPS (exists => active) ====="; (find /sys/kernel/iommu_groups -type l 2>/dev/null || true)
    echo; echo "===== GPU ====="; echo "${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
    echo; echo "===== GPU FUNCS + DRIVER ====="
    for f in "${FUNCS[@]}"; do
      echo "${f#0000:} driver: $(driver_in_use "$f" || echo unknown)"
    done
    echo; echo "===== MODULES (vfio/nvidia/nouveau) ====="; (lsmod | egrep 'vfio|nvidia|nouveau' || true)
    echo; echo "===== SCRIPT MODPROBE FILES ====="
    for f in "$MODPROBE_VFIO" "$MODPROBE_BL_NOUVEAU" "$MODPROBE_BL_NVIDIA"; do
      [[ -f "$f" ]] && { echo "--- $f ---"; cat "$f"; } || echo "(missing) $f"
    done
    echo; echo "===== /etc/modules ====="; cat /etc/modules 2>/dev/null || true
    echo; echo "===== VM hostpci lines ====="
    for vm in $(list_vms); do
      qm config "$vm" 2>/dev/null | grep -E '^hostpci[0-9]+:' && echo "VMID $vm above"
    done
    echo; echo "===== STATE FILE ====="
    [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "(no state file)"
  } | tee "$out" >/dev/null
  say "Saved snapshot to: $out"
}

mode_enable() {
  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  echo
  echo "GPU Passthrough Enable"
  say "NVIDIA GPU detected: ${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"

  # Safety: if host is currently using nvidia/nouveau, do not proceed live
  if host_has_nvidia_modules_loaded; then
    die "Host is currently using NVIDIA/nouveau drivers. Reboot and ensure host is not using the GPU, then run enable again."
  fi

  local changes=0
  ensure_state_loaded_and_initialized
  load_state

  # Record which GPU funcs this state refers to (for messaging / later)
  GPU_PCI_FUNCS="${FUNCS[*]}"
  write_state

  # Ensure kernel flags (may require reboot to activate IOMMU)
  local flags_changed
  flags_changed="$(enable_iommu_kernel_flags_if_missing)"
  [[ "$flags_changed" == "1" ]] && changes=1

  # If IOMMU still not active after flag changes (expected until reboot), explain and stop here
  if ! iommu_active; then
    warn "IOMMU is not active yet."
    if [[ "$flags_changed" == "1" ]]; then
      echo
      warn "Reboot required to activate IOMMU after adding kernel flags."
      echo "After reboot, run:"
      echo "  set-gpupass enable"
      exit 0
    else
      die "IOMMU is not active. Ensure VT-d/AMD-Vi is enabled in BIOS and kernel flags are present, then reboot."
    fi
  fi
  say "IOMMU detected"

  # Ensure VFIO boot modules
  local mod_changed
  mod_changed="$(ensure_vfio_modules_boot)"
  [[ "$mod_changed" == "1" ]] && changes=1

  # Write script-owned modprobe files (safe, deterministic)
  # Detect if content already matches; simplest: rewrite and treat as change only if missing
  local wrote=0
  if [[ ! -f "$MODPROBE_VFIO" || ! -f "$MODPROBE_BL_NOUVEAU" || ! -f "$MODPROBE_BL_NVIDIA" ]]; then
    wrote=1
  fi
  write_vfio_and_blacklist_files "${FUNCS[@]}"
  [[ "$wrote" == "1" ]] && changes=1

  update-initramfs -u >/dev/null
  say "initramfs updated"

  if [[ $changes -eq 1 ]]; then
    echo
    warn "Reboot required to complete setup."
    echo "After reboot, run:"
    echo "  set-gpupass bind"
  else
    say "Host is already configured for GPU passthrough."
    say "No reboot required."
  fi
}

mode_bind() {
  # Must be enabled first
  if ! iommu_active; then
    die "IOMMU is not active. Run: set-gpupass enable (and reboot if instructed)."
  fi

  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  # Check GPU is vfio-bound (best-effort)
  local ok=1 f drv
  for f in "${FUNCS[@]}"; do
    drv="$(driver_in_use "$f" || true)"
    [[ "$drv" == "vfio-pci" ]] || ok=0
  done
  if [[ $ok -eq 0 ]]; then
    warn "GPU is not fully bound to vfio-pci yet."
    warn "If you just ran enable, reboot and try again."
    echo
  fi

  # Determine which VMs reference it
  mapfile -t REF_VMS < <(
    for f in "${FUNCS[@]}"; do
      find_vm_assignments_for_addr "$f" | awk '{print $1}'
    done | sort -u
  )

  if [[ ${#REF_VMS[@]} -gt 0 ]]; then
    say "GPU is currently referenced by VM(s): ${REF_VMS[*]}"
  else
    say "GPU is not referenced by any VM."
  fi

  local target
  target="$(prompt_vmid_menu "What do you want to do with the GPU?")"

  if [[ "$target" == "__EXIT__" ]]; then
    say "No changes made."
    exit 0
  fi

  # Safety: refuse if any referencing VM is running (for FREE or SWITCH)
  local vmid
  for vmid in "${REF_VMS[@]}"; do
    vm_running "$vmid" && die "VM $vmid is running and references GPU. Stop it first to change GPU bindings safely."
  done

  if [[ "$target" == "__FREE__" ]]; then
    for vmid in "${REF_VMS[@]}"; do
      remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
    done
    say "GPU freed (no VM references remain)."
    exit 0
  fi

  vm_running "$target" && die "Target VM $target is running. Stop it first (safe default)."

  # Optional VM optimization prompts (opt-in)
  maybe_optimize_vm_for_gpu "$target"

  # Switch: remove from other VMs, then add to target
  for vmid in "${REF_VMS[@]}"; do
    [[ "$vmid" == "$target" ]] && continue
    remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
  done
  # avoid duplicates in target
  remove_from_vm_if_present "$target" "${FUNCS[@]}" || true
  add_funcs_to_vm "$target" "${FUNCS[@]}"

  say "Bind/switch complete."
  echo "Next: start VM $target and install NVIDIA drivers inside the VM."
}

mode_revert() {
  ensure_state_loaded_and_initialized
  load_state

  echo
  warn "This will undo ONLY what set-gpupass added:"
  echo "- Remove script VFIO binding + blacklists"
  echo "- Remove VFIO boot module lines that set-gpupass added"
  echo "- Remove IOMMU kernel flags that set-gpupass added (if any)"
  echo "- Rebuild initramfs"
  echo

  if ! prompt_yn "Proceed with revert?"; then
    say "No changes made."
    exit 0
  fi

  # Optional: remove GPU from VMs first
  if prompt_yn "Also remove GPU from all VMs (hostpci entries)?"; then
    local gpu; gpu="$(choose_gpu)"
    mapfile -t FUNCS < <(sibling_functions "$gpu")

    mapfile -t REF_VMS < <(
      for f in "${FUNCS[@]}"; do
        find_vm_assignments_for_addr "$f" | awk '{print $1}'
      done | sort -u
    )

    local vmid
    for vmid in "${REF_VMS[@]}"; do
      vm_running "$vmid" && die "VM $vmid is running. Stop it first to remove GPU safely."
    done
    for vmid in "${REF_VMS[@]}"; do
      remove_from_vm_if_present "$vmid" "${FUNCS[@]}"
    done
    say "GPU removed from VMs."
  fi

  # Optional: revert VM optimization if any (only affects one VM we tracked)
  if [[ -n "${VM_OPTIMIZED_VMID:-}" ]]; then
    if prompt_yn "Also revert optional VM settings that set-gpupass applied?"; then
      revert_vm_optimizations_if_any
    fi
  fi

  # Remove host config we own
  remove_vfio_and_blacklist_files
  say "Removed script vfio binding + blacklists"

  # Remove /etc/modules lines we added
  remove_vfio_module_lines_we_added >/dev/null || true

  # Remove IOMMU flags we added
  remove_iommu_kernel_flags_we_added >/dev/null || true

  update-initramfs -u >/dev/null
  say "initramfs updated"

  # If state now contains no changes, remove it; otherwise keep for safety
  load_state
  if [[ -z "${IOMMU_FLAGS_ADDED:-}" && -z "${VFIO_MODULE_LINES_ADDED:-}" && -z "${VM_OPTIMIZED_VMID:-}" ]]; then
    rm -f "$STATE_FILE" || true
    rmdir "$STATE_DIR" 2>/dev/null || true
    say "State cleared."
  else
    warn "State retained (some tracked items remain)."
  fi

  warn "Reboot recommended to fully return to default host driver binding."
}

# ---------------- main ----------------
MODE="${1:-status}"
case "$MODE" in
  status)    mode_status ;;
  snapshot)  mode_snapshot ;;
  enable)    mode_enable ;;
  bind)      mode_bind ;;
  revert)    mode_revert ;;
  *)
    echo "Usage: set-gpupass {status|snapshot|enable|bind|revert}"
    exit 1
    ;;
esac
