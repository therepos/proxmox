#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/smb-setup.sh?$(date +%s))"
# Purpose: Samba server on Proxmox host / SMB client mounts in VM (Debian/Ubuntu)
# =============================================================================
# Usage:
#   1) Proxmox host  -> install / status / passwd / add user / repair / uninstall
#   2) VM            -> install / uninstall SMB client mounts
#
# Flags: --server-install | --server-status | --server-passwd
#        --server-adduser [name] | --server-repair | --server-uninstall [share]
#        --client-install | --client-uninstall [path] | -y
#
# Note: Samba runs as root (force user) to match FileBrowser, so its files stay editable.
# Config (env): HOST_IP, SMB_USER, SMB_PASS, ASSUME_YES.
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

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# Prompt that still works when piped from wget (reads the real terminal).
askstr() { # askstr "prompt" [default]
    local p="$1" def="${2:-}" in=""
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then echo "$def"; return; fi
    if [[ -r /dev/tty ]]; then
        read -rp "$p" in </dev/tty || in="$def"
    else
        in="$def"
    fi
    echo "${in:-$def}"
}

# --- Variables ---------------------------------------------------------------
ASSUME_YES="${ASSUME_YES:-0}"

# Host IP is auto-detected (never hardcode — it differs per machine and changes
# with DHCP). Override by exporting HOST_IP before running.
HOST_IP="${HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')}"

SAMBA_GROUP="sambausers"
SAMBA_USERS=("toor")

# Server shares: "share_name:share_path"
SHARES=(
    "sec:/mnt/sec"
)

# Client mounts: "share_name:mount_path"
# NOTE: For host->VM sharing use virtiofs, not SMB (see virtiofs-setup.sh).
MOUNTS=(
    "sec:/mnt/sec"
)

# Samba runs all file operations as root (force user = root). This is deliberate:
# FileBrowser also runs as root, so files it creates are root-owned. Files stay
# owned by root, but the share is group 'sambausers' with setgid + default ACLs
# (see apply_share_access) so VM users and containers reaching /mnt/sec over
# virtiofs can read/write too — not just root over SMB.
SHARE_OWNER="root"
SHARE_OWNER_GROUP="$SAMBA_GROUP"   # group-own the share so members can write

# Extra UIDs that get direct read/write via a default ACL. These are the VM
# users and containers (e.g. the Brave/Kasm container, uid 1000) that reach the
# share through virtiofs. Naming the UID directly is deliberate: the
# 'sambausers' group has different GID numbers on the host and inside the VM, so
# group membership alone does not carry across virtiofs — a named-UID ACL does.
# Space-separated; override via env. Set to "" to disable.
SHARE_ACCESS_UIDS="${SHARE_ACCESS_UIDS:-1000}"

SMB_USER="${SMB_USER:-toor}"
SMB_PASS="${SMB_PASS:-}"   # prompted at install time; never hardcoded
SMB_CREDS_FILE="/etc/samba/.smbcreds"

prompt_smb_pass() {
    [[ -n "$SMB_PASS" ]] && return 0
    [[ -r /dev/tty ]] || fail "No password set. Export SMB_PASS=... for headless runs."
    local p1 p2
    while true; do
        read -rsp "Set Samba password for '${SMB_USER}': " p1 </dev/tty; echo ""
        read -rsp "Confirm password: " p2 </dev/tty; echo ""
        [[ -z "$p1" ]] && { warn "Password cannot be empty."; continue; }
        [[ "$p1" != "$p2" ]] && { warn "Passwords do not match."; continue; }
        SMB_PASS="$p1"
        return 0
    done
}

# --- Server functions (Proxmox host) -----------------------------------------

# Populate SHARE_NAMES / SHARE_PATHS from smb.conf (skips global/printers).
enum_shares() {
    SHARE_NAMES=(); SHARE_PATHS=()
    local line name path
    while IFS= read -r line; do
        name=$(echo "$line" | sed 's/[][]//g' | xargs)
        [[ -z "$name" || "$name" == "global" || "$name" == "printers" || "$name" == "print$" ]] && continue
        path=$(sed -n "/^\[$name\]/,/^\[/{ /path/s/.*= *//p; }" /etc/samba/smb.conf 2>/dev/null | head -1)
        SHARE_NAMES+=("$name"); SHARE_PATHS+=("$path")
    done < <(grep '^\[' /etc/samba/smb.conf 2>/dev/null || true)
}

