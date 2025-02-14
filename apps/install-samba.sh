#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-samba.sh)"
# purpose: this script installs samba
# =====
# notes: to ensure files inside the directory have the right permissions 
# sudo find /mnt/sec/media -type f -exec chmod 664 {} \;
# sudo find /mnt/sec/media -type d -exec chmod 775 {} \;

# Define colors and status symbols
GREEN="\e[32m\u2714\e[0m"
RED="\e[31m\u2718\e[0m"
RESET="\e[0m"
LOG_FILE="/var/log/install-samba.log"

# Function to output status messages and log errors
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        echo "[ERROR] ${message}" >> "$LOG_FILE"
        echo "For more details, check the log file at $LOG_FILE."
        exit 1
    fi
}

# Redirect all output to a log file for debugging
exec > >(tee -a "$LOG_FILE") 2>&1

# Clear the log file at the start of each run
: > "$LOG_FILE"

# Start of the installation
echo "Starting Samba installation and configuration script..." >> "$LOG_FILE"

# Ensure necessary dependencies are installed
function install_dependencies() {
    local dependencies=("sudo" "samba" "samba-common-bin")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "Installing missing dependency: $dep..." >> "$LOG_FILE"
            apt update >> "$LOG_FILE" 2>&1 && apt install -y "$dep" >> "$LOG_FILE" 2>&1
            [[ $? -eq 0 ]] && status_message "success" "$dep installed successfully." || status_message "error" "Failed to install $dep."
        else
            status_message "success" "$dep is already installed."
        fi
    done
}

# Set up the Samba share configuration
function setup_samba_share() {
    local share_name="mediadb"
    local share_path="/mnt/sec/media"

    # Create the directory if it doesn't exist
    if [ ! -d "$share_path" ]; then
        mkdir -p "$share_path" >> "$LOG_FILE" 2>&1
        [[ $? -eq 0 ]] && status_message "success" "Directory $share_path created successfully." || status_message "error" "Failed to create directory $share_path."
    fi

    # Backup the Samba configuration
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak >> "$LOG_FILE" 2>&1
    [[ $? -eq 0 ]] && status_message "success" "Samba configuration backed up successfully." || status_message "error" "Failed to back up Samba configuration."

    # Ensure the workgroup is set
    sed -i '/^workgroup =/d' /etc/samba/smb.conf
    echo "[global]
workgroup = WORKGROUP
" | tee -a /etc/samba/smb.conf >> "$LOG_FILE"
    status_message "success" "Samba workgroup set to WORKGROUP."

    # Configure the share in smb.conf
    if grep -q "^\[$share_name\]" /etc/samba/smb.conf; then
        sed -i '/^\['"$share_name"'\]/,/^$/d' /etc/samba/smb.conf
    fi
    echo "
[$share_name]
   path = $share_path
   browseable = yes
   writable = yes
   guest ok = no
   read only = no
   create mask = 0775
   directory mask = 0775
   valid users = toor
" >> /etc/samba/smb.conf
    [[ $? -eq 0 ]] && status_message "success" "Samba share configuration added for '$share_name'." || status_message "error" "Failed to add Samba share configuration for '$share_name'."

    # Set permissions for the directory
    chown -R root:toor "$share_path" >> "$LOG_FILE" 2>&1
    chmod -R 775 "$share_path" >> "$LOG_FILE" 2>&1
    [[ $? -eq 0 ]] && status_message "success" "Permissions set for $share_path." || status_message "error" "Failed to set permissions for $share_path."

    # Restart Samba service
    systemctl restart smbd >> "$LOG_FILE" 2>&1
    [[ $? -eq 0 ]] && status_message "success" "Samba service restarted successfully." || status_message "error" "Failed to restart Samba service."
}

# Check if the user already exists
function check_existing_user() {
    local samba_user=$1
    if id "$samba_user" &>/dev/null; then
        status_message "error" "User '$samba_user' already exists. Please use a different username to avoid overwriting an existing account."
        exit 1
    fi
}

# Create a Samba user
function setup_samba_user() {
    local samba_user=$1

    # Check if the user already exists
    check_existing_user "$samba_user"

    # Add the user
    useradd -m -s /bin/bash "$samba_user" >> "$LOG_FILE" 2>&1
    usermod -aG toor "$samba_user" >> "$LOG_FILE" 2>&1

    read -s -p "Enter a password for the Samba user '$samba_user': " samba_password
    echo
    read -s -p "Confirm the password for the Samba user '$samba_user': " samba_password_confirm
    echo

    if [[ "$samba_password" != "$samba_password_confirm" ]]; then
        status_message "error" "Passwords do not match. Please re-run the script."
    fi

    {
        echo "$samba_password"
        echo "$samba_password"
    } | smbpasswd -s -a "$samba_user" >> "$LOG_FILE" 2>&1

    smbpasswd -e "$samba_user" >> "$LOG_FILE" 2>&1
    [[ $? -eq 0 ]] && status_message "success" "Samba user '$samba_user' has been created and enabled." || status_message "error" "Failed to create Samba user '$samba_user'."
}

# Main execution flow
install_dependencies
setup_samba_share
read -p "Enter the username for the Samba account: " samba_user
setup_samba_user "$samba_user"

# Final success message
status_message "success" "Samba share 'mediadb' has been created successfully."
echo "You can access it from other machines using:"
echo "\\\\<Proxmox-IP>\\mediadb"
