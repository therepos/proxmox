#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/drivemount-setup.sh?$(date +%s))"
# Purpose: Mount drives, register as Proxmox storage, manage LXC bind mounts

set -euo pipefail

GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
YELLOW="\e[33m➜\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    elif [[ "$status" == "info" ]]; then
        echo -e "${YELLOW} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

[[ $EUID -eq 0 ]] || status_message "error" "Must be run as root."
command -v pct &>/dev/null || status_message "error" "Not a Proxmox host."

# ===== Helpers =====

list_lxcs_inline() {
    pct list | awk 'NR>1 {printf "%s(%s) ", $1, $3}'
}

bind_mount_into_lxc() {
    local ctid=$1
    local host_path=$2

    if ! pct config "$ctid" &>/dev/null; then
        status_message "info" "CTID $ctid not found, skipping"
        return
    fi
    if pct config "$ctid" | grep -qE "^mp[0-9]+:.*${host_path//\//\\/}[, ]"; then
        status_message "info" "CTID $ctid already has $host_path"
        return
    fi
    local idx=0
    while pct config "$ctid" | grep -q "^mp${idx}:"; do
        idx=$((idx + 1))
    done
    pct set "$ctid" -mp${idx} "${host_path},mp=${host_path}" >/dev/null
    pct reboot "$ctid" 2>/dev/null || true
    status_message "success" "Bind-mounted to CTID $ctid"
}

remove_bind_mount_from_lxc() {
    local ctid=$1
    local host_path=$2

    local removed=0
    for key in $(pct config "$ctid" 2>/dev/null | grep -oE "^mp[0-9]+" | tr -d ':'); do
        if pct config "$ctid" | grep "^${key}:" | grep -q "${host_path//\//\\/}[, ]"; then
            pct set "$ctid" --delete "$key" >/dev/null
            removed=1
        fi
    done
    if [[ $removed -eq 1 ]]; then
        pct reboot "$ctid" 2>/dev/null || true
        status_message "success" "Removed from CTID $ctid"
    else
        status_message "info" "CTID $ctid had no matching bind mount"
    fi
}

ctids_with_mount() {
    local host_path=$1
    local result=""
    for ctid in $(pct list | awk 'NR>1 {print $1}'); do
        if pct config "$ctid" 2>/dev/null | grep -qE "^mp[0-9]+:.*${host_path//\//\\/}[, ]"; then
            result+="$ctid "
        fi
    done
    echo "$result" | xargs
}

