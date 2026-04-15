#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/smb-setup.sh?$(date +%s))"
# Purpose: Setup Samba server on Proxmox host or mount SMB/CIFS shares in VM
# =============================================================================
# Usage:
#   bash -c "$(wget -qLO- ...)"                                          # Interactive mode
#   bash -c "$(wget -qLO- ...)" --server-install                         # Install Samba server
#   bash -c "$(wget -qLO- ...)" --server-uninstall                       # Remove all Samba shares
#   bash -c "$(wget -qLO- ...)" --server-uninstall mediadb               # Remove specific share
#   bash -c "$(wget -qLO- ...)" --client-install                         # Mount SMB shares in VM
#   bash -c "$(wget -qLO- ...)" --client-uninstall                       # Unmount all SMB shares
#   bash -c "$(wget -qLO- ...)" --client-uninstall /mnt/sec/media        # Unmount specific share
# =============================================================================

set -e

HOST_IP="192.168.1.111"
SAMBA_GROUP="sambausers"
SAMBA_USERS=("toor")

# Server shares: "share_name:share_path"
SHARES=(
    "mediadb:/mnt/sec/media"
)

# Client mounts: "share_name:mount_path"
MOUNTS=(
    "mediadb:/mnt/sec/media"
)

SMB_USER="toor"
SMB_PASS="password"
SMB_CREDS_FILE="/etc/samba/.smbcreds"

# =============================================================================
# Server functions (run on Proxmox host)
# =============================================================================

check_server() {
    local found=0

    # Check if Samba is running
    if systemctl is-active --quiet smbd 2>/dev/null; then
        echo "  Samba server: running"
        found=1
    fi

    # Check for configured shares in smb.conf
    while IFS= read -r line; do
        local share_name
        share_name=$(echo "$line" | sed 's/[][]//g' | xargs)
        if [[ -n "$share_name" && "$share_name" != "global" && "$share_name" != "printers" && "$share_name" != "print$" ]]; then
            local share_path
            share_path=$(sed -n "/^\[$share_name\]/,/^\[/{ /path/s/.*= *//p; }" /etc/samba/smb.conf 2>/dev/null | head -1)
            echo "  Share: [$share_name] -> $share_path"
            found=1
        fi
    done < <(grep '^\[' /etc/samba/smb.conf 2>/dev/null || true)

    return $((1 - found))
}

server_install() {
    echo "=== Setting up Samba server ==="

    # Install samba if not present
    if ! dpkg -s samba &>/dev/null; then
        echo "Installing samba and dependencies..."
        apt update -y && apt install -y samba samba-common-bin acl
    else
        echo "Samba already installed"
    fi

    # Create samba group
    getent group "$SAMBA_GROUP" &>/dev/null || groupadd "$SAMBA_GROUP"
    echo "Group '$SAMBA_GROUP' ready."

    # Create users and samba credentials
    for u in "${SAMBA_USERS[@]}"; do
        id "$u" &>/dev/null || useradd -m "$u"
        echo "$u:$u" | chpasswd
        (echo "$u"; echo "$u") | smbpasswd -s -a "$u"
        usermod -aG "$SAMBA_GROUP" "$u"
        echo "User '$u' added to '$SAMBA_GROUP' and enabled for Samba."
    done

    # Backup existing config
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

    # Write global config
    cat >/etc/samba/smb.conf <<'GLOBAL_EOF'
[global]
   workgroup = WORKGROUP
   logging = file
   map to guest = bad user
   server role = standalone server
   vfs objects = acl_xattr
   map acl inherit = yes
   store dos attributes = yes
   server min protocol = SMB2
   server max protocol = SMB3
   load printers = no
   printing = bsd
   disable spoolss = yes
GLOBAL_EOF

    # Add each share
    for ENTRY in "${SHARES[@]}"; do
        local SHARE_NAME="${ENTRY%%:*}"
        local SHARE_PATH="${ENTRY#*:}"
        # FIX: use first samba user as owner to match force user in smb.conf
        local SHARE_OWNER="${SAMBA_USERS[0]}"

        echo ""
        echo "--- [$SHARE_NAME] -> $SHARE_PATH ---"

        # Create share directory with permissions
        mkdir -p "$SHARE_PATH"
        # FIX: chown to SAMBA_USERS[0] instead of root so ownership matches force user
        chown -R "$SHARE_OWNER":"$SAMBA_GROUP" "$SHARE_PATH"
        chmod -R 2775 "$SHARE_PATH"
        chmod g+s "$SHARE_PATH"

        # Set POSIX ACLs
        setfacl -R -m g:"$SAMBA_GROUP":rwX "$SHARE_PATH"
        setfacl -R -m d:g:"$SAMBA_GROUP":rwX "$SHARE_PATH"

        echo "Permissions and ACLs set on '$SHARE_PATH'."

        # Append share config
        # FIX: added force user to match filesystem ownership set above
        cat >>/etc/samba/smb.conf <<SHARE_EOF

[$SHARE_NAME]
   path = $SHARE_PATH
   browseable = yes
   read only = no
   guest ok = no
   create mask = 0664
   directory mask = 2775
   force create mode = 0664
   force directory mode = 2775
   inherit permissions = yes
   force group = $SAMBA_GROUP
   force user = $SHARE_OWNER
   valid users = @${SAMBA_GROUP}
   write list = @${SAMBA_GROUP}
SHARE_EOF
    done

    # Validate and restart
    testparm -s || { echo "ERROR: Samba config invalid"; exit 1; }
    systemctl enable --now smbd
    systemctl restart smbd

    local IP
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "=== Samba server setup complete ==="
    echo "Share ready: \\\\${IP}\\${SHARES[0]%%:*}"
    echo "Users: ${SAMBA_USERS[*]}"
}

