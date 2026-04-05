#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/nfs-setup.sh?$(date +%s))"
# Purpose: Setup NFS server on Proxmox host or mount NFS shares in VM (PVE9/Ubuntu)
# =============================================================================
# Usage:
#   bash -c "$(wget -qLO- ...)"                                    # Interactive mode
#   bash -c "$(wget -qLO- ...)" --server-install                   # Install NFS server exports
#   bash -c "$(wget -qLO- ...)" --server-uninstall                 # Remove all NFS server exports
#   bash -c "$(wget -qLO- ...)" --server-uninstall /mnt/sec/apps   # Remove specific export
#   bash -c "$(wget -qLO- ...)" --client-install                   # Mount NFS shares in VM
#   bash -c "$(wget -qLO- ...)" --client-uninstall                 # Unmount all NFS shares
#   bash -c "$(wget -qLO- ...)" --client-uninstall /mnt/sec/media  # Unmount specific share
# =============================================================================

set -e

HOST_IP="192.168.1.111"
SUBNET="192.168.1.0/24"
EXPORTS=(
    "/mnt/sec/apps"
    "/mnt/sec/media"
)
MOUNTS=(
    "/mnt/sec/apps"
    "/mnt/sec/media"
)

# =============================================================================
# Server functions (run on Proxmox host)
# =============================================================================

check_server() {
    local found=0

    # Check if NFS server is running
    if systemctl is-active --quiet nfs-server 2>/dev/null; then
        echo "  NFS server: running"
        found=1
    fi

    # Check exports
    for EXPORT_PATH in "${EXPORTS[@]}"; do
        if grep -q "$EXPORT_PATH" /etc/exports 2>/dev/null; then
            echo "  Export: $EXPORT_PATH"
            found=1
        fi
    done

    # Check for any other exports for this subnet
    while IFS= read -r line; do
        local export_path
        export_path=$(echo "$line" | awk '{print $1}')
        local already=0
        for EXPORT in "${EXPORTS[@]}"; do
            if [[ "$export_path" == "$EXPORT" ]]; then
                already=1
                break
            fi
        done
        if [[ "$already" -eq 0 ]]; then
            echo "  Export: $export_path (additional)"
            found=1
        fi
    done < <(grep "$SUBNET" /etc/exports 2>/dev/null || true)

    return $((1 - found))
}

server_install() {
    echo "=== Setting up NFS server ==="

    # Install nfs-kernel-server if not present
    if ! dpkg -s nfs-kernel-server &>/dev/null; then
        echo "Installing nfs-kernel-server..."
        apt update && apt install -y nfs-kernel-server
    else
        echo "nfs-kernel-server already installed"
    fi

    for EXPORT_PATH in "${EXPORTS[@]}"; do
        echo ""
        echo "--- $EXPORT_PATH ---"

        # Create directory if it doesn't exist
        mkdir -p "$EXPORT_PATH"

        EXPORT_ENTRY="$EXPORT_PATH    $SUBNET(rw,sync,no_subtree_check,no_root_squash)"

        if grep -qF "$EXPORT_PATH" /etc/exports 2>/dev/null; then
            echo "Updating existing export entry..."
            sed -i "\|^$EXPORT_PATH |c\\$EXPORT_ENTRY" /etc/exports
        else
            echo "Adding export entry..."
            echo "$EXPORT_ENTRY" >> /etc/exports
        fi
    done

    # Apply exports
    exportfs -ra
    systemctl enable --now nfs-server

    echo ""
    echo "=== NFS server setup complete ==="
    echo "Active exports:"
    exportfs -v
}

