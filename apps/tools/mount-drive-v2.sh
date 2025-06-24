#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/mount-drive-v2.sh?$(date +%s))"
# purpose: mounts a user-specified drive and updates fstab

# Colors for output
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"

function status_message() {
    local status=$1
    local message=$2
    [[ "$status" == "success" ]] && echo -e "$GREEN $message" || { echo -e "$RED $message"; exit 1; }
}

# Check for sudo if not running as root
if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        echo "sudo is not installed. Installing..."
        apt update && apt install -y sudo || status_message failure "Failed to install sudo."
    fi
fi

echo -e "\nScanning for unmounted drives...\n"

# List all unmounted partitions
MAP=()
i=1
while IFS= read -r line; do
    DEV=$(echo "$line" | awk '{print $1}')
    FSTYPE=$(echo "$line" | awk '{print $2}')
    SIZE=$(echo "$line" | awk '{print $3}')
    echo "$i) $DEV ($FSTYPE, $SIZE)"
    MAP+=("$DEV")
    ((i++))
done < <(lsblk -pnlo NAME,FSTYPE,SIZE,MOUNTPOINT | awk '$4 == "" && $2 != ""')

# Check if any unmounted drives were found
[[ ${#MAP[@]} -eq 0 ]] && status_message failure "No unmounted drives found."

# Prompt user to choose
read -rp $'\nSelect a drive to mount by number: ' CHOICE
SELECTED_DEV="${MAP[$((CHOICE - 1))]}"

[[ -z "$SELECTED_DEV" ]] && status_message failure "Invalid selection."

# Prompt for mount point name
read -rp "Enter mount point name (e.g., media, data): " MNT_NAME
MNT_PATH="/mnt/$MNT_NAME"

# Create mount point
mkdir -p "$MNT_PATH" || status_message failure "Could not create $MNT_PATH."

# Detect filesystem
FSTYPE=$(lsblk -no FSTYPE "$SELECTED_DEV")
[[ -z "$FSTYPE" ]] && status_message failure "Could not detect filesystem."

# Install necessary drivers if needed
case "$FSTYPE" in
    ntfs)
        if ! command -v ntfs-3g &>/dev/null; then
            echo "Installing ntfs-3g..."
            apt update && apt install -y ntfs-3g || status_message failure "Failed to install ntfs-3g."
        fi
        ;;
    exfat)
        if ! command -v mount.exfat-fuse &>/dev/null; then
            echo "Installing exfat drivers..."
            apt update && apt install -y exfat-fuse exfat-utils || status_message failure "Failed to install exfat support."
        fi
        ;;
    vfat)
        echo "VFAT detected. No additional drivers needed."
        ;;
    ext4)
        echo "EXT4 detected. Ready to mount."
        ;;
    *)
        status_message failure "Unsupported filesystem: $FSTYPE"
        ;;
esac

# Mount the drive
mount "$SELECTED_DEV" "$MNT_PATH" || status_message failure "Failed to mount $SELECTED_DEV."
status_message success "Mounted $SELECTED_DEV to $MNT_PATH."

# Ask to update fstab
read -rp "Update /etc/fstab for auto-mount on boot? (y/n): " DO_FSTAB
if [[ "$DO_FSTAB" =~ ^[Yy]$ ]]; then
    UUID=$(blkid -s UUID -o value "$SELECTED_DEV")
    [[ -z "$UUID" ]] && status_message failure "Failed to retrieve UUID."

    LINE="UUID=$UUID $MNT_PATH $FSTYPE defaults,nofail,x-systemd.device-timeout=10 0 2"
    grep -q "$UUID" /etc/fstab || echo "$LINE" >> /etc/fstab
    status_message success "fstab updated with: $LINE"
else
    echo "Skipped fstab update."
fi
