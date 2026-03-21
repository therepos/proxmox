#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/setup-gpu.sh.sh?$(date +%s))"
# purpose: one-stop NVIDIA toolkit for Proxmox — host driver install + GPU passthrough
# version: pve9
#
# nvidia-toolkit — Safe, reversible NVIDIA driver + GPU passthrough helper for Proxmox VE
#
# Disable secure boot first!
#
# DRIVER commands (host GPU use):
#   nvidia-toolkit driver-install   Install NVIDIA driver via APT (no .run)
#   nvidia-toolkit driver-status    Detailed host driver diagnostics
#   nvidia-toolkit driver-remove    Purge host NVIDIA driver packages
#
# PASSTHROUGH commands (VM GPU use):
#   nvidia-toolkit passthrough      One-click: enable + bind
#   nvidia-toolkit enable           Prepare host for passthrough (IOMMU, VFIO, blacklists)
#   nvidia-toolkit bind             Assign/switch/free GPU to a VM
#   nvidia-toolkit revert           Undo all passthrough changes
#
# UTILITY commands:
#   nvidia-toolkit status           Full system overview (driver + passthrough)
#   nvidia-toolkit vfio-cleanup     Auto-detect and remove VFIO/passthrough leftovers
#   nvidia-toolkit snapshot         Save diagnostics to /root/
#
# If run with no args (e.g. via wget|bash), shows an interactive menu.
#
# Key safety goals:
# - Never edit VM config files directly (no sed on /etc/pve/qemu-server/*.conf)
# - Never hide qm errors (non-technical users must see failures)
# - Only create script-owned modprobe files (does not touch vfio.conf or other user files)
# - IOMMU kernel flags: only add missing tokens; revert removes only tokens it added
# - Revert removes only what this script added/changed
# - Driver install: APT only, Secure Boot check, kernel freshness check, Nouveau blacklist
# - Driver remove: lists packages first, provides recovery instructions
#
set -euo pipefail

# ======================= version =======================
SCRIPT_VERSION="3.0.0"

# ======================= global flags =======================
DRY_RUN=false
LOG_FILE="/var/log/nvidia-toolkit-$(date +%Y%m%d-%H%M%S).log"
LOCK_FILE="/var/run/nvidia-toolkit.lock"

