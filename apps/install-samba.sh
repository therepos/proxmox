#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-samba.sh)"
# purpose: this script installs and configures Samba with correct permissions
# =====
# notes: to ensure files inside the directory have the right permissions 
# sudo find /mnt/sec/media -type f -exec chmod 664 {} \;
# sudo find /mnt/sec/media -type d -exec chmod 775 {} \;

LOG_FILE="/var/log/install-samba.log"
SHARE_NAME="mediadb"
SHARE_PATH="/mnt/sec/media"
SAMBA_GROUP="sambausers"
SAMBA_USER="admin"

# Function to log status messages
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "\e[32m✔ ${message}\e[0m"
    else
        echo -e "\e[31m✘ ${message}\e[0m"
        echo "[ERROR] ${message}" >> "$LOG_FILE"
        exit 1
    fi
}

# Redirect all output to a log file for debugging
exec > >(tee -a "$LOG_FILE") 2>&1
: > "$LOG_FILE"  # Clear the log file on each run

echo "Starting Samba installation..." >> "$LOG_FILE"

# Install required packages
function install_dependencies() {
    apt update -y && apt install -y samba samba-common-bin acl
    [[ $? -eq 0 ]] && status_message "success" "Dependencies installed." || status_message "error" "Failed to install dependencies."
}

# Create the Samba share directory
function setup_samba_share() {
    mkdir -p "$SHARE_PATH"

    # Ensure Samba group exists
    getent group "$SAMBA_GROUP" || groupadd "$SAMBA_GROUP"

    # Ensure `admin` is in the Samba group
    usermod -aG "$SAMBA_GROUP" "$SAMBA_USER"

    # Set directory ownership and permissions
    chown -R root:"$SAMBA_GROUP" "$SHARE_PATH"
    chmod -R 2775 "$SHARE_PATH"

    # Apply ACL to enforce `rw-rw-r--` on new files
    setfacl -d -m group:"$SAMBA_GROUP":rw "$SHARE_PATH"
    setfacl -m group:"$SAMBA_GROUP":rw "$SHARE_PATH"

    # Backup and update Samba configuration
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

    cat <<EOF > /etc/samba/smb.conf
[global]
   workgroup = WORKGROUP
   logging = file
   map to guest = bad user
   usershare allow guests = yes

[$SHARE_NAME]
   path = $SHARE_PATH
   browseable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0664
   directory mask = 2775
   force create mode = 0664
   force directory mode = 2775
   force group = $SAMBA_GROUP
   valid users = $SAMBA_USER
   write list = $SAMBA_USER
EOF

    # Restart Samba service
    systemctl restart smbd
    [[ $? -eq 0 ]] && status_message "success" "Samba service restarted." || status_message "error" "Failed to restart Samba."
}

install_dependencies
setup_samba_share

status_message "success" "Samba share '$SHARE_NAME' has been configured successfully."
echo "You can access it via: \\\\<Proxmox-IP>\\$SHARE_NAME"