server_uninstall() {
    local filter_paths=("$@")
    echo "=== Uninstalling NFS server ==="
    echo ""

    # Build list of all exports for this subnet
    local entries=()

    while IFS= read -r line; do
        local export_path
        export_path=$(echo "$line" | awk '{print $1}')
        if [[ -n "$export_path" ]]; then
            entries+=("$export_path")
        fi
    done < <(grep "$SUBNET" /etc/exports 2>/dev/null || true)

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "No NFS export entries found."
        return 0
    fi

    # Determine selected entries
    local selected=()

    if [[ ${#filter_paths[@]} -gt 0 ]]; then
        # Piped mode with specific paths
        for fp in "${filter_paths[@]}"; do
            local matched=0
            for entry in "${entries[@]}"; do
                if [[ "$entry" == "$fp" ]]; then
                    selected+=("$entry")
                    matched=1
                    break
                fi
            done
            if [[ "$matched" -eq 0 ]]; then
                echo "Warning: $fp not found in exports, skipping."
            fi
        done
    elif [[ ! -t 0 ]]; then
        # Piped mode without paths = all
        selected=("${entries[@]}")
    else
        # Interactive mode
        echo "Found NFS exports:"
        for i in "${!entries[@]}"; do
            echo "  $((i + 1))) ${entries[$i]}"
        done
        echo "  a) All"
        echo ""

        read -rp "Select exports to remove (e.g. 1, 1 3, or a): " selection

        if [[ "$selection" == "a" || "$selection" == "A" ]]; then
            selected=("${entries[@]}")
        else
            for num in $selection; do
                local idx=$((num - 1))
                if [[ $idx -ge 0 && $idx -lt ${#entries[@]} ]]; then
                    selected+=("${entries[$idx]}")
                else
                    echo "Invalid selection: $num"
                fi
            done
        fi
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "No valid entries selected. Cancelled."
        return 0
    fi

    echo ""

    # Remove selected exports
    for export_path in "${selected[@]}"; do
        if grep -q "^$export_path " /etc/exports 2>/dev/null; then
            echo "Removing export: $export_path"
            sed -i "\|^$export_path |d" /etc/exports
        fi
    done

    # Re-apply exports
    exportfs -ra

    # If no exports remain, stop and remove NFS server
    if [[ ! -s /etc/exports ]] || ! grep -q '[^[:space:]]' /etc/exports 2>/dev/null; then
        echo "No exports remaining. Stopping NFS server..."
        systemctl disable --now nfs-server 2>/dev/null || true

        if dpkg -s nfs-kernel-server &>/dev/null; then
            echo "Removing nfs-kernel-server..."
            apt remove -y nfs-kernel-server
        fi
    else
        echo "Other exports remain. NFS server kept running."
    fi

    echo ""
    echo "=== NFS server uninstall complete ==="
}

# =============================================================================
# Client functions (run on VM)
# =============================================================================

check_client() {
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

client_install() {
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
    echo "=== NFS mount setup complete ==="
    echo "All mounts configured and persisted in /etc/fstab"
}

client_uninstall() {
    local filter_paths=("$@")
    echo "=== Uninstalling NFS mounts ==="
    echo ""

    # Build list of all NFS entries for this host
    local entries=()
    local statuses=()

    # From fstab
    while IFS= read -r line; do
        local fstab_path
        fstab_path=$(echo "$line" | awk '{print $2}')
        if mountpoint -q "$fstab_path" 2>/dev/null; then
            entries+=("$fstab_path")
            statuses+=("mounted")
        else
            entries+=("$fstab_path")
            statuses+=("fstab entry, not currently mounted")
        fi
    done < <(grep "$HOST_IP:.*nfs" /etc/fstab 2>/dev/null || true)

    # From live mounts not in fstab
    while IFS= read -r line; do
        local live_path
        live_path=$(echo "$line" | awk '{print $3}')
        if [[ -n "$live_path" ]]; then
            local already=0
            for existing in "${entries[@]}"; do
                if [[ "$existing" == "$live_path" ]]; then
                    already=1
                    break
                fi
            done
            if [[ "$already" -eq 0 ]]; then
                entries+=("$live_path")
                statuses+=("mounted, no fstab entry")
            fi
        fi
    done < <(mount | grep "$HOST_IP:" 2>/dev/null || true)

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "No NFS entries found for $HOST_IP."
        return 0
    fi

    # Determine selected entries
    local selected=()

    if [[ ${#filter_paths[@]} -gt 0 ]]; then
        # Piped mode with specific paths
        for fp in "${filter_paths[@]}"; do
            local matched=0
            for entry in "${entries[@]}"; do
                if [[ "$entry" == "$fp" ]]; then
                    selected+=("$entry")
                    matched=1
                    break
                fi
            done
            if [[ "$matched" -eq 0 ]]; then
                echo "Warning: $fp not found in NFS entries, skipping."
            fi
        done
    elif [[ ! -t 0 ]]; then
        # Piped mode without paths = all
        selected=("${entries[@]}")
    else
        # Interactive mode
        echo "Found NFS entries for $HOST_IP:"
        for i in "${!entries[@]}"; do
            echo "  $((i + 1))) ${entries[$i]} (${statuses[$i]})"
        done
        echo "  a) All"
        echo ""

        read -rp "Select entries to uninstall (e.g. 1, 1 3, or a): " selection

        if [[ "$selection" == "a" || "$selection" == "A" ]]; then
            selected=("${entries[@]}")
        else
            for num in $selection; do
                local idx=$((num - 1))
                if [[ $idx -ge 0 && $idx -lt ${#entries[@]} ]]; then
                    selected+=("${entries[$idx]}")
                else
                    echo "Invalid selection: $num"
                fi
            done
        fi
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        echo "No valid entries selected. Cancelled."
        return 0
    fi

    echo ""

    # Unmount and remove selected entries
    for path in "${selected[@]}"; do
        if mountpoint -q "$path" 2>/dev/null; then
            echo "Unmounting $path..."
            sudo umount "$path"
        fi
        if grep -q "$HOST_IP:.*$path.*nfs" /etc/fstab 2>/dev/null; then
            echo "Removing fstab entry for $path..."
            sudo sed -i "\|$HOST_IP:.*$path.*nfs|d" /etc/fstab
        fi
    done

    sudo systemctl daemon-reload

    # Remove nfs-common only if all entries were removed
    if ! grep -q "$HOST_IP:.*nfs" /etc/fstab 2>/dev/null && \
       ! mount | grep -q "$HOST_IP:" 2>/dev/null; then
        if dpkg -s nfs-common &>/dev/null; then
            echo "No NFS mounts remaining. Removing nfs-common..."
            sudo apt remove -y nfs-common
        fi
    fi

    echo ""
    echo "=== NFS mount uninstall complete ==="
}

# =============================================================================
# Main
# =============================================================================

echo "=== NFS Setup Manager ==="
echo ""

# Non-interactive mode via flags
case "${1:-}" in
    --server-install)
        server_install
        exit 0
        ;;
    --server-uninstall)
        shift
        server_uninstall "$@"
        exit 0
        ;;
    --client-install)
        client_install
        exit 0
        ;;
    --client-uninstall)
        shift
        client_uninstall "$@"
        exit 0
        ;;
esac

# Interactive mode
echo "Where are you running this?"
echo "  1) Proxmox host (NFS server)"
echo "  2) VM (NFS client)"
read -rp "Select (1/2): " mode

case "$mode" in
    1)
        echo ""
        if check_server; then
            echo ""
            echo "Existing NFS server config detected (shown above)."
            read -rp "Do you want to [u]ninstall or [r]einstall? (u/r): " choice
            case "$choice" in
                u|U) server_uninstall ;;
                r|R) server_install ;;
                *) echo "Cancelled."; exit 0 ;;
            esac
        else
            echo "No NFS server config found."
            read -rp "Do you want to set up NFS server? (y/n): " choice
            case "$choice" in
                y|Y) server_install ;;
                *) echo "Cancelled."; exit 0 ;;
            esac
        fi
        ;;
    2)
        echo ""
        if check_client; then
            echo ""
            echo "Existing NFS mounts detected (shown above)."
            read -rp "Do you want to [u]ninstall or [r]einstall? (u/r): " choice
            case "$choice" in
                u|U) client_uninstall ;;
                r|R) client_install ;;
                *) echo "Cancelled."; exit 0 ;;
            esac
        else
            echo "No existing NFS mounts found."
            read -rp "Do you want to set up NFS mounts? (y/n): " choice
            case "$choice" in
                y|Y) client_install ;;
                *) echo "Cancelled."; exit 0 ;;
            esac
        fi
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac