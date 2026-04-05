#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/vm-mountnfs.sh?$(date +%s))"
# Purpose: Setup or uninstall NFS mounts from Proxmox host to VM
# Usage:
#   bash -c "$(wget -qLO- ...)"
#   bash -c "$(wget -qLO- ...)" --install
#   bash -c "$(wget -qLO- ...)" --uninstall

set -e

HOST_IP="192.168.1.111"
MOUNTS=(
    "/mnt/sec/apps"
    "/mnt/sec/media"
)

check_mounts() {
    local found=0
    for MOUNT_PATH in "${MOUNTS[@]}"; do
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            local fstype
            fstype=$(findmnt -n -o FSTYPE "$MOUNT_PATH" 2>/dev/null)
            echo "  $MOUNT_PATH ($fstype)"
            found=1
        fi
    done
    return $((1 - found))
}

uninstall() {
    echo "=== Uninstalling mounts ==="
    for MOUNT_PATH in "${MOUNTS[@]}"; do
        # Unmount if mounted
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            echo "Unmounting $MOUNT_PATH..."
            sudo umount "$MOUNT_PATH"
        fi

        # Remove NFS fstab entries only
        if grep -q "$HOST_IP:.*$MOUNT_PATH.*nfs" /etc/fstab; then
            echo "Removing NFS fstab entry for $MOUNT_PATH..."
            sudo sed -i "\|$HOST_IP:.*$MOUNT_PATH.*nfs|d" /etc/fstab
        fi
    done

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

        # Add to fstab if not already there
        FSTAB_ENTRY="$HOST_IP:$MOUNT_PATH $MOUNT_PATH nfs defaults,_netdev,nofail 0 0"

        if grep -qF "$HOST_IP:$MOUNT_PATH" /etc/fstab; then
            echo "Updating existing fstab entry..."
            sudo sed -i "\|$HOST_IP:$MOUNT_PATH|c\\$FSTAB_ENTRY" /etc/fstab
        else
            echo "Adding to fstab for persistence..."
            echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
        fi
    done

    sudo systemctl daemon-reload

    echo ""
    echo "=== Setup complete ==="
    echo "All mounts configured and persisted in /etc/fstab"
}

# --- Main ---
echo "=== NFS Mount Manager ==="
echo ""

# Non-interactive mode via flags (checks both $0 and $1 for compatibility)
case "${1:-${0:-}}" in
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