#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/vm-mountsmb.sh?$(date +%s))"
# Purpose: Setup or uninstall SMB/CIFS mounts from remote host to VM
# =============================================================================
# Usage:
#   bash -c "$(wget -qLO- ...)"
#   bash -c "$(wget -qLO- ...)" --install
#   bash -c "$(wget -qLO- ...)" --uninstall
# =============================================================================

set -e

HOST_IP="192.168.1.111"
SMB_USER="username"
SMB_PASS="password"
MOUNTS=(
    "mediadb:/mnt/sec/media"
)

check_mounts() {
    local found=0

    # Check live mounts for script-defined paths
    for ENTRY in "${MOUNTS[@]}"; do
        local MOUNT_PATH="${ENTRY#*:}"
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            local fstype
            fstype=$(findmnt -n -o FSTYPE "$MOUNT_PATH" 2>/dev/null)
            echo "  $MOUNT_PATH (mounted, $fstype)"
            found=1
        fi
    done

    # Also discover any cifs fstab entries for this host not already reported
    while IFS= read -r line; do
        local fstab_path
        fstab_path=$(echo "$line" | awk '{print $2}')
        # Skip if already reported above
        local already=0
        for ENTRY in "${MOUNTS[@]}"; do
            local MOUNT_PATH="${ENTRY#*:}"
            if [[ "$fstab_path" == "$MOUNT_PATH" ]]; then
                already=1
                break
            fi
        done
        if [[ "$already" -eq 0 ]]; then
            if mountpoint -q "$fstab_path" 2>/dev/null; then
                echo "  $fstab_path (mounted, from fstab)"
            else
                echo "  $fstab_path (fstab entry, not currently mounted)"
            fi
            found=1
        fi
    done < <(grep "//$HOST_IP/.*cifs" /etc/fstab 2>/dev/null || true)

    # Check script-defined paths that exist in fstab but aren't mounted
    for ENTRY in "${MOUNTS[@]}"; do
        local SHARE_NAME="${ENTRY%%:*}"
        local MOUNT_PATH="${ENTRY#*:}"
        if ! mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            if grep -q "//$HOST_IP/$SHARE_NAME" /etc/fstab 2>/dev/null; then
                echo "  $MOUNT_PATH (fstab entry, not currently mounted)"
                found=1
            fi
        fi
    done

    return $((1 - found))
}

uninstall() {
    echo "=== Uninstalling mounts ==="

    # Unmount all cifs shares from this host (live mounts)
    while IFS= read -r line; do
        local mount_path
        mount_path=$(echo "$line" | awk '{print $2}')
        if mountpoint -q "$mount_path" 2>/dev/null; then
            echo "Unmounting $mount_path..."
            sudo umount "$mount_path"
        fi
    done < <(grep "//$HOST_IP/.*cifs" /etc/fstab 2>/dev/null || true)

    # Also unmount script-defined paths in case fstab was already cleaned
    for ENTRY in "${MOUNTS[@]}"; do
        local MOUNT_PATH="${ENTRY#*:}"
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            echo "Unmounting $MOUNT_PATH..."
            sudo umount "$MOUNT_PATH"
        fi
    done

    # Check for any live cifs mounts from this host not in fstab
    while IFS= read -r line; do
        local mount_path
        mount_path=$(echo "$line" | awk '{print $3}')
        if [[ -n "$mount_path" ]] && mountpoint -q "$mount_path" 2>/dev/null; then
            echo "Unmounting live mount $mount_path..."
            sudo umount "$mount_path"
        fi
    done < <(mount | grep "//$HOST_IP/" 2>/dev/null || true)

    # Remove all cifs fstab entries for this host
    if grep -q "//$HOST_IP/.*cifs" /etc/fstab 2>/dev/null; then
        echo "Removing all SMB fstab entries for $HOST_IP..."
        sudo sed -i "\|//$HOST_IP/.*cifs|d" /etc/fstab
    fi

    # Remove cifs-utils if installed
    if dpkg -s cifs-utils &>/dev/null; then
        echo "Removing cifs-utils..."
        sudo apt remove -y cifs-utils
    fi

    sudo systemctl daemon-reload

    echo ""
    echo "=== Uninstall complete ==="
}

install() {
    echo "=== Setting up SMB mounts ==="

    # Install cifs-utils if not present
    if ! dpkg -s cifs-utils &>/dev/null; then
        echo "Installing cifs-utils..."
        sudo apt update && sudo apt install -y cifs-utils
    else
        echo "cifs-utils already installed"
    fi

    # Clean up any existing cifs entries for this host first
    if grep -q "//$HOST_IP/.*cifs" /etc/fstab 2>/dev/null; then
        echo "Cleaning existing fstab entries for $HOST_IP..."

        # Unmount any existing mounts from fstab
        while IFS= read -r line; do
            local old_path
            old_path=$(echo "$line" | awk '{print $2}')
            if mountpoint -q "$old_path" 2>/dev/null; then
                echo "  Unmounting $old_path..."
                sudo umount "$old_path"
            fi
        done < <(grep "//$HOST_IP/.*cifs" /etc/fstab 2>/dev/null || true)

        sudo sed -i "\|//$HOST_IP/.*cifs|d" /etc/fstab
    fi

    for ENTRY in "${MOUNTS[@]}"; do
        local SHARE_NAME="${ENTRY%%:*}"
        local MOUNT_PATH="${ENTRY#*:}"

        echo ""
        echo "--- //$HOST_IP/$SHARE_NAME -> $MOUNT_PATH ---"

        # Create mount point
        sudo mkdir -p "$MOUNT_PATH"

        # Unmount if already mounted
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            echo "Unmounting existing mount..."
            sudo umount "$MOUNT_PATH"
        fi

        # Mount the SMB share
        echo "Mounting //$HOST_IP/$SHARE_NAME to $MOUNT_PATH..."
        sudo mount -t cifs "//$HOST_IP/$SHARE_NAME" "$MOUNT_PATH" \
            -o username="$SMB_USER",password="$SMB_PASS",uid=1000,gid=1000,file_mode=0777,dir_mode=0777

        # Verify mount
        if mountpoint -q "$MOUNT_PATH"; then
            echo "Mount successful!"
            ls "$MOUNT_PATH" | head -10
        else
            echo "ERROR: Mount failed for $MOUNT_PATH"
            exit 1
        fi

        # Add to fstab
        FSTAB_ENTRY="//$HOST_IP/$SHARE_NAME $MOUNT_PATH cifs username=$SMB_USER,password=$SMB_PASS,uid=1000,gid=1000,file_mode=0777,dir_mode=0777,_netdev,nofail 0 0"
        echo "Adding to fstab for persistence..."
        echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    done

    sudo systemctl daemon-reload

    echo ""
    echo "=== Setup complete ==="
    echo "All mounts configured and persisted in /etc/fstab"
}

# --- Main ---
echo "=== SMB Mount Manager ==="
echo ""

# Non-interactive mode via flags
case "${1:-}" in
    --install)
        install
        exit 0
        ;;
    --uninstall)
        uninstall
        exit 0
        ;;
esac

# Interactive mode
if check_mounts; then
    echo ""
    echo "Existing mounts detected (shown above)."
    read -rp "Do you want to [u]ninstall or [r]einstall? (u/r): " choice
    case "$choice" in
        u|U)
            uninstall
            ;;
        r|R)
            install
            ;;
        *)
            echo "Cancelled."
            exit 0
            ;;
    esac
else
    echo "No existing mounts found."
    read -rp "Do you want to set up SMB mounts? (y/n): " choice
    case "$choice" in
        y|Y)
            install
            ;;
        *)
            echo "Cancelled."
            exit 0
            ;;
    esac
fi