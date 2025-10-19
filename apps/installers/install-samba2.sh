#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-samba2.sh?$(date +%s))"
# purpose: installs samba
# version: pve 9
# =====
# Refined Samba installer for Proxmox (Debian 12 / PVE 9)
# - Windows-friendly ACLs (acl_xattr)
# - Group-based write access
# - SMB2/3 only
# - Multi-user support

set -euo pipefail

LOG_FILE="/var/log/install-samba.log"
SHARE_NAME="mediadb"
SHARE_PATH="/mnt/sec/media"
SAMBA_GROUP="sambausers"
# Add/modify users here; password defaults to the same as username
SAMBA_USERS=("toor")

exec > >(tee -a "$LOG_FILE") 2>&1
: > "$LOG_FILE"
echo "Starting Samba installation..."

apt update -y && apt install -y samba samba-common-bin acl
echo "✔ Samba and dependencies installed."

getent group "$SAMBA_GROUP" || groupadd "$SAMBA_GROUP"
echo "✔ Group '$SAMBA_GROUP' ready."

# Create users and Samba creds
for u in "${SAMBA_USERS[@]}"; do
  id "$u" &>/dev/null || useradd -m "$u"
  echo "$u:$u" | chpasswd
  (echo "$u"; echo "$u") | smbpasswd -s -a "$u"
  usermod -aG "$SAMBA_GROUP" "$u"
  echo "✔ User '$u' added to '$SAMBA_GROUP' and enabled for Samba."
done

# Share path with cooperative permissions
mkdir -p "$SHARE_PATH"
chown -R root:"$SAMBA_GROUP" "$SHARE_PATH"
chmod -R 2775 "$SHARE_PATH"
chmod g+s "$SHARE_PATH"

# POSIX ACLs (group RWX; inherit to new files/dirs)
setfacl -R -m g:"$SAMBA_GROUP":rwX "$SHARE_PATH"
setfacl -R -m d:g:"$SAMBA_GROUP":rwX "$SHARE_PATH"
# (Optional) let 'others' read new items; comment out if you want private access
#setfacl -R -m d:o::r "$SHARE_PATH"

echo "✔ Permissions and ACLs set on '$SHARE_PATH'."

# Backup and write smb.conf tuned for Windows clients
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak || true
cat >/etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   logging = file
   map to guest = bad user
   server role = standalone server
   # Windows-friendly ACLs & attributes
   vfs objects = acl_xattr
   map acl inherit = yes
   store dos attributes = yes
   # Safer protocol floor/ceiling
   server min protocol = SMB2
   server max protocol = SMB3
   # Avoid legacy printer stuff
   load printers = no
   printing = bsd
   disable spoolss = yes

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
   valid users = @${SAMBA_GROUP}
   write list = @${SAMBA_GROUP}
EOF

testparm -s || { echo "Samba config invalid"; exit 1; }

systemctl enable --now smbd
systemctl restart smbd
echo "✔ Samba service configured and running."

IP=$(hostname -I | awk '{print $1}')
echo -e "\nSamba share ready: \\\\${IP}\\${SHARE_NAME}"
echo "Use a Windows account/credentials matching one of: ${SAMBA_USERS[*]}"
