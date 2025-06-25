#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installer/install-samba.sh?$(date +%s))"
# purpose: installs and configures Samba with correct permissions
# =====
# notes: to ensure files inside the directory have the right permissions 
# sudo find /mnt/sec/media -type f -exec chmod 664 {} \;
# sudo find /mnt/sec/media -type d -exec chmod 775 {} \;

# Configuration
LOG_FILE="/var/log/install-samba.log"
SHARE_NAME="mediadb"
SHARE_PATH="/mnt/sec/media"
SAMBA_GROUP="sambausers"
SAMBA_USER="toor"

# Status message function
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

# Redirect output to log
exec > >(tee -a "$LOG_FILE") 2>&1
: > "$LOG_FILE"

echo "Starting Samba installation..."

# Install packages
apt update -y && apt install -y samba samba-common-bin acl
status_message success "Samba and dependencies installed."

# Ensure Samba group exists
getent group "$SAMBA_GROUP" || groupadd "$SAMBA_GROUP"
status_message success "Group '$SAMBA_GROUP' ready."

# Create Samba user if missing
id "$SAMBA_USER" &>/dev/null || useradd -m "$SAMBA_USER"
echo "Set password for Samba user '$SAMBA_USER':"
echo "$SAMBA_USER:$SAMBA_USER" | chpasswd
(echo "$SAMBA_USER"; echo "$SAMBA_USER") | smbpasswd -s -a "$SAMBA_USER"
usermod -aG "$SAMBA_GROUP" "$SAMBA_USER"
status_message success "User '$SAMBA_USER' created and added to '$SAMBA_GROUP'."

# Create share path
mkdir -p "$SHARE_PATH"
chown -R root:"$SAMBA_GROUP" "$SHARE_PATH"
chmod -R 2775 "$SHARE_PATH"
chmod g+s "$SHARE_PATH"

# Set ACLs
setfacl -R -m g:"$SAMBA_GROUP":rwX "$SHARE_PATH"
setfacl -R -m d:g:"$SAMBA_GROUP":rwX "$SHARE_PATH"
setfacl -R -m d:o::r "$SHARE_PATH"

status_message success "Permissions and ACLs set on '$SHARE_PATH'."

# Backup original Samba config
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# Write new Samba config
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
   inherit permissions = yes
EOF

# Enable and restart Samba
systemctl enable smbd
systemctl restart smbd
status_message success "Samba service configured and running."

echo -e "\e[32mSamba share '$SHARE_NAME' is ready at: \\\\<your-proxmox-ip>\\$SHARE_NAME\e[0m"


