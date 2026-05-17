#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/drivemount-setup.sh?$(date +%s))"
# Purpose: Mount drives, register as Proxmox storage, manage LXC bind mounts
# =============================================================================

set -euo pipefail

GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
YELLOW="\e[33m➜\e[0m"
RESET="\e[0m"

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

# Precheck
[[ $EUID -eq 0 ]] || status_message "error" "Must be run as root."
command -v pct &>/dev/null || status_message "error" "pct not found. Run on the Proxmox host."

# ===== Helpers =====

detect_os_disk() {
    local root_src
    root_src=$(findmnt -no SOURCE /)
    local os_disk=""
    if [[ "$root_src" == /dev/mapper/* ]]; then
        local vg pv
        vg=$(lvs --noheadings -o vg_name "$root_src" 2>/dev/null | tr -d ' ')
        pv=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$vg" '$2==vg {print $1; exit}')
        # strip partition suffix from PV path (e.g. /dev/nvme0n1p3 -> /dev/nvme0n1)
        os_disk=$(echo "$pv" | sed -E 's|p?[0-9]+$||')
    else
        local parent
        parent=$(lsblk -no PKNAME "$root_src" 2>/dev/null | tail -1)
        [[ -n "$parent" ]] && os_disk="/dev/${parent}"
    fi
    echo "$os_disk"
}

list_drives() {
    local os_disk
    os_disk=$(detect_os_disk)

    # Use a delimiter to preserve empty MOUNTPOINT field
    lsblk -pnlo NAME,FSTYPE,SIZE,MOUNTPOINT,UUID,TYPE -P | \
        while read -r line; do
            eval "$line"
            local dev="$NAME"
            local fstype="$FSTYPE"
            local size="$SIZE"
            local mountpoint="$MOUNTPOINT"
            local uuid="$UUID"
            local type="$TYPE"

            # Filter
            [[ "$type" != "part" && "$type" != "disk" ]] && continue
            [[ -n "$os_disk" && "$dev" == "$os_disk"* ]] && continue
            [[ -z "$fstype" ]] && continue
            [[ "$fstype" == "LVM2_member" ]] && continue
            [[ "$fstype" == "swap" ]] && continue

            # For whole disks, skip if it has partitions
            if [[ "$type" == "disk" ]]; then
                local part_count
                part_count=$(lsblk -nlo NAME "$dev" 2>/dev/null | wc -l)
                [[ "$part_count" -gt 1 ]] && continue
            fi

            echo "$dev $fstype $size $mountpoint $uuid"
        done
}

show_drives_menu() {
    MAP=()
    local i=1
    local found=0
    echo "Detected drives:"
    echo ""
    while IFS=' ' read -r dev fstype size mountpoint uuid; do
        [[ -z "$dev" ]] && continue
        local status_text
        if [[ -z "$mountpoint" ]]; then
            status_text="[NOT MOUNTED]"
        else
            local pve_storage
            pve_storage=$(grep -B1 "path ${mountpoint}\b" /etc/pve/storage.cfg 2>/dev/null | grep -oP '^\S+: \K\S+' | head -1)
            if [[ -n "$pve_storage" ]]; then
                status_text="-> ${mountpoint}   [MOUNTED + storage '${pve_storage}']"
            else
                status_text="-> ${mountpoint}   [MOUNTED]"
            fi
        fi
        printf "  %d) %-18s %-8s %-8s %s\n" "$i" "$dev" "$fstype" "$size" "$status_text"
        MAP+=("$dev|$fstype|$size|$mountpoint|$uuid")
        i=$((i + 1))
        found=1
    done < <(list_drives)

    if [[ $found -eq 0 ]]; then
        echo "  (no eligible drives found)"
    fi
    echo "  q) Quit"
    echo ""
}

bind_mount_into_lxc() {
    local ctid=$1
    local host_path=$2
    local mount_target=$3

    if pct config "$ctid" | grep -qE "^mp[0-9]+:.*${host_path//\//\\/}[, ]"; then
        status_message "info" "CTID $ctid already has $host_path bind-mounted"
        return
    fi

    local idx=0
    while pct config "$ctid" | grep -q "^mp${idx}:"; do
        idx=$((idx + 1))
    done

    pct set "$ctid" -mp${idx} "${host_path},mp=${mount_target}" >/dev/null
    pct reboot "$ctid" 2>/dev/null || pct start "$ctid" 2>/dev/null || true
    status_message "success" "Bind-mounted to CTID $ctid"
}

remove_bind_mount_from_lxc() {
    local ctid=$1
    local host_path=$2

    local mp_keys
    mp_keys=$(pct config "$ctid" | grep -oE "^mp[0-9]+" | tr -d ':' || true)
    local removed=0
    for key in $mp_keys; do
        local line
        line=$(pct config "$ctid" | grep "^${key}:" || true)
        if echo "$line" | grep -q "${host_path//\//\\/}[, ]"; then
            pct set "$ctid" --delete "$key" >/dev/null
            removed=1
        fi
    done
    if [[ $removed -eq 1 ]]; then
        pct reboot "$ctid" 2>/dev/null || true
        status_message "success" "Removed bind mount from CTID $ctid"
    else
        status_message "info" "CTID $ctid had no matching bind mount"
    fi
}

list_lxcs_inline() {
    pct list | awk 'NR>1 {printf "%s (%s), ", $1, $3}' | sed 's/, $//'
}

select_lxcs() {
    local ctids
    ctids=$(pct list | awk 'NR>1 {print $1}')
    if [[ -z "$ctids" ]]; then
        echo ""
        return
    fi

    echo "Found LXCs: $(list_lxcs_inline)"
    echo ""
    echo "  1) All"
    echo "  2) Select specific"
    echo "  3) None"
    echo ""
    read -p "Choice: " choice </dev/tty
    case "$choice" in
        1) echo "$ctids" ;;
        2)
            read -p "Select LXCs (comma-separated): " selected </dev/tty
            echo "$selected" | tr ',' '\n' | tr -d ' '
            ;;
        *) echo "" ;;
    esac
}

register_proxmox_storage() {
    local name=$1
    local path=$2

    if grep -q "^dir: ${name}\b" /etc/pve/storage.cfg 2>/dev/null; then
        status_message "info" "Storage '$name' already registered"
        return
    fi

    pvesm add dir "$name" \
        --path "$path" \
        --content images,rootdir,vztmpl,iso,backup,snippets \
        --shared 0 >/dev/null
    status_message "success" "Registered as Proxmox storage '$name' (Datacenter -> Storage -> $name)"
}

unregister_proxmox_storage() {
    local name=$1
    if grep -q "^dir: ${name}\b" /etc/pve/storage.cfg 2>/dev/null; then
        pvesm remove "$name" >/dev/null
        status_message "success" "Storage '$name' unregistered"
    fi
}

# ===== Actions =====

action_new_mount() {
    local dev=$1
    local fstype=$2
    local size=$3
    local uuid=$4

    echo ""
    if [[ -n "$fstype" ]]; then
        status_message "info" "$dev has existing data ($fstype)"
        echo ""
        echo "  1) Mount and keep data (recommended)"
        echo "  2) Wipe and reformat"
        echo "  3) Cancel"
        echo ""
        read -p "Choice: " op </dev/tty
    else
        echo "  1) Format as ext4 and mount"
        echo "  2) Cancel"
        echo ""
        read -p "Choice: " op </dev/tty
        [[ "$op" == "1" ]] && op="2"
    fi

    case "$op" in
        1) : ;;
        2)
            read -p "Type 'wipe' to confirm destruction of all data on $dev: " confirm </dev/tty
            [[ "$confirm" != "wipe" ]] && status_message "info" "Cancelled."
            wipefs -a "$dev" >/dev/null
            mkfs.ext4 -F "$dev" >/dev/null
            fstype="ext4"
            uuid=$(blkid -s UUID -o value "$dev")
            status_message "success" "Formatted $dev as ext4"
            ;;
        *) status_message "info" "Cancelled."; exit 0 ;;
    esac

    case "$fstype" in
        ntfs) command -v ntfs-3g &>/dev/null || apt install -y -qq ntfs-3g >/dev/null ;;
        exfat) command -v mount.exfat-fuse &>/dev/null || apt install -y -qq exfat-fuse >/dev/null ;;
    esac

    echo ""
    read -p "Enter mount point name (e.g. sec, media, data): " mnt_name </dev/tty
    [[ -z "$mnt_name" ]] && status_message "error" "Mount name required."
    local mnt_path="/mnt/${mnt_name}"

    mkdir -p "$mnt_path"
    mount "$dev" "$mnt_path" || status_message "error" "Mount failed."
    local avail
    avail=$(df -h "$mnt_path" | awk 'NR==2 {print $4}')
    status_message "success" "Mounted (${avail} available)"

    if ! grep -q "$uuid" /etc/fstab; then
        echo "UUID=${uuid} ${mnt_path} ${fstype} defaults,nofail,x-systemd.device-timeout=10 0 2" >> /etc/fstab
    fi
    status_message "success" "fstab updated"

    echo ""
    echo "Register as Proxmox storage? (usable for backups, ISOs, VM disks via UI)"
    echo ""
    echo "  1) Yes (recommended for primary data drives)"
    echo "  2) No, just mount"
    echo ""
    read -p "Choice: " reg </dev/tty
    if [[ "$reg" == "1" ]]; then
        register_proxmox_storage "$mnt_name" "$mnt_path"
    fi

    echo ""
    echo "Bind-mount ${mnt_path} into LXCs? (bind mounts apply only to LXCs, one at a time)"
    local selected
    selected=$(select_lxcs)
    if [[ -n "$selected" ]]; then
        for ctid in $selected; do
            bind_mount_into_lxc "$ctid" "$mnt_path" "$mnt_path"
        done
    fi

    echo ""
    echo "================================================================"
    status_message "success" "Setup complete."
    echo "================================================================"
    echo ""
    echo "  Mount:    ${mnt_path} (${avail})"
    [[ "$reg" == "1" ]] && echo "  Storage:  '${mnt_name}'"
    [[ -n "$selected" ]] && echo "  LXCs:     $(echo $selected | tr '\n' ' ')"
}

action_manage_existing() {
    local mount_path=$1
    local storage_name
    storage_name=$(grep -B1 "path ${mount_path}\b" /etc/pve/storage.cfg 2>/dev/null | grep -oP '^\S+: \K\S+' | head -1)

    echo ""
    echo "Manage ${mount_path}:"
    echo ""
    echo "  1) Add bind mount to LXC(s)"
    echo "  2) Remove bind mount from LXC(s)"
    echo "  3) Show current bind mounts"
    echo "  4) Unmount and unregister"
    echo "  5) Cancel"
    echo ""
    read -p "Choice: " op </dev/tty

    case "$op" in
        1)
            local selected
            selected=$(select_lxcs)
            for ctid in $selected; do
                bind_mount_into_lxc "$ctid" "$mount_path" "$mount_path"
            done
            ;;
        2)
            local selected
            selected=$(select_lxcs)
            for ctid in $selected; do
                remove_bind_mount_from_lxc "$ctid" "$mount_path"
            done
            ;;
        3)
            echo ""
            echo "LXCs with ${mount_path} bind-mounted:"
            local found=0
            for ctid in $(pct list | awk 'NR>1 {print $1}'); do
                if pct config "$ctid" | grep -qE "^mp[0-9]+:.*${mount_path//\//\\/}[, ]"; then
                    echo "  - CTID $ctid ($(pct config "$ctid" | grep -oP '^hostname: \K\S+'))"
                    found=1
                fi
            done
            [[ $found -eq 0 ]] && echo "  (none)"
            ;;
        4)
            read -p "Type 'yes' to unmount and unregister ${mount_path}: " confirm </dev/tty
            [[ "$confirm" != "yes" ]] && { status_message "info" "Cancelled."; exit 0; }
            for ctid in $(pct list | awk 'NR>1 {print $1}'); do
                remove_bind_mount_from_lxc "$ctid" "$mount_path" >/dev/null 2>&1 || true
            done
            [[ -n "$storage_name" ]] && unregister_proxmox_storage "$storage_name"
            umount "$mount_path" || status_message "error" "Failed to unmount (in use?)"
            sed -i "\|${mount_path}|d" /etc/fstab
            rmdir "$mount_path" 2>/dev/null || true
            status_message "success" "Unmounted and cleaned up"
            ;;
        *) status_message "info" "Cancelled." ;;
    esac
}

# ===== Menu =====

echo ""
echo "================================================================"
echo "  Drive Mount Manager"
echo "================================================================"
echo ""

show_drives_menu

read -p "Select a drive: " choice </dev/tty
echo ""

case "$choice" in
    q|Q) status_message "info" "Bye."; exit 0 ;;
    ''|*[!0-9]*) status_message "error" "Invalid choice." ;;
esac

idx=$((choice - 1))
if [[ $idx -lt 0 || $idx -ge ${#MAP[@]} ]]; then
    status_message "error" "Invalid choice."
fi

IFS='|' read -r dev fstype size mountpoint uuid <<< "${MAP[$idx]}"

if [[ -z "$mountpoint" ]]; then
    action_new_mount "$dev" "$fstype" "$size" "$uuid"
else
    action_manage_existing "$mountpoint"
fi