# ======================= UI =======================
_log()  { echo -e "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
say()   { echo -e "\033[1;32m✔\033[0m $*";  _log "OK:   $*"; }
warn()  { echo -e "\033[1;33m⚠\033[0m $*" >&2; _log "WARN: $*"; }
err()   { echo -e "\033[1;31m✘\033[0m $*" >&2; _log "ERR:  $*"; }
die()   { err "$*"; exit 1; }
info()  { echo -e "\033[1;36mℹ\033[0m $*";  _log "INFO: $*"; }

prompt_yn() {
  local q="$1" default="${2:-n}"
  local hint="[y/N]"
  [[ "${default,,}" == "y" ]] && hint="[Y/n]"
  read -r -p "$q $hint: " ans
  ans="${ans:-$default}"
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

run_or_dry() {
  if $DRY_RUN; then
    info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

run_qm() {
  if $DRY_RUN; then
    info "[DRY-RUN] qm $*"
    return 0
  fi
  local rc=0
  qm "$@" || rc=$?
  if [[ $rc -ne 0 ]]; then
    err "Command failed (exit $rc): qm $*"
    return 1
  fi
}

# ======================= concurrency guard (flock-safe) =======================
acquire_lock() {
  # Graceful fallback if flock is not available (e.g., minimal containers)
  if ! has_cmd flock; then
    warn "flock not available — skipping concurrency guard."
    warn "Avoid running multiple instances simultaneously."
    return 0
  fi
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "Another instance of nvidia-toolkit is already running (lockfile: $LOCK_FILE)."
  fi
  _log "Lock acquired: $$"
}

release_lock() {
  if has_cmd flock; then
    flock -u 9 2>/dev/null || true
  fi
  rm -f "$LOCK_FILE" 2>/dev/null || true
}

# ======================= CLI parsing =======================
FILTERED_ARGS=()
parse_global_flags() {
  local filtered=()
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      *) filtered+=("$arg") ;;
    esac
  done
  FILTERED_ARGS=("${filtered[@]+"${filtered[@]}"}")
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

apt_install_if_missing lspci pciutils
apt_install_if_missing update-initramfs initramfs-tools

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
STATE_DIR="/var/lib/nvidia-toolkit"
STATE_FILE="$STATE_DIR/state.env"
TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STATE_DIR"

MODPROBE_VFIO="/etc/modprobe.d/nvidia-toolkit-vfio.conf"
MODPROBE_BL_NOUVEAU="/etc/modprobe.d/nvidia-toolkit-blacklist-nouveau.conf"
MODPROBE_BL_NVIDIA="/etc/modprobe.d/nvidia-toolkit-blacklist-nvidia.conf"

# Also detect legacy set-gpupass files for migration/cleanup
LEGACY_MODPROBE_FILES=(
  "/etc/modprobe.d/set-gpupass-vfio.conf"
  "/etc/modprobe.d/set-gpupass-blacklist-nouveau.conf"
  "/etc/modprobe.d/set-gpupass-blacklist-nvidia.conf"
)

# ======================= state helpers (safe parsing) =======================
_state_get() {
  local key="$1"
  if [[ ! -f "$STATE_FILE" ]]; then echo ""; return; fi
  sed -n "s/^${key}=\"\\(.*\\)\"$/\\1/p" "$STATE_FILE" | tail -1
}

load_state() {
  STATE_VERSION="$(_state_get STATE_VERSION)"
  STATE_CREATED_AT="$(_state_get STATE_CREATED_AT)"
  BOOT_METHOD="$(_state_get BOOT_METHOD)"
  IOMMU_FLAGS_ADDED="$(_state_get IOMMU_FLAGS_ADDED)"
  VFIO_MODULE_LINES_ADDED="$(_state_get VFIO_MODULE_LINES_ADDED)"
  GPU_PCI_FUNCS="$(_state_get GPU_PCI_FUNCS)"
  VM_OPTIMIZED_VMID="$(_state_get VM_OPTIMIZED_VMID)"
  VM_PREV_BIOS="$(_state_get VM_PREV_BIOS)"
  VM_PREV_MACHINE="$(_state_get VM_PREV_MACHINE)"
  VM_PREV_ARGS_PRESENT="$(_state_get VM_PREV_ARGS_PRESENT)"
  VM_PREV_ARGS_VALUE="$(_state_get VM_PREV_ARGS_VALUE)"
  DRIVER_INSTALLED_BY_US="$(_state_get DRIVER_INSTALLED_BY_US)"
}

write_state() {
  cat >"$STATE_FILE" <<EOF
# nvidia-toolkit state (auto-generated). Remove only via: nvidia-toolkit revert
STATE_VERSION="2"
STATE_CREATED_AT="${STATE_CREATED_AT:-$TS}"

BOOT_METHOD="${BOOT_METHOD:-}"
IOMMU_FLAGS_ADDED="${IOMMU_FLAGS_ADDED:-}"
VFIO_MODULE_LINES_ADDED="${VFIO_MODULE_LINES_ADDED:-}"
GPU_PCI_FUNCS="${GPU_PCI_FUNCS:-}"

VM_OPTIMIZED_VMID="${VM_OPTIMIZED_VMID:-}"
VM_PREV_BIOS="${VM_PREV_BIOS:-}"
VM_PREV_MACHINE="${VM_PREV_MACHINE:-}"
VM_PREV_ARGS_PRESENT="${VM_PREV_ARGS_PRESENT:-}"
VM_PREV_ARGS_VALUE="${VM_PREV_ARGS_VALUE:-}"

DRIVER_INSTALLED_BY_US="${DRIVER_INSTALLED_BY_US:-}"
EOF
}

ensure_state() {
  load_state
  [[ -f "$STATE_FILE" ]] || { STATE_CREATED_AT="$TS"; write_state; }
}

# ======================= safety checks =======================
check_boot_space() {
  local boot_mount="/boot"
  if mountpoint -q "$boot_mount" 2>/dev/null; then
    local avail_kb
    avail_kb="$(df -k "$boot_mount" | awk 'NR==2{print $4}')"
    if [[ -n "$avail_kb" ]] && (( avail_kb < 51200 )); then
      local avail_mb=$(( avail_kb / 1024 ))
      warn "/boot has only ${avail_mb}MB free (need ~50MB for initramfs rebuild)."
      warn "Consider removing old kernels: apt autoremove --purge"
      echo
      if ! prompt_yn "Continue anyway (risky)?"; then
        die "Aborted — free up /boot space first."
      fi
    fi
  fi
}

safe_update_initramfs() {
  check_boot_space
  run_or_dry update-initramfs -u
}

check_secure_boot() {
  if has_cmd mokutil; then
    local sb_state
    sb_state="$(mokutil --sb-state 2>/dev/null || echo "unknown")"
    if echo "$sb_state" | grep -qi "SecureBoot enabled"; then
      warn "Secure Boot is ENABLED."
      warn "Unsigned DKMS kernel modules (like nvidia) will fail to load."
      warn "Options:"
      warn "  1) Disable Secure Boot in BIOS/UEFI"
      warn "  2) Sign the kernel modules with a MOK key after install"
      echo
      if ! prompt_yn "Continue anyway?"; then
        die "Aborted — disable Secure Boot first."
      fi
    else
      say "Secure Boot is not enabled — OK."
    fi
  else
    info "mokutil not found — cannot check Secure Boot (proceeding)."
  fi
}

check_kernel_current() {
  local running installed
  running="$(uname -r)"
  installed="$(dpkg -l 'pve-kernel-*' 2>/dev/null \
    | awk '/^ii.*pve-kernel-[0-9]/{print $2}' \
    | sort -V | tail -1 || true)"

  if [[ -n "$installed" ]]; then
    local latest="${installed#pve-kernel-}"
    if [[ "$running" != "$latest" ]]; then
      warn "Running kernel ($running) differs from newest installed ($latest)."
      warn "Reboot into the new kernel BEFORE installing drivers is recommended."
      warn "Otherwise DKMS will build for the old kernel."
      echo
      if ! prompt_yn "Continue with current kernel anyway?"; then
        die "Aborted — reboot first, then re-run."
      fi
    else
      say "Running kernel matches latest installed."
    fi
  fi
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

iommu_active() {
  [[ -d /sys/kernel/iommu_groups ]] && \
    [[ -n "$(find /sys/kernel/iommu_groups -type l -maxdepth 3 2>/dev/null | head -1)" ]]
}

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

# Relaxed check: only returns true if the modules are actually loaded AND preventing
# the desired operation. For passthrough, we care about nvidia/nouveau. For driver-install,
# we only care about nouveau (nvidia being loaded means driver is already working).
host_has_nvidia_modules_loaded() {
  lsmod | awk '{print $1}' | grep -Eq '^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm|nouveau)$'
}

host_has_nouveau_loaded() {
  lsmod | awk '{print $1}' | grep -Eq '^nouveau$'
}

host_has_nvidia_kmod_loaded() {
  lsmod | awk '{print $1}' | grep -Eq '^nvidia$'
}

host_nvidia_userspace_present() {
  has_cmd nvidia-smi
}

host_nvidia_pkgs_installed() {
  dpkg -l 2>/dev/null | awk '$1=="ii"{print $2}' | grep -Eq \
    '^(pve-nvidia-driver|nvidia-driver|nvidia-headless|nvidia-kernel-dkms|cuda-drivers|cuda)$|^nvidia-'
}

host_driver_summary() {
  local pkgs="no" smi="no" mods="no" nouveau="no"
  host_nvidia_pkgs_installed && pkgs="yes"
  host_nvidia_userspace_present && smi="yes"
  host_has_nvidia_kmod_loaded && mods="yes"
  host_has_nouveau_loaded && nouveau="yes"
  echo "packages=${pkgs}, nvidia-smi=${smi}, nvidia_kmod=${mods}, nouveau=${nouveau}"
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

# ======================= APT source helpers =======================
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local bak="${f}.bak.${TS}"
  cp -a "$f" "$bak"
  info "Backed up $f → $bak"
}

enable_nonfree_apt_components() {
  info "Ensuring contrib/non-free/non-free-firmware APT components..."

  # deb822 format (Debian 12+)
  local f="/etc/apt/sources.list.d/debian.sources"
  if [[ -f "$f" ]]; then
    if grep -q "^Components:" "$f"; then
      local needs_update=false
      local current; current="$(grep '^Components:' "$f" | head -1)"
      for comp in contrib non-free non-free-firmware; do
        if ! echo "$current" | grep -qw "$comp"; then needs_update=true; break; fi
      done
      if $needs_update; then
        backup_file "$f"
        local new_components="$current"
        for comp in contrib non-free non-free-firmware; do
          if ! echo "$new_components" | grep -qw "$comp"; then
            new_components="$new_components $comp"
          fi
        done
        run_or_dry sed -i "0,/^Components:.*/{s/^Components:.*/$new_components/}" "$f"
        say "Updated $f: $new_components"
      else
        say "$f already has all required components."
      fi
    fi
  fi

  # Legacy format
  local f2="/etc/apt/sources.list"
  if [[ -f "$f2" ]] && grep -qE '^deb\s' "$f2" 2>/dev/null; then
    local changed=false tmpf; tmpf="$(mktemp)"
    while IFS= read -r line; do
      if [[ "$line" =~ ^deb[[:space:]] ]] && echo "$line" | grep -qw "main"; then
        local new_line="$line"
        for comp in contrib non-free non-free-firmware; do
          if ! echo "$new_line" | grep -qw "$comp"; then
            new_line="$new_line $comp"
            changed=true
          fi
        done
        echo "$new_line" >> "$tmpf"
      else
        echo "$line" >> "$tmpf"
      fi
    done < "$f2"
    if $changed; then
      backup_file "$f2"
      run_or_dry cp "$tmpf" "$f2"
      say "Updated $f2 with contrib/non-free/non-free-firmware."
    fi
    rm -f "$tmpf"
  fi
}

# ======================= Nouveau blacklist (for driver install) =======================
ensure_nouveau_blacklisted() {
  # Check if already blacklisted anywhere
  if grep -rq "blacklist nouveau" /etc/modprobe.d/ 2>/dev/null; then
    say "Nouveau already blacklisted."
    return 0
  fi

  info "Blacklisting nouveau driver..."
  local blfile="/etc/modprobe.d/nvidia-toolkit-blacklist-nouveau.conf"
  if $DRY_RUN; then
    info "[DRY-RUN] Would create $blfile and update initramfs"
    return 0
  fi
  cat > "$blfile" <<'CONF'
# Added by nvidia-toolkit — prevent nouveau from loading
blacklist nouveau
options nouveau modeset=0
CONF
  safe_update_initramfs
  say "Nouveau blacklisted + initramfs updated."
}

# ======================= IOMMU group isolation check =======================
check_iommu_group_isolation() {
  local addr="$1"
  local group_link="/sys/bus/pci/devices/${addr}/iommu_group"

  if [[ ! -L "$group_link" ]]; then
    warn "Could not determine IOMMU group for $addr."
    return 0
  fi

  local group_path; group_path="$(readlink -f "$group_link")"
  local group_num; group_num="$(basename "$group_path")"
  local non_gpu=()
  local dev
  for dev in "$group_path"/devices/*; do
    dev="$(basename "$dev")"
    local class; class="$(cat /sys/bus/pci/devices/"$dev"/class 2>/dev/null || echo "0x000000")"
    [[ "$class" == 0x0604* ]] && continue
    local prefix="${addr%.*}"
    [[ "$dev" == "${prefix}."* ]] && continue
    non_gpu+=("$dev")
  done

  if [[ ${#non_gpu[@]} -gt 0 ]]; then
    echo
    warn "IOMMU group $group_num contains non-GPU devices:"
    for d in "${non_gpu[@]}"; do
      echo "  - $d ($(lspci -s "${d#0000:}" 2>/dev/null | sed -E 's/^[0-9a-fA-F:.]+ //' || echo unknown))"
    done
    warn "Passthrough may require ACS override patch."
    echo
    if ! prompt_yn "Continue anyway?"; then
      die "Aborted due to IOMMU group isolation concern."
    fi
  else
    say "IOMMU group $group_num is clean."
  fi
}

# ======================= file helpers =======================
write_file_atomic() {
  local path="$1" tmp="${path}.tmp.$$"
  if $DRY_RUN; then
    info "[DRY-RUN] Would write to $path"
    cat >/dev/null
    return 0
  fi
  cat >"$tmp"
  mv "$tmp" "$path"
}

remove_exact_line_from_file() {
  local file="$1" line="$2"
  [[ -f "$file" ]] || return 0
  grep -qxF "$line" "$file" || return 0
  if $DRY_RUN; then
    info "[DRY-RUN] Would remove line '$line' from $file"
    return 0
  fi
  awk -v l="$line" '$0 != l' "$file" > "${file}.tmp.$$" && mv "${file}.tmp.$$" "$file"
}

# ======================= IOMMU kernel flags (tracked) =======================
cmdline_has_token() {
  local text="$1" token="$2"
  [[ " $text " == *" $token "* ]]
}

_sed_escape_replace() {
  printf '%s\n' "$1" | sed -e 's/[&\\/|]/\\&/g'
}

enable_iommu_kernel_flags_if_missing() {
  local tokens; tokens="$(iommu_flag_tokens_for_cpu)"
  [[ -n "$tokens" ]] || die "Unsupported CPU vendor; cannot determine IOMMU flags."

  local method; method="$(boot_method_detect)"
  BOOT_METHOD="$method"
  local changed=0 added_tokens=()

  if [[ "$method" == "systemd-boot" ]]; then
    local f="/etc/kernel/cmdline"
    [[ -f "$f" ]] || die "systemd-boot detected but /etc/kernel/cmdline not found."
    local cur; cur="$(cat "$f")"
    for t in $tokens; do
      if ! cmdline_has_token "$cur" "$t"; then
        cur="${cur} ${t}"; added_tokens+=("$t"); changed=1
      fi
    done
    if [[ $changed -eq 1 ]]; then
      write_file_atomic "$f" <<<"$(echo "$cur" | tr -s ' ' | sed 's/^ //;s/ $//')"
      run_or_dry proxmox-boot-tool refresh
      IOMMU_FLAGS_ADDED="${added_tokens[*]}"
      write_state
      say "Enabled IOMMU kernel flags: ${IOMMU_FLAGS_ADDED}"
    fi
  else
    local f="/etc/default/grub"
    [[ -f "$f" ]] || die "GRUB config not found at /etc/default/grub"
    local var line
    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
      var="GRUB_CMDLINE_LINUX_DEFAULT"
      line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f")"
    else
      var="GRUB_CMDLINE_LINUX"
      line="$(grep -E '^GRUB_CMDLINE_LINUX=' "$f" || true)"
      [[ -n "$line" ]] || die "No GRUB_CMDLINE_LINUX* line found."
    fi
    local cur_val; cur_val="$(echo "$line" | sed -E 's/^[A-Z0-9_]+=//;s/^"//;s/"$//')"
    local new_val="$cur_val"
    for t in $tokens; do
      if ! cmdline_has_token "$new_val" "$t"; then
        new_val="${new_val} ${t}"; added_tokens+=("$t"); changed=1
      fi
    done
    if [[ $changed -eq 1 ]]; then
      new_val="$(echo "$new_val" | tr -s ' ' | sed 's/^ //;s/ $//')"
      local escaped; escaped="$(_sed_escape_replace "$new_val")"
      run_or_dry sed -i -E "s|^${var}=\".*\"|${var}=\"${escaped}\"|" "$f"
      run_or_dry update-grub || true
      IOMMU_FLAGS_ADDED="${added_tokens[*]}"
      write_state
      say "Enabled IOMMU kernel flags: ${IOMMU_FLAGS_ADDED}"
    fi
  fi
  echo "$changed"
}

remove_iommu_kernel_flags_we_added() {
  ensure_state; load_state
  [[ -n "${IOMMU_FLAGS_ADDED:-}" ]] || { echo 0; return; }
  local method="${BOOT_METHOD:-}"; [[ -n "$method" ]] || method="$(boot_method_detect)"
  local tokens="$IOMMU_FLAGS_ADDED"

  if [[ "$method" == "systemd-boot" ]]; then
    local f="/etc/kernel/cmdline"
    local cur; cur="$(cat "$f")"
    for t in $tokens; do
      cur="$(echo " $cur " | sed -E "s/[[:space:]]${t}[[:space:]]/ /g" | sed 's/^ //;s/ $//')"
    done
    write_file_atomic "$f" <<<"$(echo "$cur" | tr -s ' ')"
    run_or_dry proxmox-boot-tool refresh
  else
    local f="/etc/default/grub"
    local var line
    if grep -qE '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f"; then
      var="GRUB_CMDLINE_LINUX_DEFAULT"; line="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$f")"
    else
      var="GRUB_CMDLINE_LINUX"; line="$(grep -E '^GRUB_CMDLINE_LINUX=' "$f" || true)"
      [[ -n "$line" ]] || die "No GRUB_CMDLINE_LINUX* line found."
    fi
    local cur_val; cur_val="$(echo "$line" | sed -E 's/^[A-Z0-9_]+=//;s/^"//;s/"$//')"
    local new_val="$cur_val"
    for t in $tokens; do
      new_val="$(echo " $new_val " | sed -E "s/[[:space:]]${t}[[:space:]]/ /g" | sed 's/^ //;s/ $//')"
    done
    new_val="$(echo "$new_val" | tr -s ' ' | sed 's/^ //;s/ $//')"
    local escaped; escaped="$(_sed_escape_replace "$new_val")"
    run_or_dry sed -i -E "s|^${var}=\".*\"|${var}=\"${escaped}\"|" "$f"
    run_or_dry update-grub || true
  fi
  IOMMU_FLAGS_ADDED=""; BOOT_METHOD="$method"; write_state
  echo 1
}

# ======================= VFIO host config (tracked) =======================
compute_ids_csv_for_funcs() {
  local funcs=("$@")
  local ids; ids="$(
    for f in "${funcs[@]}"; do
      lspci -Dnns "${f#0000:}" | awk -F'[][]' '{print $3}'
    done | sort -u | paste -sd, -
  )"
  [[ -n "$ids" ]] || die "Could not compute PCI IDs for: ${funcs[*]}"
  echo "$ids"
}

ensure_vfio_modules_boot() {
  ensure_state; load_state
  local f="/etc/modules"; touch "$f"
  local required_modules=(vfio vfio_pci vfio_iommu_type1)
  if modinfo vfio_virqfd &>/dev/null; then required_modules+=(vfio_virqfd); fi
  local added=() m
  for m in "${required_modules[@]}"; do
    if ! grep -qxF "$m" "$f" 2>/dev/null; then
      run_or_dry bash -c "echo '$m' >> '$f'" 2>/dev/null || true
      added+=("$m")
    fi
  done
  if [[ ${#added[@]} -gt 0 ]]; then
    VFIO_MODULE_LINES_ADDED="${added[*]}"; write_state; echo 1
  else
    echo 0
  fi
}

write_vfio_and_blacklist_files() {
  local funcs=("$@")
  local ids_csv; ids_csv="$(compute_ids_csv_for_funcs "${funcs[@]}")"

  write_file_atomic "$MODPROBE_VFIO" <<EOF
# managed by nvidia-toolkit — do not edit manually
options vfio-pci ids=${ids_csv} disable_vga=1
EOF

  write_file_atomic "$MODPROBE_BL_NOUVEAU" <<'EOF'
# managed by nvidia-toolkit — do not edit manually
blacklist nouveau
options nouveau modeset=0
EOF

  write_file_atomic "$MODPROBE_BL_NVIDIA" <<'EOF'
# managed by nvidia-toolkit — do not edit manually
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF

  say "VFIO binding: ids=${ids_csv}"
  say "Blacklisted: nvidia, nvidia_drm, nvidia_modeset, nvidia_uvm, nouveau"
}

remove_vfio_and_blacklist_files() {
  run_or_dry rm -f "$MODPROBE_VFIO" "$MODPROBE_BL_NOUVEAU" "$MODPROBE_BL_NVIDIA" || true
}

remove_vfio_module_lines_we_added() {
  ensure_state; load_state
  [[ -n "${VFIO_MODULE_LINES_ADDED:-}" ]] || { echo 0; return; }
  for m in $VFIO_MODULE_LINES_ADDED; do
    remove_exact_line_from_file "/etc/modules" "$m"
  done
  VFIO_MODULE_LINES_ADDED=""; write_state; echo 1
}

# ======================= VM helpers =======================
prompt_vmid_menu() {
  local q="$1"
  mapfile -t MENU < <(qm list 2>/dev/null | tail -n +2 | while read -r vmid name status _; do
    [[ -n "$vmid" ]] && echo "$vmid|$name|$status"
  done)
  local clean=() entry
  for entry in "${MENU[@]}"; do [[ -n "$entry" ]] && clean+=("$entry"); done
  MENU=("${clean[@]+"${clean[@]}"}")
  echo >&2; echo "$q" >&2

  if [[ ${#MENU[@]} -eq 0 ]]; then
    warn "No VMs found."; echo "__EXIT__"; return
  fi

  if [[ ${#MENU[@]} -eq 1 ]]; then
    local vmid rest name status
    vmid="${MENU[0]%%|*}"; rest="${MENU[0]#*|}"; name="${rest%%|*}"; status="${rest#*|}"
    echo "Only one VM: $vmid ($name) [$status]" >&2; echo >&2
    echo "0) Do nothing  F) Free/Unbind GPU  1) Assign to VM $vmid" >&2
    while true; do
      read -r -p "Choice: " pick; pick="${pick:-0}"
      case "${pick^^}" in 0) echo "__EXIT__"; return ;; F) echo "__FREE__"; return ;; 1) echo "$vmid"; return ;; *) warn "Enter 0, F, or 1." ;; esac
    done
  fi

  echo "  0) Do nothing  F) Free/Unbind GPU" >&2; echo >&2
  echo "  #  VMID   Status    Name" >&2
  echo "  -- -----  --------  -------------------------" >&2
  local i=1 row
  for row in "${MENU[@]}"; do
    local vmid rest name status
    vmid="${row%%|*}"; rest="${row#*|}"; name="${rest%%|*}"; status="${rest#*|}"
    printf "  %-2s %-5s  %-8s  %s\n" "$i" "$vmid" "$status" "$name" >&2
    i=$((i+1))
  done
  while true; do
    read -r -p "Choice (0, F, or 1-${#MENU[@]}): " pick; pick="${pick:-0}"
    case "${pick^^}" in 0) echo "__EXIT__"; return ;; F) echo "__FREE__"; return ;; esac
    [[ "$pick" =~ ^[0-9]+$ ]] || { warn "Enter a number."; continue; }
    (( pick >= 1 && pick <= ${#MENU[@]} )) || { warn "Out of range."; continue; }
    echo "${MENU[$((pick-1))]%%|*}"; return
  done
}

remove_from_vm_if_present() {
  local vmid="$1"; shift
  for addr in "$@"; do
    while read -r _ rest; do
      [[ -n "$rest" ]] || continue
      local key; key="$(echo "$rest" | awk -F: '{print $1}')"
      [[ -n "$key" ]] || continue
      warn "Removing $key from VM $vmid"
      run_qm set "$vmid" --delete "$key" || warn "Failed to remove $key from VM $vmid (continuing)"
    done < <(qm config "$vmid" 2>/dev/null | awk -v a="$addr" -v s="${addr#0000:}" '
      $1 ~ /^hostpci[0-9]+:/ && (index($0,a) || index($0,s)) {print "X " $0}')
  done
}

check_vm_machine_type() {
  local vmid="$1"
  local machine; machine="$(qm config "$vmid" 2>/dev/null | awk '/^machine:/{print $2}' || true)"
  local bios; bios="$(qm config "$vmid" 2>/dev/null | awk '/^bios:/{print $2}' || true)"

  if [[ -z "$machine" || "$machine" == *"i440fx"* ]]; then
    echo
    warn "VM $vmid uses i440fx machine type. q35 is recommended for PCIe passthrough."
    info "To change: qm set $vmid --machine q35"
    if [[ -z "$bios" || "$bios" != "ovmf" ]]; then
      warn "Also consider OVMF (UEFI): qm set $vmid --bios ovmf"
    fi
    echo
    if ! prompt_yn "Continue with i440fx anyway?"; then return 1; fi
  fi
  return 0
}

add_funcs_to_vm() {
  local vmid="$1"; shift; local funcs=("$@")
  check_vm_machine_type "$vmid" || return 1
  local used; used="$(qm config "$vmid" 2>/dev/null | awk -F: '/^hostpci[0-9]+:/{gsub("hostpci","",$1); print $1}' | sort -n | paste -sd, -)"
  local slots=() i
  for i in $(seq 0 9); do
    if ! echo ",$used," | grep -q ",$i,"; then slots+=("$i"); fi
  done
  local idx=0 f short
  for f in "${funcs[@]}"; do
    [[ ${#slots[@]} -gt $idx ]] || die "No free hostpci slots on VM $vmid."
    short="${f#0000:}"
    info "Adding $short to VM $vmid as hostpci${slots[$idx]}"
    run_qm set "$vmid" --"hostpci${slots[$idx]}" "${short},pcie=1" || return 1
    idx=$((idx+1))
  done
}

stop_vm_with_wait() {
  local vmid="$1" interval=3
  if ! vm_running "$vmid"; then say "VM $vmid already stopped."; return 0; fi

  local has_agent=0
  if qm config "$vmid" 2>/dev/null | grep -qE '^agent:.*1'; then
    info "Graceful shutdown VM $vmid..."
    if qm shutdown "$vmid" 2>/dev/null; then
      has_agent=1
      local waited=0
      while vm_running "$vmid" && (( waited < 30 )); do printf "."; sleep "$interval"; waited=$((waited+interval)); done; echo
    fi
  fi
  if vm_running "$vmid"; then
    [[ $has_agent -eq 0 ]] && info "No guest agent. Stopping VM $vmid..." || warn "Graceful timed out. Stopping..."
    qm stop "$vmid" 2>&1 || true
    local waited=0
    while vm_running "$vmid" && (( waited < 30 )); do printf "."; sleep "$interval"; waited=$((waited+interval)); done; echo
  fi
  if vm_running "$vmid"; then
    warn "Force-stopping VM $vmid..."; qm stop "$vmid" --forceStop 1 2>&1 || true
    local fw=0; while vm_running "$vmid" && (( fw < 15 )); do sleep 1; fw=$((fw+1)); done
    if vm_running "$vmid"; then err "Could not stop VM $vmid."; return 1; fi
  fi
  say "VM $vmid stopped."; sleep 2; return 0
}

start_vm_with_wait() {
  local vmid="$1"
  if vm_running "$vmid"; then warn "VM $vmid running. Stopping first..."; stop_vm_with_wait "$vmid" || return 1; fi
  info "Starting VM $vmid..."
  local out; if ! out="$(qm start "$vmid" 2>&1)"; then
    err "Failed to start VM $vmid."; echo "$out" >&2; echo
    echo "  Common causes: Missing EFI disk, IOMMU conflict, vfio-pci not bound, i440fx+pcie=1"
    info "Run: nvidia-toolkit snapshot"; return 1
  fi
  sleep 3
  if vm_running "$vmid"; then say "VM $vmid running!"; else warn "VM $vmid started but not detected as running."; fi
}

# ══════════════════════════════════════════════════════════════
#  MODE: driver-install (APT-based, no .run installer)
# ══════════════════════════════════════════════════════════════
mode_driver_install() {
  echo
  echo "═══════════════════════════════════"
  echo " NVIDIA Driver Install (APT)"
  echo "═══════════════════════════════════"
  echo

  host_has_any_nvidia_gpu || die "No NVIDIA GPU detected."

  local gpu; gpu="$(choose_gpu)"
  say "GPU: ${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
  info "Host driver: $(host_driver_summary)"

  # Check if driver is already working
  if host_nvidia_userspace_present && nvidia-smi >/dev/null 2>&1; then
    say "NVIDIA driver is already working."
    nvidia-smi --query-gpu=name,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null || nvidia-smi || true
    echo
    info "Nothing to do. Use 'driver-status' for full details."
    return 0
  fi

  # Check for VFIO conflicts — if GPU is bound to vfio-pci, driver install won't work
  local drv; drv="$(driver_in_use "$gpu" || echo "none")"
  if [[ "$drv" == "vfio-pci" ]]; then
    warn "GPU is currently bound to vfio-pci (passthrough mode)."
    warn "Host driver install requires the GPU to NOT be in passthrough."
    echo
    info "Options:"
    echo "  1) Run: nvidia-toolkit vfio-cleanup (to remove passthrough leftovers)"
    echo "  2) Run: nvidia-toolkit revert (to undo all passthrough config)"
    echo "  Then reboot and re-run: nvidia-toolkit driver-install"
    die "Cannot install host driver while GPU is bound to vfio-pci."
  fi

  # Pre-flight checks
  check_secure_boot
  check_kernel_current

  echo
  info "This will:"
  echo "  1) Enable Debian contrib/non-free/non-free-firmware APT components"
  echo "  2) Blacklist the nouveau driver"
  echo "  3) Install pve-headers + dkms + build-essential"
  echo "  4) Install nvidia-driver via APT"
  echo "  5) Verify DKMS module built correctly"
  echo
  if ! prompt_yn "Proceed?"; then say "No changes made."; return 0; fi

  enable_nonfree_apt_components
  run_or_dry apt-get update -y

  ensure_nouveau_blacklisted

  # Install prerequisites
  info "Installing build prerequisites..."
  local header_pkg="pve-headers-$(uname -r)"
  if ! apt-cache show "$header_pkg" >/dev/null 2>&1; then
    warn "Header package '$header_pkg' not found."
    warn "Try: apt-get update && apt-cache search pve-headers"
    die "Cannot continue without matching kernel headers."
  fi
  run_or_dry apt-get install -y "$header_pkg" dkms build-essential
  say "Prerequisites installed."

  # Install nvidia-driver
  info "Installing nvidia-driver via APT (this may take a few minutes)..."
  run_or_dry apt-get install -y nvidia-driver
  say "nvidia-driver installed."

  # Verify DKMS
  if ! $DRY_RUN; then
    info "Verifying DKMS module build..."
    local dkms_out; dkms_out="$(dkms status 2>/dev/null || true)"
    if echo "$dkms_out" | grep -i nvidia | grep -qi "installed"; then
      say "NVIDIA DKMS module built successfully."
      echo "$dkms_out" | grep -i nvidia | while IFS= read -r l; do echo "    $l"; done
    elif echo "$dkms_out" | grep -i nvidia | grep -qi "error\|fail"; then
      warn "NVIDIA DKMS module build FAILED."
      echo "$dkms_out" | grep -i nvidia
      warn "Check: /var/lib/dkms/nvidia/*/build/make.log"
      die "DKMS build failed."
    else
      info "DKMS status:"; echo "  $dkms_out"
    fi
  fi

  # Track in state
  ensure_state; load_state
  DRIVER_INSTALLED_BY_US="yes"; write_state

  echo
  echo "═════════════════════════════════════════════"
  echo "  Driver install complete!"
  echo "═════════════════════════════════════════════"
  echo
  echo "  Next: REBOOT, then verify with:"
  echo "    nvidia-smi"
  echo
  echo "  If something goes wrong:"
  echo "    dkms status"
  echo "    journalctl -b -k | grep -i nvidia"
  echo "    nvidia-toolkit driver-status"
  echo
  echo "  To undo this install:"
  echo "    nvidia-toolkit driver-remove"
  echo "═════════════════════════════════════════════"
  echo
  if prompt_yn "Reboot now?"; then
    info "Rebooting in 5 seconds (Ctrl+C to cancel)..."
    sleep 5; reboot
  fi
}

# ══════════════════════════════════════════════════════════════
#  MODE: driver-status (detailed diagnostics)
# ══════════════════════════════════════════════════════════════
mode_driver_status() {
  echo
  echo "═══════════════════════════════════"
  echo " NVIDIA Driver Status (detailed)"
  echo "═══════════════════════════════════"
  echo

  # GPU hardware
  echo "┌─ Hardware ─────────────────────────────────┐"
  mapfile -t GPUS < <(detect_nvidia_gpu_addrs)
  if [[ ${#GPUS[@]} -eq 0 ]]; then
    echo "  No NVIDIA GPU detected by lspci."
  else
    for g in "${GPUS[@]}"; do
      echo "  GPU: ${g#0000:} ($(gpu_model_for_addr "$g"))"
      local drv; drv="$(driver_in_use "$g" || echo "none")"
      echo "  Driver in use: $drv"
      mapfile -t FUNCS < <(sibling_functions "$g")
      for f in "${FUNCS[@]}"; do
        [[ "$f" == "$g" ]] && continue
        echo "  Sibling: ${f#0000:} → $(driver_in_use "$f" || echo "none")"
      done
    done
  fi
  echo "└────────────────────────────────────────────┘"
  echo

  # Kernel modules
  echo "┌─ Kernel Modules ──────────────────────────────┐"
  local mods; mods="$(lsmod | awk '{print $1}' | grep -iE '^(nvidia|nouveau|vfio)' | sort || echo "(none)")"
  echo "  Loaded: $mods"
  echo "└────────────────────────────────────────────────┘"
  echo

  # Packages
  echo "┌─ Installed Packages ──────────────────────────┐"
  local pkgs; pkgs="$(dpkg -l 2>/dev/null | awk '$1=="ii" && ($2 ~ /nvidia/ || $2 ~ /cuda/) {printf "  %-40s %s\n", $2, $3}')"
  if [[ -n "$pkgs" ]]; then echo "$pkgs"; else echo "  (none)"; fi
  echo "└────────────────────────────────────────────────┘"
  echo

  # nvidia-smi
  echo "┌─ nvidia-smi ──────────────────────────────────┐"
  if has_cmd nvidia-smi; then
    if nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=name,driver_version,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw --format=csv,noheader 2>/dev/null \
        | while IFS=, read -r name ver temp util mem_used mem_total power; do
          echo "  Model    : $name"
          echo "  Driver   : $ver"
          echo "  Temp     : $temp"
          echo "  GPU util : $util"
          echo "  Memory   : $mem_used / $mem_total"
          echo "  Power    : $power"
        done
      # Also show processes
      local procs; procs="$(nvidia-smi --query-compute-apps=pid,name,used_gpu_memory --format=csv,noheader 2>/dev/null || true)"
      if [[ -n "$procs" ]]; then
        echo "  GPU processes:"
        echo "$procs" | while IFS=, read -r pid name mem; do
          echo "    PID $pid: $name ($mem)"
        done
      fi
    else
      warn "  nvidia-smi found but failed to run."
      echo "  This usually means the driver is installed but not loaded (reboot needed?)."
    fi
  else
    echo "  nvidia-smi not found (driver not installed or not in PATH)."
  fi
  echo "└────────────────────────────────────────────────┘"
  echo

  # DKMS
  echo "┌─ DKMS Status ─────────────────────────────────┐"
  if has_cmd dkms; then
    local dkms_out; dkms_out="$(dkms status 2>/dev/null | grep -i nvidia || echo "  (no nvidia DKMS modules)")"
    echo "  $dkms_out"
  else
    echo "  dkms not installed"
  fi
  echo "└────────────────────────────────────────────────┘"
  echo

  # Blacklists
  echo "┌─ Modprobe Blacklists ─────────────────────────┐"
  local bl_files; bl_files="$(grep -rl 'blacklist nouveau\|blacklist nvidia' /etc/modprobe.d/ 2>/dev/null || true)"
  if [[ -n "$bl_files" ]]; then
    echo "$bl_files" | while IFS= read -r f; do
      echo "  $f:"
      grep -E 'blacklist|options.*modeset' "$f" | while IFS= read -r l; do echo "    $l"; done
    done
  else
    echo "  (no nvidia/nouveau blacklists found)"
  fi
  echo "└────────────────────────────────────────────────┘"
  echo

  # Secure boot
  echo "┌─ Secure Boot ─────────────────────────────────┐"
  if has_cmd mokutil; then
    echo "  $(mokutil --sb-state 2>/dev/null || echo "unknown")"
  else
    echo "  mokutil not available"
  fi
  echo "└────────────────────────────────────────────────┘"
}

# ══════════════════════════════════════════════════════════════
#  MODE: driver-remove (with recovery instructions)
# ══════════════════════════════════════════════════════════════
mode_driver_remove() {
  echo
  echo "═══════════════════════════════════"
  echo " NVIDIA Driver Remove"
  echo "═══════════════════════════════════"
  echo

  if ! host_has_any_nvidia_gpu; then
    say "No NVIDIA GPU detected."; return 0
  fi

  info "Current state: $(host_driver_summary)"
  echo

  local nvidia_pkgs
  nvidia_pkgs="$(dpkg -l 2>/dev/null | awk '$1=="ii" && ($2 ~ /^nvidia/ || $2 ~ /^pve-nvidia/ || $2 ~ /^cuda/) {print "  " $2}')"
  if [[ -z "$nvidia_pkgs" ]]; then
    say "No NVIDIA/CUDA packages found to remove."; return 0
  fi

  warn "The following packages will be PURGED:"
  echo "$nvidia_pkgs"
  echo
  warn "This will remove the NVIDIA driver from the host."
  echo

  # Recovery instructions BEFORE proceeding
  echo "┌─ RECOVERY INFO (save this!) ─────────────────────────┐"
  echo "│                                                       │"
  echo "│  If you need the driver back after removing:          │"
  echo "│    nvidia-toolkit driver-install                      │"
  echo "│                                                       │"
  echo "│  If the system fails to boot:                         │"
  echo "│    1. Boot into Proxmox recovery/advanced options     │"
  echo "│    2. apt-get purge 'nvidia*'                         │"
  echo "│    3. update-initramfs -u                             │"
  echo "│    4. reboot                                          │"
  echo "│                                                       │"
  echo "│  Log file: $LOG_FILE"
  echo "└───────────────────────────────────────────────────────┘"
  echo

  if ! prompt_yn "Proceed with driver removal?"; then
    say "No changes made."; return 0
  fi
  if ! prompt_yn "FINAL confirmation — purge NVIDIA driver packages?"; then
    say "No changes made."; return 0
  fi

  if $DRY_RUN; then
    info "[DRY-RUN] Would purge: nvidia*, pve-nvidia-driver*, cuda*"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || die "apt-get update failed."
  apt-get purge -y 'pve-nvidia-driver*' 'nvidia*' 'cuda*' 2>&1 || true
  apt-get autoremove -y 2>&1 || true

  safe_update_initramfs
  say "NVIDIA driver packages purged + initramfs updated."

  # Update state
  ensure_state; load_state
  DRIVER_INSTALLED_BY_US=""; write_state

  echo
  warn "REBOOT REQUIRED to complete removal."
  info "To re-install later: nvidia-toolkit driver-install"
}

# ══════════════════════════════════════════════════════════════
#  MODE: vfio-cleanup (auto-detect and remove passthrough leftovers)
# ══════════════════════════════════════════════════════════════
mode_vfio_cleanup() {
  echo
  echo "═══════════════════════════════════"
  echo " VFIO / Passthrough Cleanup"
  echo "═══════════════════════════════════"
  echo
  info "Scanning for passthrough leftovers..."
  echo

  local found_issues=0

  # 1. Check for script-owned modprobe files
  local mp_files=("$MODPROBE_VFIO" "$MODPROBE_BL_NOUVEAU" "$MODPROBE_BL_NVIDIA" "${LEGACY_MODPROBE_FILES[@]}")
  local orphan_mp=()
  for f in "${mp_files[@]}"; do
    if [[ -f "$f" ]]; then
      orphan_mp+=("$f")
      found_issues=1
    fi
  done

  # 2. Check for ANY vfio-pci modprobe config (not just ours)
  local external_vfio=()
  while IFS= read -r f; do
    local dominated=false
    for known in "${mp_files[@]}"; do [[ "$f" == "$known" ]] && dominated=true; done
    $dominated || external_vfio+=("$f")
  done < <(grep -rl 'vfio-pci' /etc/modprobe.d/ 2>/dev/null || true)

  # 3. Check for VFIO module entries in /etc/modules
  local vfio_in_modules=()
  for m in vfio vfio_pci vfio_iommu_type1 vfio_virqfd; do
    if grep -qxF "$m" /etc/modules 2>/dev/null; then
      vfio_in_modules+=("$m")
      found_issues=1
    fi
  done

  # 4. Check for GPU bound to vfio-pci
  local vfio_bound_gpus=()
  mapfile -t ALL_GPUS < <(detect_nvidia_gpu_addrs)
  for g in "${ALL_GPUS[@]}"; do
    mapfile -t FUNCS < <(sibling_functions "$g")
    for f in "${FUNCS[@]}"; do
      local drv; drv="$(driver_in_use "$f" || echo "none")"
      if [[ "$drv" == "vfio-pci" ]]; then
        vfio_bound_gpus+=("${f#0000:}")
        found_issues=1
      fi
    done
  done

  # 5. Check for NVIDIA blacklists (that would prevent driver loading)
  local nvidia_blacklists=()
  while IFS= read -r f; do
    nvidia_blacklists+=("$f")
    found_issues=1
  done < <(grep -rl 'blacklist nvidia$\|blacklist nvidia_drm\|blacklist nvidia_modeset' /etc/modprobe.d/ 2>/dev/null || true)

  # 6. Check state file
  local has_state=false
  if [[ -f "$STATE_FILE" ]]; then
    local tracked_flags; tracked_flags="$(_state_get IOMMU_FLAGS_ADDED)"
    local tracked_modules; tracked_modules="$(_state_get VFIO_MODULE_LINES_ADDED)"
    if [[ -n "$tracked_flags" || -n "$tracked_modules" ]]; then
      has_state=true
      found_issues=1
    fi
  fi

  # Report findings
  if [[ $found_issues -eq 0 ]] && [[ ${#external_vfio[@]} -eq 0 ]]; then
    say "No passthrough leftovers detected. System is clean."
    return 0
  fi

  echo "Found the following passthrough artifacts:"
  echo

  if [[ ${#orphan_mp[@]} -gt 0 ]]; then
    echo "  Modprobe config files (script-managed):"
    for f in "${orphan_mp[@]}"; do echo "    ✘ $f"; done
    echo
  fi

  if [[ ${#external_vfio[@]} -gt 0 ]]; then
    echo "  External VFIO modprobe configs (NOT managed by this script):"
    for f in "${external_vfio[@]}"; do echo "    ? $f"; done
    echo
  fi

  if [[ ${#vfio_in_modules[@]} -gt 0 ]]; then
    echo "  VFIO entries in /etc/modules:"
    for m in "${vfio_in_modules[@]}"; do echo "    ✘ $m"; done
    echo
  fi

  if [[ ${#vfio_bound_gpus[@]} -gt 0 ]]; then
    echo "  GPU functions currently bound to vfio-pci:"
    for g in "${vfio_bound_gpus[@]}"; do echo "    ✘ $g"; done
    info "  (These will unbind after reboot once configs are removed)"
    echo
  fi

  if [[ ${#nvidia_blacklists[@]} -gt 0 ]]; then
    echo "  NVIDIA driver blacklists (preventing host driver):"
    for f in "${nvidia_blacklists[@]}"; do echo "    ✘ $f"; done
    echo
  fi

  if $has_state; then
    echo "  Tracked state (IOMMU flags / modules added by script):"
    [[ -n "$tracked_flags" ]] && echo "    IOMMU flags: $tracked_flags"
    [[ -n "$tracked_modules" ]] && echo "    Modules: $tracked_modules"
    echo
  fi

  # ── Phase 1: Script-owned artifacts (safe to remove) ──────────────
  local has_own_artifacts=false
  [[ ${#orphan_mp[@]} -gt 0 || ${#vfio_in_modules[@]} -gt 0 || ${#nvidia_blacklists[@]} -gt 0 ]] && has_own_artifacts=true
  $has_state && has_own_artifacts=true

  if $has_own_artifacts; then
    echo "┌─ Phase 1: Script-managed artifacts (safe to remove) ─┐"
    [[ ${#orphan_mp[@]} -gt 0 ]] && for f in "${orphan_mp[@]}"; do echo "  ✘ $f"; done
    [[ ${#vfio_in_modules[@]} -gt 0 ]] && echo "  ✘ /etc/modules entries: ${vfio_in_modules[*]}"
    for f in "${nvidia_blacklists[@]}"; do
      if head -1 "$f" 2>/dev/null | grep -q 'nvidia-toolkit\|set-gpupass'; then
        echo "  ✘ $f (script-managed blacklist)"
      fi
    done
    $has_state && echo "  ✘ Tracked IOMMU/module state"
    echo "└────────────────────────────────────────────────────────┘"
    echo

    if prompt_yn "Remove script-managed artifacts?"; then
      for f in "${orphan_mp[@]}"; do
        run_or_dry rm -f "$f"; say "Removed $f"
      done
      for m in "${vfio_in_modules[@]}"; do
        remove_exact_line_from_file "/etc/modules" "$m"; say "Removed '$m' from /etc/modules"
      done
      for f in "${nvidia_blacklists[@]}"; do
        if head -1 "$f" 2>/dev/null | grep -q 'nvidia-toolkit\|set-gpupass'; then
          run_or_dry rm -f "$f"; say "Removed $f"
        fi
      done
      if $has_state; then
        remove_iommu_kernel_flags_we_added >/dev/null || true
        remove_vfio_module_lines_we_added >/dev/null || true
        say "Tracked IOMMU/module state cleaned up."
      fi
    else
      say "Skipped script-managed cleanup."
    fi
  fi

  # ── Phase 2: External VFIO configs (NOT ours — require explicit per-file confirm) ──
  # Also gather non-script-owned nvidia blacklists
  local external_blacklists=()
  for f in "${nvidia_blacklists[@]}"; do
    if ! head -1 "$f" 2>/dev/null | grep -q 'nvidia-toolkit\|set-gpupass'; then
      external_blacklists+=("$f")
    fi
  done

  local all_external=("${external_vfio[@]+"${external_vfio[@]}"}" "${external_blacklists[@]+"${external_blacklists[@]}"}")
  if [[ ${#all_external[@]} -gt 0 ]]; then
    echo
    echo "┌─ Phase 2: External configs (NOT managed by this script) ─┐"
    echo "│                                                           │"
    echo "│  These files were created by another tool or manually.    │"
    echo "│  They will NOT be removed unless you explicitly confirm   │"
    echo "│  each one individually.                                   │"
    echo "│                                                           │"
    echo "└───────────────────────────────────────────────────────────┘"
    echo

    for f in "${all_external[@]}"; do
      echo "  ┌─ $f"
      # Show full contents (these are usually 1-5 lines)
      sed 's/^/  │ /' "$f" 2>/dev/null || echo "  │ (could not read)"
      echo "  └─"
      echo
      warn "This file is NOT managed by nvidia-toolkit."
      warn "Removing it may affect other tools or manual configurations."
      echo
      if prompt_yn "  Delete $f? Type 'y' only if you are sure"; then
        run_or_dry rm -f "$f"
        say "Removed $f"
      else
        info "Kept $f (no changes)"
      fi
      echo
    done
  fi

  safe_update_initramfs
  say "initramfs rebuilt."

  echo
  warn "═══════════════════════════════════════════"
  warn " REBOOT REQUIRED"
  warn "═══════════════════════════════════════════"
  info "After reboot, GPU will no longer be bound to vfio-pci."
  info "You can then run: nvidia-toolkit driver-install"
}

# ══════════════════════════════════════════════════════════════
#  MODE: status (unified overview)
# ══════════════════════════════════════════════════════════════
mode_status() {
  echo
  echo "═══════════════════════════════════"
  echo " System Status"
  echo "═══════════════════════════════════"
  echo

  echo "  Host       : $(hostname) | $(uname -r)"
  echo "  CPU vendor : $(cpu_vendor || echo unknown)"
  echo "  Boot method: $(boot_method_detect)"
  echo "  IOMMU      : $(iommu_active && echo "ACTIVE ✔" || echo "NOT ACTIVE ✘")"
  echo "  Secure Boot: $(mokutil --sb-state 2>/dev/null | head -1 || echo "unknown")"
  echo

  # GPU summary (non-interactive)
  mapfile -t ALL_GPUS < <(detect_nvidia_gpu_addrs)
  if [[ ${#ALL_GPUS[@]} -eq 0 ]]; then
    echo "  NVIDIA GPU : none detected"
  else
    for g in "${ALL_GPUS[@]}"; do
      echo "  GPU: ${g#0000:} ($(gpu_model_for_addr "$g"))"
      mapfile -t FUNCS < <(sibling_functions "$g")
      for f in "${FUNCS[@]}"; do
        local drv marker=""
        drv="$(driver_in_use "$f" || echo "none")"
        [[ "$drv" == "vfio-pci" ]] && marker=" ← passthrough"
        [[ "$drv" == "nvidia" ]] && marker=" ← host driver"
        echo "    ${f#0000:} → $drv$marker"
      done

      if iommu_active; then
        local gl="/sys/bus/pci/devices/${g}/iommu_group"
        [[ -L "$gl" ]] && echo "    IOMMU group: $(basename "$(readlink -f "$gl")")"
      fi

      local any=0 assigns
      for f in "${FUNCS[@]}"; do
        assigns="$(find_vm_assignments_for_addr "$f" || true)"
        if [[ -n "$assigns" ]]; then any=1
          echo "$assigns" | awk '{vm=$1; $1=""; sub(/^ /,""); print "    VM " vm ": " $0}'
        fi
      done
      [[ $any -eq 0 ]] && echo "    (not assigned to any VM)"
    done
  fi

  echo
  echo "  Host driver: $(host_driver_summary)"
  if has_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    echo "  nvidia-smi : working ✔"
  else
    echo "  nvidia-smi : not working ✘"
  fi

  # Passthrough leftover scan (quick)
  local leftovers=0
  [[ -f "$MODPROBE_VFIO" ]] && leftovers=1
  [[ -f "$MODPROBE_BL_NVIDIA" ]] && leftovers=1
  for f in "${LEGACY_MODPROBE_FILES[@]}"; do [[ -f "$f" ]] && leftovers=1; done
  if [[ $leftovers -eq 1 ]]; then
    echo
    warn "  Passthrough config files detected. Run 'vfio-cleanup' to inspect/remove."
  fi

  echo
  if [[ -f "$STATE_FILE" ]]; then
    echo "  State file: $STATE_FILE"
  else
    echo "  State file: none"
  fi
}

# ══════════════════════════════════════════════════════════════
#  MODE: snapshot
# ══════════════════════════════════════════════════════════════
mode_snapshot() {
  local out="/root/gpu-snapshot-${TS}.txt"
  local gpu="" FUNCS=()
  if host_has_any_nvidia_gpu; then gpu="$(choose_gpu)"; mapfile -t FUNCS < <(sibling_functions "$gpu"); fi

  {
    echo "===== nvidia-toolkit snapshot v${SCRIPT_VERSION} ====="
    echo; echo "===== DATE ====="; date
    echo; echo "===== KERNEL ====="; uname -r
    echo; echo "===== CPU ====="; lscpu | grep -iE 'Vendor ID|Model name' || true
    echo; echo "===== BOOT ====="; boot_method_detect; echo "Cmdline: $(cat /proc/cmdline)"
    echo; echo "===== BOOT PARTITION ====="; df -h /boot 2>/dev/null || echo "(n/a)"
    echo; echo "===== SECURE BOOT ====="; mokutil --sb-state 2>/dev/null || echo "(n/a)"
    echo; echo "===== IOMMU GROUPS ====="; find /sys/kernel/iommu_groups -type l 2>/dev/null | sort -V || echo "(none)"
    echo; echo "===== HOST DRIVER ====="; echo "$(host_driver_summary)"
    has_cmd nvidia-smi && { echo; echo "===== nvidia-smi ====="; nvidia-smi 2>&1 || echo "(failed)"; }
    has_cmd dkms && { echo; echo "===== DKMS ====="; dkms status 2>&1 || true; }

    if [[ -n "$gpu" ]]; then
      echo; echo "===== GPU ====="; echo "${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
      echo; echo "===== GPU FUNCS ====="; for f in "${FUNCS[@]}"; do echo "${f#0000:} driver: $(driver_in_use "$f" || echo none)"; done
      echo; echo "===== IOMMU GROUP ====="; local gl="/sys/bus/pci/devices/${gpu}/iommu_group"
      [[ -L "$gl" ]] && ls "$(readlink -f "$gl")/devices/" 2>/dev/null || echo "(n/a)"
    fi

    echo; echo "===== MODULES ====="; lsmod | grep -iE 'nvidia|nouveau|vfio' || echo "(none)"
    echo; echo "===== MODPROBE FILES ====="; for ff in "$MODPROBE_VFIO" "$MODPROBE_BL_NOUVEAU" "$MODPROBE_BL_NVIDIA" "${LEGACY_MODPROBE_FILES[@]}"; do
      [[ -f "$ff" ]] && { echo "--- $ff ---"; cat "$ff"; } || echo "(missing) $ff"
    done
    echo; echo "===== /etc/modules ====="; cat /etc/modules 2>/dev/null || true
    echo; echo "===== VM hostpci ====="; local vm lines found=0; for vm in $(list_vms); do
      lines="$(qm config "$vm" 2>/dev/null | grep -E '^hostpci[0-9]+:|^machine:' || true)"
      [[ -n "$lines" ]] && { echo "VM $vm:"; echo "$lines"; found=1; }
    done; [[ $found -eq 0 ]] && echo "(none)"
    echo; echo "===== NVIDIA PACKAGES ====="; dpkg -l 2>/dev/null | grep -iE 'nvidia|cuda' || echo "(none)"
    echo; echo "===== STATE ====="; [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "(none)"
  } >"$out" 2>&1

  say "Snapshot saved: $out"
  info "Share this file for troubleshooting."
}

# ══════════════════════════════════════════════════════════════
#  MODE: enable (passthrough)
# ══════════════════════════════════════════════════════════════
mode_enable() {
  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  echo
  echo "═══════════════════════════════════"
  echo " GPU Passthrough — Enable"
  echo "═══════════════════════════════════"
  echo
  say "GPU: ${gpu#0000:} ($(gpu_model_for_addr "$gpu"))"
  info "Functions: ${FUNCS[*]}"
  info "Host driver: $(host_driver_summary)"

  # Relaxed check: only block if nvidia modules are loaded AND not in vfio mode.
  # If the user already has vfio-pci bound, that's fine — we're just adding config.
  if host_has_nvidia_modules_loaded; then
    local all_vfio=true
    for f in "${FUNCS[@]}"; do
      local drv; drv="$(driver_in_use "$f" || echo "none")"
      [[ "$drv" == "vfio-pci" ]] || all_vfio=false
    done
    if ! $all_vfio; then
      echo
      err "Host NVIDIA/nouveau kernel modules are loaded and GPU is not bound to vfio-pci."
      info "Options:"
      echo "  1) Run: nvidia-toolkit driver-remove (purge host driver, then reboot)"
      echo "  2) Run: nvidia-toolkit vfio-cleanup (if leftover from prior passthrough)"
      die "Cannot proceed while host is actively using the GPU."
    else
      info "GPU already bound to vfio-pci — proceeding to configure."
    fi
  fi

  echo
  info "This will:"
  echo "  1. Add IOMMU kernel flags (if missing)"
  echo "  2. Add VFIO modules to /etc/modules"
  echo "  3. Create modprobe configs to bind GPU to vfio-pci"
  echo "  4. Blacklist nvidia/nouveau on host"
  echo "  5. Rebuild initramfs"
  echo
  if ! prompt_yn "Proceed?"; then say "No changes made."; return 0; fi

  ensure_state; load_state
  GPU_PCI_FUNCS="${FUNCS[*]}"; write_state
  local changes=0

  local fc; fc="$(enable_iommu_kernel_flags_if_missing)"; [[ "$fc" == "1" ]] && changes=1

  if ! iommu_active; then
    if [[ "$fc" == "1" ]]; then
      warn "Reboot required to activate IOMMU."
      info "After reboot: nvidia-toolkit enable"
      exit 0
    fi
    err "IOMMU not active. Enable VT-d (Intel) or AMD-Vi in BIOS."
    die "IOMMU is not active."
  fi
  say "IOMMU active"

  check_iommu_group_isolation "$gpu"

  local mc; mc="$(ensure_vfio_modules_boot)"; [[ "$mc" == "1" ]] && changes=1

  local wrote=0
  [[ ! -f "$MODPROBE_VFIO" || ! -f "$MODPROBE_BL_NOUVEAU" || ! -f "$MODPROBE_BL_NVIDIA" ]] && wrote=1
  write_vfio_and_blacklist_files "${FUNCS[@]}"
  [[ "$wrote" == "1" ]] && changes=1

  safe_update_initramfs
  say "initramfs updated"

  echo
  if [[ $changes -eq 1 ]]; then
    warn "REBOOT REQUIRED, then run: nvidia-toolkit bind"
  else
    say "Host configured. Run: nvidia-toolkit bind"
  fi
}

# ══════════════════════════════════════════════════════════════
#  MODE: bind
# ══════════════════════════════════════════════════════════════
mode_bind() {
  iommu_active || die "IOMMU not active. Run: nvidia-toolkit enable"

  local gpu; gpu="$(choose_gpu)"
  mapfile -t FUNCS < <(sibling_functions "$gpu")

  echo
  echo "═══════════════════════════════════"
  echo " GPU Passthrough — Bind to VM"
  echo "═══════════════════════════════════"
  echo

  local all_vfio=1 f
  for f in "${FUNCS[@]}"; do
    local drv; drv="$(driver_in_use "$f" || echo "none")"
    [[ "$drv" != "vfio-pci" ]] && { all_vfio=0; warn "${f#0000:} bound to '$drv' not 'vfio-pci'."; }
  done
  if [[ $all_vfio -eq 0 ]]; then
    warn "Not all functions bound to vfio-pci. Did you enable + reboot?"
    prompt_yn "Continue anyway?" || die "Run 'nvidia-toolkit enable' first."
  else
    say "All GPU functions bound to vfio-pci."
  fi

  local raw_vms=() REF_VMS=()
  mapfile -t raw_vms < <(for f in "${FUNCS[@]}"; do find_vm_assignments_for_addr "$f" | awk '{print $1}'; done | sort -u)
  for v in "${raw_vms[@]}"; do [[ -n "$v" ]] && REF_VMS+=("$v"); done
  [[ ${#REF_VMS[@]} -gt 0 ]] && say "Currently assigned to: ${REF_VMS[*]}" || info "Not assigned to any VM."

  local target; target="$(prompt_vmid_menu "What do you want to do?")"
  [[ "$target" == "__EXIT__" ]] && { say "No changes."; return 0; }

  local vms_to_stop=() vms_were_running=() vmid
  for vmid in "${REF_VMS[@]}"; do vm_running "$vmid" && vms_to_stop+=("$vmid"); done
  if [[ "$target" != "__FREE__" && "$target" != "__EXIT__" ]] && vm_running "$target"; then
    local already=0; for vmid in "${vms_to_stop[@]+"${vms_to_stop[@]}"}"; do [[ "$vmid" == "$target" ]] && already=1; done
    [[ $already -eq 0 ]] && vms_to_stop+=("$target")
  fi

  if [[ ${#vms_to_stop[@]} -gt 0 ]]; then
    warn "Must stop VM(s): ${vms_to_stop[*]}"
    prompt_yn "Stop, apply, and restart?" || die "Stop VMs manually first."
    for vmid in "${vms_to_stop[@]}"; do
      stop_vm_with_wait "$vmid" || die "Could not stop VM $vmid."
      vms_were_running+=("$vmid")
    done
  fi

  if [[ "$target" == "__FREE__" ]]; then
    [[ ${#REF_VMS[@]} -eq 0 ]] && { say "GPU already free."; return 0; }
    for vmid in "${REF_VMS[@]}"; do remove_from_vm_if_present "$vmid" "${FUNCS[@]}"; done
    say "GPU freed."
    for vmid in "${vms_were_running[@]}"; do start_vm_with_wait "$vmid" || warn "Could not restart VM $vmid."; done
    return 0
  fi

  for vmid in "${REF_VMS[@]}"; do [[ "$vmid" == "$target" ]] && continue; remove_from_vm_if_present "$vmid" "${FUNCS[@]}"; done
  remove_from_vm_if_present "$target" "${FUNCS[@]}" || true
  add_funcs_to_vm "$target" "${FUNCS[@]}" || { warn "GPU assignment failed."; return 1; }

  say "GPU bound to VM $target!"

  local target_was_running=0
  for vmid in "${vms_were_running[@]+"${vms_were_running[@]}"}"; do [[ "$vmid" == "$target" ]] && target_was_running=1; done

  if [[ $target_was_running -eq 1 ]]; then
    start_vm_with_wait "$target" || warn "Could not start VM $target."
  else
    if prompt_yn "Start VM $target now?"; then start_vm_with_wait "$target"; else info "Start later: qm start $target"; fi
  fi

  for vmid in "${vms_were_running[@]+"${vms_were_running[@]}"}"; do
    [[ "$vmid" == "$target" ]] && continue
    info "Restarting VM $vmid..."; start_vm_with_wait "$vmid" || warn "Could not restart VM $vmid."
  done
  echo; info "Install NVIDIA drivers inside the VM."
}

# ══════════════════════════════════════════════════════════════
#  MODE: revert
# ══════════════════════════════════════════════════════════════
mode_revert() {
  ensure_state; load_state

  echo
  echo "═══════════════════════════════════"
  echo " Revert All Changes"
  echo "═══════════════════════════════════"
  echo
  warn "This will undo ONLY what this script added:"
  echo "  • Remove VFIO binding + blacklists"
  echo "  • Remove VFIO boot module lines"
  echo "  • Remove IOMMU kernel flags (if tracked)"
  echo "  • Rebuild initramfs"
  echo
  if ! prompt_yn "Proceed?"; then say "No changes."; return 0; fi

  if prompt_yn "Also remove GPU from all VMs?"; then
    local gpu; gpu="$(choose_gpu)"
    mapfile -t FUNCS < <(sibling_functions "$gpu")
    local raw_vms=() REF_VMS=()
    mapfile -t raw_vms < <(for f in "${FUNCS[@]}"; do find_vm_assignments_for_addr "$f" | awk '{print $1}'; done | sort -u)
    for v in "${raw_vms[@]}"; do [[ -n "$v" ]] && REF_VMS+=("$v"); done
    local vmid vms_to_stop=()
    for vmid in "${REF_VMS[@]}"; do vm_running "$vmid" && vms_to_stop+=("$vmid"); done
    if [[ ${#vms_to_stop[@]} -gt 0 ]]; then
      warn "Running VMs with GPU: ${vms_to_stop[*]}"
      if prompt_yn "Stop them?"; then
        for vmid in "${vms_to_stop[@]}"; do stop_vm_with_wait "$vmid" || die "Could not stop VM $vmid."; done
      else
        die "Cannot remove GPU from running VMs."
      fi
    fi
    for vmid in "${REF_VMS[@]}"; do remove_from_vm_if_present "$vmid" "${FUNCS[@]}"; done
    [[ ${#REF_VMS[@]} -gt 0 ]] && say "GPU removed from VMs."
  fi

  remove_vfio_and_blacklist_files; say "Removed VFIO configs."
  remove_vfio_module_lines_we_added >/dev/null || true
  remove_iommu_kernel_flags_we_added >/dev/null || true
  safe_update_initramfs; say "initramfs updated."

  echo
  warn "REBOOT RECOMMENDED"
  info "Then install host driver: nvidia-toolkit driver-install"

  load_state
  if [[ -z "${IOMMU_FLAGS_ADDED:-}" && -z "${VFIO_MODULE_LINES_ADDED:-}" ]]; then
    rm -f "$STATE_FILE" || true; rmdir "$STATE_DIR" 2>/dev/null || true; say "State cleared."
  else
    warn "State retained (some items remain)."
  fi
}

# ══════════════════════════════════════════════════════════════
#  MODE: passthrough (one-click)
# ══════════════════════════════════════════════════════════════
mode_passthrough() {
  echo
  echo "═══════════════════════════════════"
  echo " One-Click GPU Passthrough"
  echo "═══════════════════════════════════"
  echo
  host_has_any_nvidia_gpu || die "No NVIDIA GPU found."
  info "Host driver: $(host_driver_summary)"

  if host_has_nvidia_modules_loaded; then
    # Check if it's just nouveau or actual nvidia
    local all_vfio=true
    mapfile -t GPUS < <(detect_nvidia_gpu_addrs)
    for g in "${GPUS[@]}"; do
      mapfile -t FUNCS < <(sibling_functions "$g")
      for f in "${FUNCS[@]}"; do
        local drv; drv="$(driver_in_use "$f" || echo "none")"
        [[ "$drv" == "vfio-pci" ]] || all_vfio=false
      done
    done

    if ! $all_vfio; then
      warn "Host is using the NVIDIA GPU."
      echo "  1) Run: nvidia-toolkit driver-remove → reboot → re-run"
      echo "  2) Or purge now:"
      echo
      if prompt_yn "Run driver removal now?"; then
        mode_driver_remove
        warn "Reboot needed after driver removal."
        return 0
      fi
      die "Cannot continue while host is using the GPU."
    fi
  fi

  mode_enable
  if ! iommu_active; then return 0; fi
  echo
  if prompt_yn "Bind GPU to a VM now?"; then mode_bind; else info "Later: nvidia-toolkit bind"; fi
}

# ══════════════════════════════════════════════════════════════
#  Interactive menu
# ══════════════════════════════════════════════════════════════
interactive_menu() {
  echo
  echo "═════════════════════════════════════════════"
  echo "  nvidia-toolkit v${SCRIPT_VERSION}"
  echo "  NVIDIA Driver & GPU Passthrough for Proxmox"
  echo "═════════════════════════════════════════════"

  if host_has_any_nvidia_gpu; then
    info "NVIDIA GPU detected; $(host_driver_summary)"
  else
    info "No NVIDIA GPU detected"
  fi
  $DRY_RUN && warn "DRY-RUN MODE"

  while true; do
    echo
    echo "┌───── Driver (host GPU use) ──────────────────────┐"
    echo "│  1) driver-install  — install via APT (no .run)   │"
    echo "│  2) driver-status   — detailed driver diagnostics │"
    echo "│  3) driver-remove   — purge NVIDIA packages       │"
    echo "├───── Passthrough (VM GPU use) ───────────────────┤"
    echo "│  4) passthrough     — one-click enable + bind     │"
    echo "│  5) enable          — prepare host for passthrough│"
    echo "│  6) bind            — assign/free GPU to a VM     │"
    echo "│  7) revert          — undo all passthrough changes│"
    echo "├───── Utility ────────────────────────────────────┤"
    echo "│  8) status          — full system overview        │"
    echo "│  9) vfio-cleanup    — remove passthrough leftovers│"
    echo "│ 10) snapshot        — save diagnostics to /root/  │"
    echo "│  0) exit                                          │"
    echo "└──────────────────────────────────────────────────┘"
    echo
    read -r -p "Choose [0-10]: " choice
    case "${choice:-}" in
      1)  mode_driver_install ;;
      2)  mode_driver_status ;;
      3)  mode_driver_remove ;;
      4)  mode_passthrough ;;
      5)  mode_enable ;;
      6)  mode_bind ;;
      7)  mode_revert ;;
      8)  mode_status ;;
      9)  mode_vfio_cleanup ;;
      10) mode_snapshot ;;
      0|q|Q|exit) say "Goodbye."; exit 0 ;;
      *) warn "Enter 0-10." ;;
    esac
  done
}

# ══════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════
parse_global_flags "$@"
MODE="${FILTERED_ARGS[0]:-}"

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/nvidia-toolkit-${TS}.log"
_log "=== nvidia-toolkit v${SCRIPT_VERSION} | Mode: ${MODE:-interactive} | PID: $$ ==="
$DRY_RUN && _log "DRY-RUN mode"

acquire_lock
trap 'release_lock' EXIT

case "$MODE" in
  "")              interactive_menu ;;
  driver-install)  mode_driver_install ;;
  driver-status)   mode_driver_status ;;
  driver-remove)   mode_driver_remove ;;
  passthrough)     mode_passthrough ;;
  enable)          mode_enable ;;
  bind)            mode_bind ;;
  revert)          mode_revert ;;
  status)          mode_status ;;
  vfio-cleanup)    mode_vfio_cleanup ;;
  snapshot)        mode_snapshot ;;
  # Legacy aliases
  oneclick)        mode_passthrough ;;
  hostdriver)      mode_driver_remove ;;
  --version|-v)    echo "nvidia-toolkit v${SCRIPT_VERSION}" ;;
  --help|-h)
    cat <<EOF
Usage: nvidia-toolkit [--dry-run] [COMMAND]

Driver commands:
  driver-install    Install NVIDIA host driver via APT
  driver-status     Detailed driver diagnostics
  driver-remove     Purge NVIDIA driver packages (with recovery info)

Passthrough commands:
  passthrough       One-click: enable + bind GPU to VM
  enable            Configure host for GPU passthrough
  bind              Assign/switch/free GPU to a VM
  revert            Undo all passthrough changes

Utility commands:
  status            Full system overview
  vfio-cleanup      Detect and remove passthrough leftovers
  snapshot          Save diagnostics to /root/

Options:
  --dry-run         Preview changes without applying
  --help            Show this help
  --version         Show version

Run with no arguments for interactive menu.
EOF
    ;;
  *)
    err "Unknown command: $MODE"
    echo "Run 'nvidia-toolkit --help' for usage."
    exit 1
    ;;
esac