# Print the client connection details for a share (the summary shown after install).
print_connection_info() {
    local share="$1" user="$2" note="${3:-}"
    echo "  Windows:  \\\\${HOST_IP}\\${share}"
    echo "  Mac:      smb://${HOST_IP}/${share}"
    echo "  Login:    ${user}  ${note}"
    echo ""
    echo "  Works from any Tailscale device, provided the ${HOST_IP%.*}.0/24"
    echo "  subnet route is approved in the Tailscale admin console."
}

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

# Make a share path writable by everyone who needs it — SMB clients (via
# force user = root), FileBrowser (root), and VM users / containers (uid 1000)
# reaching it over virtiofs. Files stay root-owned; access for the rest comes
# from group ownership + setgid + ACLs:
#   * chgrp to $SAMBA_GROUP + setgid on dirs  -> new files inherit the group.
#   * default ACLs for the group AND each $SHARE_ACCESS_UIDS -> every file,
#     existing or created later by ANY app, is writable by them regardless of
#     the creator's umask (this is what tames root-owned FileBrowser/SMB files).
# Requires the 'acl' package (installed by server_install). Idempotent.
apply_share_access() {
    local path="$1"
    [[ -d "$path" ]] || return 0

    chgrp -R "$SAMBA_GROUP" "$path" 2>/dev/null || true
    chmod -R g+rwX "$path"
    find "$path" -type d -exec chmod g+s {} + 2>/dev/null || true

    if command -v setfacl >/dev/null 2>&1; then
        local spec="g:${SAMBA_GROUP}:rwX" u
        for u in $SHARE_ACCESS_UIDS; do spec="${spec},u:${u}:rwX"; done
        # Apply to existing tree and as the inherited default for new entries.
        setfacl -R    -m "$spec" "$path" 2>/dev/null || warn "setfacl (existing) failed on $path"
        setfacl -R -d -m "$spec" "$path" 2>/dev/null || warn "setfacl (default) failed on $path"
    else
        warn "acl tools not found; skipping ACLs (install the 'acl' package)."
    fi
}

