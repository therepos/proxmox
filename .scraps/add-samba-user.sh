#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/add-samba-user.sh?$(date +%s))"
# purpose: add samba user and access

# Config
SHARE_ROOT="/mnt/sec/media"
SAMBA_GROUP="sambausers"

# Step 1: Prompt for username and password
read -rp "Enter new Samba username: " NEW_USER
read -rsp "Enter password for $NEW_USER: " NEW_PASS
echo

# Step 2: Create system and Samba user
useradd -m "$NEW_USER"
echo "$NEW_USER:$NEW_PASS" | chpasswd
(echo "$NEW_PASS"; echo "$NEW_PASS") | smbpasswd -s -a "$NEW_USER"
usermod -aG "$SAMBA_GROUP" "$NEW_USER"

# Step 3: List first-level folders
echo -e "\nAvailable folders in $SHARE_ROOT:"
FOLDERS=()
i=1
for dir in "$SHARE_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    echo "$i) $(basename "$dir")"
    FOLDERS+=("$dir")
    ((i++))
done

# Step 4: Choose folders
read -rp "Select folders (space-separated numbers, e.g. 1 3): " -a SELECTED

echo

# Step 5: Process selected folders
for index in "${SELECTED[@]}"; do
    TARGET_PATH="${FOLDERS[$((index-1))]}"
    TARGET_NAME=$(basename "$TARGET_PATH")

    echo "Setting access for '$NEW_USER' to: $TARGET_PATH"

    # Set permissions and ACL
    chown -R root:"$SAMBA_GROUP" "$TARGET_PATH"
    chmod -R 2775 "$TARGET_PATH"
    chmod g+s "$TARGET_PATH"
    setfacl -R -m u:"$NEW_USER":rwX "$TARGET_PATH"
    setfacl -R -m d:u:"$NEW_USER":rwX "$TARGET_PATH"

    # Add share to smb.conf
    cat <<EOF >> /etc/samba/smb.conf

[$TARGET_NAME-$NEW_USER]
   path = $TARGET_PATH
   browseable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0664
   directory mask = 2775
   force user = $NEW_USER
   valid users = $NEW_USER
   write list = $NEW_USER
EOF

done

# Step 6: Restart Samba
systemctl restart smbd

echo -e "\n\033[32m✔ User '$NEW_USER' added with access to selected folder(s).\033[0m"
