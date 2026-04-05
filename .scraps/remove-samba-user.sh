#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/remove-samba-user.sh?$(date +%s))"
# purpose: remove samba user and access

# Config
SHARE_ROOT="/mnt/sec/media"

# Step 1: List Samba users (filtered from /etc/passwd)
echo "Available Samba users:"
USERS=()
i=1
for u in $(pdbedit -L | cut -d: -f1); do
    echo "$i) $u"
    USERS+=("$u")
    ((i++))
done

# Step 2: Choose user
read -rp "Select a user to remove by number: " SELECTED
TARGET_USER="${USERS[$((SELECTED-1))]}"
echo -e "\nRemoving user: $TARGET_USER"

# Step 3: Remove Samba user
smbpasswd -x "$TARGET_USER"

# Step 4: Remove system user and home dir
userdel -r "$TARGET_USER"

# Step 5: Clean ACLs in all subfolders
echo "Removing ACLs in $SHARE_ROOT..."
find "$SHARE_ROOT" -type d -exec setfacl -x u:"$TARGET_USER" {} \;
find "$SHARE_ROOT" -type d -exec setfacl -x d:u:"$TARGET_USER" {} \;

# Step 6: Remove share blocks from smb.conf
echo "Cleaning up smb.conf..."
TMP_CONF="/etc/samba/smb.conf.tmp"
awk -v user="$TARGET_USER" '
BEGIN { skip=0 }
/^\[/ { skip=0 }
/force user *= *"user"/ { if ($3 == user) skip=1 }
skip == 0 { print }
' /etc/samba/smb.conf > "$TMP_CONF" && mv "$TMP_CONF" /etc/samba/smb.conf

# Step 7: Restart Samba
systemctl restart smbd

echo -e "\n\033[32m✔ User '$TARGET_USER' and their access have been removed.\033[0m"