server_uninstall() {
    local filter_names=("$@")
    echo "=== Uninstalling Samba server ==="
    echo ""

    # Build list of all shares from smb.conf
    local entries=()
    local paths=()

    while IFS= read -r line; do
        local share_name
        share_name=$(echo "$line" | sed 's/[][]//g' | xargs)
        if [[ -n "$share_name" && "$share_name" != "global" && "$share_name" != "printers" && "$share_name" != "print$" ]]; then
            local share_path
            share_path=$(sed -n "/^\[$share_name\]/,/^\[/{ /path/s/.*= *//p; }" /etc/samba/smb.conf 2>/dev/null | head -1)
            entries+=("$share_name")
            paths+=("$share_path")
        fi
    done < <(grep '^\[' /etc/samba/smb.conf 2>/dev/null || true)

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "No Samba shares found."
        return 0
    fi

    # Determine selected entries
    local selected=()

    if [[ ${#filter_names[@]} -gt 0 ]]; then
        # Piped mode with specific share names
        for fn in "${filter_names[@]}"; do
            local matched=0
            for i in "${!entries[@]}"; do
                if [[ "${entries[$i]}" == "$fn" ]]; then
                    selected+=("$i")
                    matched=1
                    break
                fi
            done
            if [[ "$matched" -eq 0 ]]; then
                echo "Warning: share '$fn' not found, skipping."
            fi
        done
    elif [[ ! -t 0 ]]; then
        # Piped mode without names = all
        for i in "${!entries[@]}"; do
            selected+=("$i")
        done
    else
        # Interactive mode
        echo "Found Samba shares:"
        for i in "${!entries[@]}"; do
            echo "  $((i + 1))) [${entries[$i]}] -> ${paths[$i]}"
        done
        echo "  a) All"
        echo ""

        read -rp "Select shares to remove (e.g. 1, 1 3, or a): " selection

        if [[ "$selection" == "a" || "$selection" == "A" ]]; then
            for i in "${!entries[@]}"; do
                selected+=("$i")
            done
        else
            for num in $selection; do
                local idx=$((num - 1))
                if [[ $idx -ge 0 && $idx -lt ${#entries[@]} ]]; then
                    selected+=("$idx")
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

    # Remove selected share sections from smb.conf
    for idx in "${selected[@]}"; do
        local share_name="${entries[$idx]}"
        echo "Removing share: [$share_name]"
        # Remove share section from config
        sed -i "/^\[$share_name\]/,/^\[/{/^\[/!d}" /etc/samba/smb.conf
        sed -i "/^\[$share_name\]/d" /etc/samba/smb.conf
    done

    # Check if any shares remain
    local remaining=0
    while IFS= read -r line; do
        local sn
        sn=$(echo "$line" | sed 's/[][]//g' | xargs)
        if [[ -n "$sn" && "$sn" != "global" && "$sn" != "printers" && "$sn" != "print$" ]]; then
            remaining=1
            break
        fi
    done < <(grep '^\[' /etc/samba/smb.conf 2>/dev/null || true)

    if [[ "$remaining" -eq 0 ]]; then
        echo "No shares remaining. Stopping Samba..."
        systemctl disable --now smbd 2>/dev/null || true

        # Remove samba users from group
        for u in "${SAMBA_USERS[@]}"; do
            smbpasswd -x "$u" 2>/dev/null || true
        done

        if dpkg -s samba &>/dev/null; then
            echo "Removing samba..."
            apt remove -y samba samba-common-bin acl
        fi
    else
        echo "Other shares remain. Restarting Samba..."
        systemctl restart smbd
    fi

    echo ""
    echo "=== Samba server uninstall complete ==="
}

# =============================================================================
# Client functions (run on VM)
# =============================================================================

check_client() {
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

    # Discover any cifs fstab entries for this host not already reported
    while IFS= read -r line; do
        local fstab_path
        fstab_path=$(echo "$line" | awk '{print $2}')
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

client_install() {
    echo "=== Setting up SMB mounts ==="

    # Install cifs-utils if not present
    if ! dpkg -s cifs-utils &>/dev/null; then
        echo "Installing cifs-utils..."
        sudo apt update && sudo apt install -y cifs-utils
    else
        echo "cifs-utils already installed"
    fi

    # Create credentials file
    echo "Setting up credentials file at $SMB_CREDS_FILE..."
    sudo mkdir -p "$(dirname "$SMB_CREDS_FILE")"
    cat <<EOF | sudo tee "$SMB_CREDS_FILE" >/dev/null
username=$SMB_USER
password=$SMB_PASS
EOF
    sudo chmod 600 "$SMB_CREDS_FILE"
    echo "Credentials file created (root-only readable)."

    # Clean up any existing cifs entries for this host first
    if grep -q "//$HOST_IP/.*cifs" /etc/fstab 2>/dev/null; then
        echo "Cleaning existing fstab entries for $HOST_IP..."

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
            -o credentials="$SMB_CREDS_FILE",uid=1000,gid=1000,file_mode=0777,dir_mode=0777

        # Verify mount
        if mountpoint -q "$MOUNT_PATH"; then
            echo "Mount successful!"
            ls "$MOUNT_PATH" | head -10
        else
            echo "ERROR: Mount failed for $MOUNT_PATH"
            exit 1
        fi

        # Add to fstab
        FSTAB_ENTRY="//$HOST_IP/$SHARE_NAME $MOUNT_PATH cifs credentials=$SMB_CREDS_FILE,uid=1000,gid=1000,file_mode=0777,dir_mode=0777,_netdev,nofail 0 0"
        echo "Adding to fstab for persistence..."
        echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    done

    sudo systemctl daemon-reload

    echo ""
    echo "=== SMB mount setup complete ==="
    echo "All mounts configured and persisted in /etc/fstab"
}

client_uninstall() {
    local filter_paths=("$@")
    echo "=== Uninstalling SMB mounts ==="
    echo ""

    # Build list of all CIFS entries for this host
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
    done < <(grep "//$HOST_IP/.*cifs" /etc/fstab 2>/dev/null || true)

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
    done < <(mount | grep "//$HOST_IP/" 2>/dev/null || true)

    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "No SMB entries found for $HOST_IP."
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
                echo "Warning: $fp not found in SMB entries, skipping."
            fi
        done
    elif [[ ! -t 0 ]]; then
        # Piped mode without paths = all
        selected=("${entries[@]}")
    else
        # Interactive mode
        echo "Found SMB entries for $HOST_IP:"
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
        if grep -q "//$HOST_IP/.*$path.*cifs" /etc/fstab 2>/dev/null; then
            echo "Removing fstab entry for $path..."
            sudo sed -i "\|//$HOST_IP/.*$path.*cifs|d" /etc/fstab
        # Also match by mount path in second column
        elif grep -q " $path .*cifs" /etc/fstab 2>/dev/null; then
            echo "Removing fstab entry for $path..."
            sudo sed -i "\| $path .*cifs|d" /etc/fstab
        fi
    done

    sudo systemctl daemon-reload

    # Remove cifs-utils and credentials file only if all entries were removed
    if ! grep -q "//$HOST_IP/.*cifs" /etc/fstab 2>/dev/null && \
       ! mount | grep -q "//$HOST_IP/" 2>/dev/null; then
        # Remove credentials file
        if [[ -f "$SMB_CREDS_FILE" ]]; then
            echo "Removing credentials file $SMB_CREDS_FILE..."
            sudo rm -f "$SMB_CREDS_FILE"
        fi

        if dpkg -s cifs-utils &>/dev/null; then
            echo "No SMB mounts remaining. Removing cifs-utils..."
            sudo apt remove -y cifs-utils
        fi
    fi

    echo ""
    echo "=== SMB mount uninstall complete ==="
}

# =============================================================================
# Main
# =============================================================================

echo "=== SMB Setup Manager ==="
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
echo "  1) Proxmox host (Samba server)"
echo "  2) VM (SMB client)"
read -rp "Select (1/2): " mode

case "$mode" in
    1)
        echo ""
        if check_server; then
            echo ""
            echo "Existing Samba config detected (shown above)."
            read -rp "Do you want to [u]ninstall or [r]einstall? (u/r): " choice
            case "$choice" in
                u|U) server_uninstall ;;
                r|R) server_install ;;
                *) echo "Cancelled."; exit 0 ;;
            esac
        else
            echo "No Samba config found."
            read -rp "Do you want to set up Samba server? (y/n): " choice
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
            echo "Existing SMB mounts detected (shown above)."
            read -rp "Do you want to [u]ninstall or [r]einstall? (u/r): " choice
            case "$choice" in
                u|U) client_uninstall ;;
                r|R) client_install ;;
                *) echo "Cancelled."; exit 0 ;;
            esac
        else
            echo "No existing SMB mounts found."
            read -rp "Do you want to set up SMB mounts? (y/n): " choice
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