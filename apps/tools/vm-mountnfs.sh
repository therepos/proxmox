#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/vm-mountnfs.sh?$(date +%s))"
# Purpose: Setup or uninstall NFS mounts from Proxmox host to VM
# =============================================================================
# Usage:
#   bash -c "$(wget -qLO- ...)"
#   bash -c "$(wget -qLO- ...)" --install
#   bash -c "$(wget -qLO- ...)" --uninstall
# =============================================================================

set -e

HOST_IP="192.168.1.111"
MOUNTS=(
    "/mnt/sec/apps"
    "/mnt/sec/media"
)

check_mounts() {
    local found=0

    # Check live mounts for script-defined paths
    for MOUNT_PATH in "${MOUNTS[@]}"; do
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            local fstype
            fstype=$(findmnt -n -o FSTYPE "$MOUNT_PATH" 2>/dev/null)
            echo "  $MOUNT_PATH (mounted, $fstype)"
            found=1
        fi
    done

    # Discover any NFS fstab entries for this host not already reported
    while IFS= read -r line; do
        local fstab_path
        fstab_path=$(echo "$line" | awk '{print $2}')
        # Skip if already reported above
        local already=0
        for MOUNT_PATH in "${MOUNTS[@]}"; do
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
    done < <(grep "$HOST_IP:.*nfs" /etc/fstab 2>/dev/null || true)

    # Check script-defined paths that exist in fstab but aren't mounted
    for MOUNT_PATH in "${MOUNTS[@]}"; do
        if ! mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            if grep -q "$HOST_IP:$MOUNT_PATH" /etc/fstab 2>/dev/null; then
                echo "  $MOUNT_PATH (fstab entry, not currently mounted)"
                found=1
            fi
        fi
    done

    return $((1 - found))
}

uninstall() {
    echo "=== Uninstalling mounts ==="

    # Unmount all NFS shares from this host found in fstab
    while IFS= read -r line; do
        local mount_path
        mount_path=$(echo "$line" | awk '{print $2}')
        if mountpoint -q "$mount_path" 2>/dev/null; then
            echo "Unmounting $mount_path..."
            sudo umount "$mount_path"
        fi
    done < <(grep "$HOST_IP:.*nfs" /etc/fstab 2>/dev/null || true)

    # Also unmount script-defined paths in case fstab was already cleaned
    for MOUNT_PATH in "${MOUNTS[@]}"; do
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            echo "Unmounting $MOUNT_PATH..."
            sudo umount "$MOUNT_PATH"
        fi
    done

    # Check for any live NFS mounts from this host not in fstab
    while IFS= read -r line; do
        local mount_path
        mount_path=$(echo "$line" | awk '{print $3}')
        if [[ -n "$mount_path" ]] && mountpoint -q "$mount_path" 2>/dev/null; then
            echo "Unmounting live mount $mount_path..."
            sudo umount "$mount_path"
        fi
    done < <(mount | grep "$HOST_IP:" 2>/dev/null || true)

    # Remove all NFS fstab entries for this host
    if grep -q "$HOST_IP:.*nfs" /etc/fstab 2>/dev/null; then
        echo "Removing all NFS fstab entries for $HOST_IP..."
        sudo sed -i "\|$HOST_IP:.*nfs|d" /etc/fstab
    fi

    # Remove nfs-common if installed
    if dpkg -s nfs-common &>/dev/null; then
        echo "Removing nfs-common..."
        sudo apt remove -y nfs-common
    fi

    sudo systemctl daemon-reload

    echo ""
    echo "=== Uninstall complete ==="
}

install() {
    echo "=== Setting up NFS mounts ==="

    # Install nfs-common if not present
    if ! dpkg -s nfs-common &>/dev/null; then
        echo "Installing nfs-common..."
        sudo apt update && sudo apt install -y nfs-common
    else
        echo "nfs-common already installed"
    fi

    # Clean up any existing NFS entries for this host first
    if grep -q "$HOST_IP:.*nfs" /etc/fstab 2>/dev/null; then
        echo "Cleaning existing fstab entries for $HOST_IP..."

        # Unmount any existing mounts from fstab
        while IFS= read -r line; do
            local old_path
            old_path=$(echo "$line" | awk '{print $2}')
            if mountpoint -q "$old_path" 2>/dev/null; then
                echo "  Unmounting $old_path..."
                sudo umount "$old_path"
            fi
        done < <(grep "$HOST_IP:.*nfs" /etc/fstab 2>/dev/null || true)

        sudo sed -i "\|$HOST_IP:.*nfs|d" /etc/fstab
    fi

    for MOUNT_PATH in "${MOUNTS[@]}"; do
        echo ""
        echo "--- $HOST_IP:$MOUNT_PATH ---"

        # Create mount point
        sudo mkdir -p "$MOUNT_PATH"

        # Unmount if already mounted
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            echo "Unmounting existing mount..."
            sudo umount "$MOUNT_PATH"
        fi

        # Mount the NFS share
        echo "Mounting $HOST_IP:$MOUNT_PATH to $MOUNT_PATH..."
        sudo mount -t nfs "$HOST_IP:$MOUNT_PATH" "$MOUNT_PATH"

        # Verify mount
        if mountpoint -q "$MOUNT_PATH"; then
            echo "Mount successful!"
            ls "$MOUNT_PATH" | head -10
        else
            echo "ERROR: Mount failed for $MOUNT_PATH"
            exit 1
        fi

        # Add to fstab
        FSTAB_ENTRY="$HOST_IP:$MOUNT_PATH $MOUNT_PATH nfs defaults,_netdev,nofail 0 0"
        echo "Adding to fstab for persistence..."
        echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    done

    sudo systemctl daemon-reload

    echo ""
    echo "=== Setup complete ==="
    echo "All mounts configured and persisted in /etc/fstab"
}

# --- Main ---
echo "=== NFS Mount Manager ==="
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
    read -rp "Do you want to set up NFS mounts? (y/n): " choice
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