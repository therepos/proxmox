#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/drivemount-setup.sh?$(date +%s))"
# Purpose: Mount a drive and optionally register as Proxmox storage
# =============================================================================

set -euo pipefail

# --- Helpers -----------------------------------------------------------------
# >>> ui-block (managed by scripts/sync-ui.sh — do not edit here) >>>
if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }
# <<< ui-block <<<

# Back-compat wrapper used within this script:
status_message() {
    case "$1" in
        success) ok "$2" ;;
        info)    info "$2" ;;
        *)       fail "$2" ;;   # error → print + exit
    esac
}

[[ $EUID -eq 0 ]] || status_message "error" "Run as root."
command -v pct &>/dev/null || status_message "error" "Not a Proxmox host."

# Detect OS disk (so we exclude it and its partitions)
OS_DISK=""
PV=$(pvs --noheadings -o pv_name 2>/dev/null | head -1 | xargs || true)
if [[ -n "$PV" ]]; then
    OS_DISK=$(echo "$PV" | sed -E 's|p?[0-9]+$||')
fi
if [[ -z "$OS_DISK" ]]; then
    ROOT_SRC=$(findmnt -no SOURCE /)
    PARENT=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | tail -1)
    [[ -n "$PARENT" ]] && OS_DISK="/dev/${PARENT}"
fi

echo ""
echo "================================================================"
echo "  Drive Mount Manager"
echo "================================================================"
echo ""