# Find managed mounts (Proxmox dir-type storage we registered, under /mnt)
list_managed_mounts() {
    awk '
        /^dir:/ { name=$2 }
        /^[[:space:]]+path/ {
            if (name && $2 ~ /^\/mnt\//) print name "|" $2
            name=""
        }
    ' /etc/pve/storage.cfg 2>/dev/null
}

# ===== Main menu =====

echo ""
echo "================================================================"
echo "  Drive Mount Manager"
echo "================================================================"
echo ""

MAP=()
i=1

# Existing managed mounts
MANAGED=$(list_managed_mounts)
if [[ -n "$MANAGED" ]]; then
    echo "Existing managed mounts:"
    while IFS='|' read -r name path; do
        [[ -z "$name" ]] && continue
        ctids=$(ctids_with_mount "$path")
        if [[ -n "$ctids" ]]; then
            echo "  $i) $path (storage '$name', bind-mounted to: $ctids)"
        else
            echo "  $i) $path (storage '$name')"
        fi
        MAP+=("MANAGE|$path|$name")
        ((i++))
    done <<< "$MANAGED"
    echo ""
fi

# Unmounted drives
echo "Scanning for unmounted drives..."
echo ""
FOUND_DRIVES=0
while IFS= read -r line; do
    DEV=$(echo "$line" | awk '{print $1}')
    FSTYPE=$(echo "$line" | awk '{print $2}')
    SIZE=$(echo "$line" | awk '{print $3}')
    [[ "$FSTYPE" == "LVM2_member" || "$FSTYPE" == "swap" || -z "$FSTYPE" ]] && continue
    [[ "$DEV" == /dev/mapper/* ]] && continue
    echo "  $i) $DEV ($FSTYPE, $SIZE)"
    MAP+=("MOUNT|$DEV|$FSTYPE")
    ((i++))
    FOUND_DRIVES=1
done < <(lsblk -pnlo NAME,FSTYPE,SIZE,MOUNTPOINT | awk '$4 == ""')

[[ $FOUND_DRIVES -eq 0 ]] && echo "  (none)"
echo ""
echo "  q) Quit"
echo ""

read -p "Select: " choice </dev/tty
echo ""

case "$choice" in
    q|Q) exit 0 ;;
    ''|*[!0-9]*) status_message "error" "Invalid choice." ;;
esac

idx=$((choice - 1))
[[ $idx -lt 0 || $idx -ge ${#MAP[@]} ]] && status_message "error" "Invalid choice."

IFS='|' read -r ACTION ARG1 ARG2 <<< "${MAP[$idx]}"

# ===== Action: Manage existing mount =====

if [[ "$ACTION" == "MANAGE" ]]; then
    MNT_PATH=$ARG1
    STORAGE_NAME=$ARG2

    echo "Manage ${MNT_PATH}:"
    echo ""
    echo "  1) Add bind mount to LXC(s)"
    echo "  2) Remove bind mount from LXC(s)"
    echo "  3) Show current bind mounts"
    echo "  4) Unmount and unregister"
    echo "  5) Cancel"
    echo ""
    read -p "Choice: " op </dev/tty
    echo ""

    case "$op" in
        1)
            echo "LXCs found: $(list_lxcs_inline)"
            read -p "Bind-mount into LXCs (comma-separated): " selected </dev/tty
            for ctid in $(echo "$selected" | tr ',' ' '); do
                ctid=$(echo "$ctid" | xargs)
                [[ -z "$ctid" ]] && continue
                bind_mount_into_lxc "$ctid" "$MNT_PATH"
            done
            ;;
        2)
            current=$(ctids_with_mount "$MNT_PATH")
            if [[ -z "$current" ]]; then
                status_message "info" "No LXCs have this mount."
                exit 0
            fi
            echo "Currently bind-mounted to: $current"
            read -p "Remove from LXCs (comma-separated): " selected </dev/tty
            for ctid in $(echo "$selected" | tr ',' ' '); do
                ctid=$(echo "$ctid" | xargs)
                [[ -z "$ctid" ]] && continue
                remove_bind_mount_from_lxc "$ctid" "$MNT_PATH"
            done
            ;;
        3)
            current=$(ctids_with_mount "$MNT_PATH")
            if [[ -n "$current" ]]; then
                echo "Bind-mounted to: $current"
            else
                echo "Not bind-mounted to any LXC."
            fi
            ;;
        4)
            read -p "Type 'yes' to unmount and unregister: " confirm </dev/tty
            [[ "$confirm" != "yes" ]] && { status_message "info" "Cancelled."; exit 0; }
            for ctid in $(pct list | awk 'NR>1 {print $1}'); do
                remove_bind_mount_from_lxc "$ctid" "$MNT_PATH" >/dev/null 2>&1 || true
            done
            pvesm remove "$STORAGE_NAME" >/dev/null 2>&1 || true
            umount "$MNT_PATH" || status_message "error" "Unmount failed (in use?)"
            sed -i "\|${MNT_PATH}|d" /etc/fstab
            rmdir "$MNT_PATH" 2>/dev/null || true
            status_message "success" "Unmounted and cleaned up"
            ;;
        *) status_message "info" "Cancelled." ;;
    esac
    exit 0
fi

# ===== Action: Mount new drive =====

DEV=$ARG1
FSTYPE=$ARG2

read -p "Mount point name (e.g. sec, media): " MNT_NAME </dev/tty
[[ -z "$MNT_NAME" ]] && status_message "error" "Required."
MNT_PATH="/mnt/${MNT_NAME}"

case "$FSTYPE" in
    ntfs) command -v ntfs-3g &>/dev/null || apt install -y -qq ntfs-3g >/dev/null ;;
    exfat) command -v mount.exfat-fuse &>/dev/null || apt install -y -qq exfat-fuse >/dev/null ;;
esac

mkdir -p "$MNT_PATH"
mount "$DEV" "$MNT_PATH" || status_message "error" "Mount failed."
AVAIL=$(df -h "$MNT_PATH" | awk 'NR==2 {print $4}')
status_message "success" "Mounted $DEV -> $MNT_PATH (${AVAIL})"

UUID=$(blkid -s UUID -o value "$DEV")
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MNT_PATH $FSTYPE defaults,nofail,x-systemd.device-timeout=10 0 2" >> /etc/fstab
    status_message "success" "fstab updated"
fi

echo ""
read -p "Register as Proxmox storage? [Y/n]: " reg </dev/tty
REGISTERED=0
if [[ ! "$reg" =~ ^[Nn]$ ]]; then
    if ! grep -q "^dir: ${MNT_NAME}\b" /etc/pve/storage.cfg 2>/dev/null; then
        pvesm add dir "$MNT_NAME" --path "$MNT_PATH" \
            --content images,rootdir,vztmpl,iso,backup,snippets --shared 0 >/dev/null
        status_message "success" "Registered as Proxmox storage '$MNT_NAME'"
        REGISTERED=1
    else
        status_message "info" "Storage '$MNT_NAME' already exists"
        REGISTERED=1
    fi
fi

CTIDS=$(pct list | awk 'NR>1 {print $1}')
SELECTED_LXCS=""
if [[ -n "$CTIDS" ]]; then
    echo ""
    echo "LXCs found: $(list_lxcs_inline)"
    read -p "Bind-mount $MNT_PATH into LXCs (comma-separated, blank to skip): " selected </dev/tty
    if [[ -n "$selected" ]]; then
        for ctid in $(echo "$selected" | tr ',' ' '); do
            ctid=$(echo "$ctid" | xargs)
            [[ -z "$ctid" ]] && continue
            bind_mount_into_lxc "$ctid" "$MNT_PATH"
            SELECTED_LXCS+="$ctid "
        done
    fi
fi

echo ""
echo "================================================================"
status_message "success" "Done."
echo "================================================================"
echo "  Mount:    $MNT_PATH ($AVAIL)"
[[ $REGISTERED -eq 1 ]] && echo "  Storage:  '$MNT_NAME'"
[[ -n "$SELECTED_LXCS" ]] && echo "  LXCs:     $SELECTED_LXCS"