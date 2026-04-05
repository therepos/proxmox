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
    for ENTRY in "${MOUNTS[@]}"; do
        local MOUNT_PATH="${ENTRY#*:}"
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
    for ENTRY in "${MOUNTS[@]}"; do
        local SHARE_NAME="${ENTRY%%:*}"
        local MOUNT_PATH="${ENTRY#*:}"

        # Unmount if mounted
        if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
            echo "Unmounting $MOUNT_PATH..."
            sudo umount "$MOUNT_PATH"
        fi

        # Remove SMB/CIFS fstab entries only
        if grep -q "//$HOST_IP/$SHARE_NAME.*cifs" /etc/fstab; then
            echo "Removing SMB fstab entry for $MOUNT_PATH..."
            sudo sed -i "\|//$HOST_IP/$SHARE_NAME.*cifs|d" /etc/fstab
        fi
    done

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

        # Add to fstab if not already there
        FSTAB_ENTRY="//$HOST_IP/$SHARE_NAME $MOUNT_PATH cifs username=$SMB_USER,password=$SMB_PASS,uid=1000,gid=1000,file_mode=0777,dir_mode=0777,_netdev,nofail 0 0"

        if grep -qF "//$HOST_IP/$SHARE_NAME" /etc/fstab; then
            echo "Updating existing fstab entry..."
            sudo sed -i "\|//$HOST_IP/$SHARE_NAME|c\\$FSTAB_ENTRY" /etc/fstab
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
echo "=== SMB Mount Manager ==="
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