# Show existing managed mounts (Proxmox storage registered under /mnt)
MANAGED=$(awk '
    /^dir:/ { name=$2 }
    /^[[:space:]]+path/ {
        if (name && $2 ~ /^\/mnt\//) print name "|" $2
        name=""
    }
' /etc/pve/storage.cfg 2>/dev/null || true)

# Collect existing managed mounts (printed later, only if unmounting)
EXISTING_MAP=()
if [[ -n "$MANAGED" ]]; then
    while IFS='|' read -r name path; do
        [[ -z "$name" ]] && continue
        EXISTING_MAP+=("$path|$name")
    done <<< "$MANAGED"
fi

# Ask the action first
echo "What do you want to do?"
echo "  1) Mount a drive"
echo "  2) Unmount a drive"
echo "  q) Quit"
echo ""
read -p "Select: " action </dev/tty
echo ""

case "$action" in
    q|Q) exit 0 ;;
    2)
        # --- UNMOUNT FLOW ---
        if [[ ${#EXISTING_MAP[@]} -eq 0 ]]; then
            status_message "info" "No managed mounts to unmount."
            exit 0
        fi
        echo "Existing mounts:"
        e=1
        for entry in "${EXISTING_MAP[@]}"; do
            IFS='|' read -r path name <<< "$entry"
            size=$(df -h "$path" 2>/dev/null | awk 'NR==2 {print $2}')
            echo "  $e) $path ($size, storage '$name')"
            ((e++))
        done
        echo ""
        echo "  q) Quit"
        echo ""
        read -p "Select: " uchoice </dev/tty
        case "$uchoice" in
            q|Q) exit 0 ;;
            ''|*[!0-9]*) status_message "error" "Invalid choice." ;;
        esac
        idx=$((uchoice - 1))
        [[ $idx -lt 0 || $idx -ge ${#EXISTING_MAP[@]} ]] && status_message "error" "Invalid choice."
        IFS='|' read -r MNT_PATH STORAGE_NAME <<< "${EXISTING_MAP[$idx]}"

        echo ""
        read -p "Type 'yes' to unmount and remove ${MNT_PATH}: " confirm </dev/tty
        [[ "$confirm" != "yes" ]] && { status_message "info" "Cancelled."; exit 0; }
        pvesm remove "$STORAGE_NAME" 2>/dev/null || true
        umount "$MNT_PATH" || status_message "error" "Unmount failed (in use?)"
        sed -i "\|${MNT_PATH}|d" /etc/fstab
        rmdir "$MNT_PATH" 2>/dev/null || true
        status_message "success" "Unmounted and cleaned up"
        exit 0
        ;;
    1) : ;;  # fall through to mount flow below
    *) status_message "error" "Invalid choice." ;;
esac

# --- MOUNT FLOW --------------------------------------------------------------
# Scan for unmounted drives, filtered for sanity
echo "Available drives to mount:"
echo ""

MAP=()
i=1
FOUND=0
while IFS= read -r line; do
    DEV=$(echo "$line" | awk '{print $1}')
    FSTYPE=$(echo "$line" | awk '{print $2}')
    SIZE=$(echo "$line" | awk '{print $3}')

    # Filter rules
    [[ "$DEV" == /dev/mapper/* ]] && continue
    [[ -n "$OS_DISK" && "$DEV" == "$OS_DISK"* ]] && continue
    [[ -z "$FSTYPE" ]] && continue
    [[ "$FSTYPE" == "LVM2_member" ]] && continue
    [[ "$FSTYPE" == "swap" ]] && continue

    echo "  $i) $DEV   $FSTYPE   $SIZE"
    MAP+=("$DEV|$FSTYPE")
    ((i++))
    FOUND=1
done < <(lsblk -pnlo NAME,FSTYPE,SIZE,MOUNTPOINT | awk '$4 == ""')

if [[ $FOUND -eq 0 ]]; then
    echo "  (none)"
fi

echo ""
echo "  q) Quit"
echo ""
read -p "Select: " choice </dev/tty

case "$choice" in
    q|Q) exit 0 ;;
    ''|*[!0-9]*) status_message "error" "Invalid choice." ;;
esac

idx=$((choice - 1))
[[ $idx -lt 0 || $idx -ge ${#MAP[@]} ]] && status_message "error" "Invalid choice."

IFS='|' read -r DEV FSTYPE <<< "${MAP[$idx]}"

echo ""
read -p "Enter mount point name (e.g. sec, media, data): " MNT_NAME </dev/tty
[[ -z "$MNT_NAME" ]] && status_message "error" "Required."
MNT_PATH="/mnt/${MNT_NAME}"

case "$FSTYPE" in
    ntfs) command -v ntfs-3g &>/dev/null || apt install -y -qq ntfs-3g >/dev/null ;;
    exfat) command -v mount.exfat-fuse &>/dev/null || apt install -y -qq exfat-fuse >/dev/null ;;
esac

mkdir -p "$MNT_PATH"
mount "$DEV" "$MNT_PATH" || status_message "error" "Mount failed."
AVAIL=$(df -h "$MNT_PATH" | awk 'NR==2 {print $4}')
status_message "success" "Mounted $DEV → $MNT_PATH (${AVAIL} available)"

UUID=$(blkid -s UUID -o value "$DEV")
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MNT_PATH $FSTYPE defaults,nofail,x-systemd.device-timeout=10 0 2" >> /etc/fstab
    systemctl daemon-reload
fi
status_message "success" "Added to fstab (auto-mount on boot)"

echo ""
read -p "Register as Proxmox storage (dump/ images/ private/ snippets/ template/)? [y/N]: " reg </dev/tty
REGISTERED=0
if [[ "$reg" =~ ^[Yy]$ ]]; then
    if ! grep -q "^dir: ${MNT_NAME}\b" /etc/pve/storage.cfg 2>/dev/null; then
        pvesm add dir "$MNT_NAME" --path "$MNT_PATH" \
            --content images,rootdir,vztmpl,iso,backup,snippets --shared 0 >/dev/null
        status_message "success" "Registered as Proxmox storage '$MNT_NAME'"
        REGISTERED=1
    fi
fi

echo ""
echo "================================================================"
status_message "success" "Done."
echo "================================================================"
echo "  Mount:    $MNT_PATH ($AVAIL)"
[[ $REGISTERED -eq 1 ]] && echo "  Storage:  '$MNT_NAME'"