server_install() {
    info "Setting up Samba server..."

    # Install samba if not present
    if ! dpkg -s samba &>/dev/null; then
        info "Installing samba and dependencies..."
        apt update -y && apt install -y samba samba-common-bin acl
    else
        ok "Samba already installed."
    fi

    # Create samba group
    getent group "$SAMBA_GROUP" &>/dev/null || groupadd "$SAMBA_GROUP"
    ok "Group '$SAMBA_GROUP' ready."

    prompt_smb_pass

    # Create users and samba credentials.
    # The Samba password is what you type from Windows/Mac; it is set from the
    # prompt above rather than being the username (the old behaviour).
    for u in "${SAMBA_USERS[@]}"; do
        id "$u" &>/dev/null || useradd -m "$u"
        (echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -s -a "$u"
        usermod -aG "$SAMBA_GROUP" "$u"
        ok "User '$u' enabled for Samba."
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

        echo ""
        echo "--- [$SHARE_NAME] -> $SHARE_PATH ---"

        if [[ ! -d "$SHARE_PATH" ]]; then
            echo "ERROR: $SHARE_PATH does not exist. Mount the drive first"
            echo "       (see drivemount-setup.sh). Aborting."
            exit 1
        fi

        # Owner stays root (FileBrowser and force-user=root Samba create files
        # as root), but the share is group-owned by $SAMBA_GROUP and made
        # writable to the group + the VM/container UIDs via setgid and ACLs, so
        # VM users reaching /mnt/sec over virtiofs can read/write too.
        chown -R "${SHARE_OWNER}:${SHARE_OWNER_GROUP}" "$SHARE_PATH"
        chmod -R 2775 "$SHARE_PATH"
        apply_share_access "$SHARE_PATH"

        ok "Permissions set on '$SHARE_PATH' (owner ${SHARE_OWNER}, group ${SAMBA_GROUP} + ACLs)."

        # force user = root is the key line. Clients still authenticate as
        # '$SMB_USER', but every read/write executes as root — so anything
        # FileBrowser wrote (as root) is fully editable from Windows/Mac.
        # Trade-off: an authenticated client has root-level write access to
        # this path. Acceptable here because it is Tailscale-only and
        # FileBrowser already exposes the filesystem as root.
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
   force user = $SHARE_OWNER
   force group = $SHARE_OWNER_GROUP
   valid users = @${SAMBA_GROUP}
   write list = @${SAMBA_GROUP}
SHARE_EOF
    done

    # Validate and restart
    testparm -s >/dev/null || fail "Samba config invalid."
    systemctl enable --now smbd
    systemctl restart smbd

    local SHARE1="${SHARES[0]%%:*}"
    echo ""
    echo "=== Samba server setup complete ==="
    echo ""
    print_connection_info "$SHARE1" "$SMB_USER" "(password as just set)"
    echo ""
}

# Show running state, configured shares, Samba users, and the client
# connection details (the same summary printed after install).
server_status() {
    echo "=== SMB Server Status ==="
    echo ""

    if systemctl is-active --quiet smbd 2>/dev/null; then
        ok "Samba service: running"
    else
        warn "Samba service: not running"
    fi

    if [[ ! -f /etc/samba/smb.conf ]]; then
        echo ""
        warn "No /etc/samba/smb.conf found — server not configured."
        return 0
    fi

    enum_shares
    echo ""
    if [[ ${#SHARE_NAMES[@]} -eq 0 ]]; then
        echo "  Shares: none configured"
    else
        echo "  Shares:"
        for i in "${!SHARE_NAMES[@]}"; do
            printf '    [%s] -> %s\n' "${SHARE_NAMES[$i]}" "${SHARE_PATHS[$i]}"
        done
    fi

    # Samba-enabled accounts (pdbedit lists the passdb, not just /etc/passwd).
    local users
    users=$(pdbedit -L 2>/dev/null | cut -d: -f1 | paste -sd', ' - || true)
    echo ""
    echo "  Samba users: ${users:-none}"

    # Client connection details (per share).
    if [[ ${#SHARE_NAMES[@]} -gt 0 ]]; then
        local login_user
        login_user=$(pdbedit -L 2>/dev/null | cut -d: -f1 | head -1 || true)
        login_user="${login_user:-${SAMBA_USERS[0]:-$SMB_USER}}"
        echo ""
        echo "  --- Connection details ---"
        echo ""
        for name in "${SHARE_NAMES[@]}"; do
            print_connection_info "$name" "$login_user" "(password as set)"
            echo ""
        done
    fi
}

# Change the Samba password for an existing user (does not touch the Linux login).
server_passwd() {
    info "Change Samba password"
    echo ""

    local users user
    mapfile -t users < <(pdbedit -L 2>/dev/null | cut -d: -f1)
    if [[ ${#users[@]} -eq 0 ]]; then
        fail "No Samba users found. Run the server install first."
    fi

    if [[ ${#users[@]} -eq 1 ]]; then
        user="${users[0]}"
        info "Changing password for '$user'."
    else
        echo "Samba users:"
        for i in "${!users[@]}"; do echo "  $((i + 1))) ${users[$i]}"; done
        echo ""
        local sel
        read -rp "Select user: " sel </dev/tty
        local idx=$((sel - 1))
        [[ $idx -ge 0 && $idx -lt ${#users[@]} ]] || fail "Invalid selection."
        user="${users[$idx]}"
    fi

    # Reuse prompt_smb_pass (prompts twice, honours SMB_PASS for headless runs).
    SMB_USER="$user"; SMB_PASS="${SMB_PASS:-}"
    prompt_smb_pass
    (echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -s "$user"
    ok "Password updated for '$user'."
}

# Add a new Samba user: create the Linux account if needed, set a Samba
# password, and add it to the share group so it can access all shares.
server_adduser() {
    info "Add Samba user"
    echo ""

    dpkg -s samba &>/dev/null || fail "Samba not installed. Run the server install first."

    local newuser="${1:-}"
    [[ -n "$newuser" ]] || newuser=$(askstr "New username: " "")
    [[ -n "$newuser" ]] || fail "Username cannot be empty."

    getent group "$SAMBA_GROUP" &>/dev/null || groupadd "$SAMBA_GROUP"
    id "$newuser" &>/dev/null || useradd -m "$newuser"

    SMB_USER="$newuser"; SMB_PASS="${SMB_PASS:-}"
    prompt_smb_pass
    (echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -s -a "$newuser"
    usermod -aG "$SAMBA_GROUP" "$newuser"

    ok "User '$newuser' enabled for Samba and added to '$SAMBA_GROUP'."
    echo ""
    info "This user can now access all shares (valid users = @${SAMBA_GROUP})."
}

# Repair ownership/permissions on files created before this fix (or by any
# writer that used a different UID). Safe to re-run; idempotent. Run this to
# retro-fix VM/container write access on an already-installed share.
server_repair() {
    info "Repairing share permissions..."
    echo ""
    for ENTRY in "${SHARES[@]}"; do
        local SHARE_PATH="${ENTRY#*:}"
        [[ -d "$SHARE_PATH" ]] || { echo "Skipping $SHARE_PATH (not present)"; continue; }
        echo "Repairing $SHARE_PATH ..."
        chown -R "${SHARE_OWNER}:${SHARE_OWNER_GROUP}" "$SHARE_PATH"
        chmod -R u+rwX "$SHARE_PATH"
        apply_share_access "$SHARE_PATH"
        ok "  done."
    done
    echo ""
    echo "=== Repair complete ==="
    echo "Files stay owned by ${SHARE_OWNER}; group ${SAMBA_GROUP} + ACLs make"
    echo "them read/write for VM users, containers (uid ${SHARE_ACCESS_UIDS// /, }), and SMB."
}

server_uninstall() {
    local filter_names=("$@")
    info "Uninstalling Samba server..."
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
        ok "No Samba shares found. Nothing to do."
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
                warn "Share '$fn' not found, skipping."
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

        read -rp "Select shares to remove (e.g. 1, 1 3, or a): " selection </dev/tty

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
                    warn "Invalid selection: $num"
                fi
            done
        fi
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        info "No valid entries selected. Cancelled."
        return 0
    fi

    echo ""

    # Remove selected share sections from smb.conf
    for idx in "${selected[@]}"; do
        local share_name="${entries[$idx]}"
        info "Removing share: [$share_name]"
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
        info "No shares remaining. Stopping Samba..."
        systemctl disable --now smbd 2>/dev/null || true

        # Remove samba users from group
        for u in "${SAMBA_USERS[@]}"; do
            smbpasswd -x "$u" 2>/dev/null || true
        done

        if dpkg -s samba &>/dev/null; then
            info "Removing samba..."
            apt remove -y samba samba-common-bin acl
        fi
    else
        info "Other shares remain. Restarting Samba..."
        systemctl restart smbd
    fi

    echo ""
    ok "Samba server uninstalled."
}

# --- Client functions (VM) ---------------------------------------------------

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
    info "Setting up SMB mounts..."

    # Install cifs-utils if not present
    if ! dpkg -s cifs-utils &>/dev/null; then
        info "Installing cifs-utils..."
        sudo apt update && sudo apt install -y cifs-utils
    else
        ok "cifs-utils already installed."
    fi

    prompt_smb_pass

    # Create credentials file
    echo "Setting up credentials file at $SMB_CREDS_FILE..."
    sudo mkdir -p "$(dirname "$SMB_CREDS_FILE")"
    cat <<EOF | sudo tee "$SMB_CREDS_FILE" >/dev/null
username=$SMB_USER
password=$SMB_PASS
EOF
    sudo chmod 600 "$SMB_CREDS_FILE"
    ok "Credentials file created (root-only readable)."

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
            ok "Mount successful."
            ls "$MOUNT_PATH" | head -10
        else
            fail "Mount failed for $MOUNT_PATH"
        fi

        # Add to fstab
        FSTAB_ENTRY="//$HOST_IP/$SHARE_NAME $MOUNT_PATH cifs credentials=$SMB_CREDS_FILE,uid=1000,gid=1000,file_mode=0777,dir_mode=0777,_netdev,nofail 0 0"
        echo "Adding to fstab for persistence..."
        echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
    done

    sudo systemctl daemon-reload

    echo ""
    ok "SMB mounts configured and persisted in /etc/fstab."
    echo "All mounts configured and persisted in /etc/fstab"
}

client_uninstall() {
    local filter_paths=("$@")
    info "Uninstalling SMB mounts..."
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
        ok "No SMB entries found. Nothing to do."
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
                warn "$fp not found in SMB entries, skipping."
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

        read -rp "Select entries to uninstall (e.g. 1, 1 3, or a): " selection </dev/tty

        if [[ "$selection" == "a" || "$selection" == "A" ]]; then
            selected=("${entries[@]}")
        else
            for num in $selection; do
                local idx=$((num - 1))
                if [[ $idx -ge 0 && $idx -lt ${#entries[@]} ]]; then
                    selected+=("${entries[$idx]}")
                else
                    warn "Invalid selection: $num"
                fi
            done
        fi
    fi

    if [[ ${#selected[@]} -eq 0 ]]; then
        info "No valid entries selected. Cancelled."
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
    ok "SMB mounts uninstalled."
}

# --- Main --------------------------------------------------------------------

# Consume -y/--yes anywhere in the args (§7: non-interactive path).
args=()
for a in "$@"; do
    case "$a" in
        -y|--yes) ASSUME_YES=1 ;;
        *) args+=("$a") ;;
    esac
done
set -- "${args[@]:-}"

echo "================================================================"
echo "  SMB Setup Manager"
echo "================================================================"
echo ""

# Non-interactive mode via flags
case "${1:-}" in
    --server-install)
        server_install
        exit 0
        ;;
    --server-repair)
        server_repair
        exit 0
        ;;
    --server-status)
        server_status
        exit 0
        ;;
    --server-passwd)
        server_passwd
        exit 0
        ;;
    --server-adduser)
        shift
        server_adduser "$@"
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
read -rp "Select (1/2): " mode </dev/tty

case "$mode" in
    1)
        echo ""
        if check_server; then
            echo ""
            echo "Existing Samba config detected (shown above)."
            echo "  s) Show status / connection details"
            echo "  c) Change a user's password"
            echo "  a) Add a user"
            echo "  r) Reinstall"
            echo "  p) Repair permissions (fix files you cannot edit)"
            echo "  u) Uninstall"
            read -rp "Select (s/c/a/r/p/u): " choice </dev/tty
            case "$choice" in
                s|S) server_status ;;
                c|C) server_passwd ;;
                a|A) server_adduser ;;
                u|U) server_uninstall ;;
                r|R) server_install ;;
                p|P) server_repair ;;
                *) info "Cancelled."; exit 0 ;;
            esac
        else
            echo "No Samba config found."
            read -rp "Do you want to set up Samba server? (y/n): " choice </dev/tty
            case "$choice" in
                y|Y) server_install ;;
                *) info "Cancelled."; exit 0 ;;
            esac
        fi
        ;;
    2)
        echo ""
        if check_client; then
            echo ""
            echo "Existing SMB mounts detected (shown above)."
            read -rp "Do you want to [u]ninstall or [r]einstall? (u/r): " choice </dev/tty
            case "$choice" in
                u|U) client_uninstall ;;
                r|R) client_install ;;
                *) info "Cancelled."; exit 0 ;;
            esac
        else
            echo "No existing SMB mounts found."
            read -rp "Do you want to set up SMB mounts? (y/n): " choice </dev/tty
            case "$choice" in
                y|Y) client_install ;;
                *) info "Cancelled."; exit 0 ;;
            esac
        fi
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac