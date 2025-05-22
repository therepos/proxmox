#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/cron-reboot-ifdown.sh?$(date +%s))"
# purpose: this script reboots proxmox if cloudflared lxc service is down
# =====
# notes:
#   sed -i 's/\r//' /usr/local/bin/reboot-ifdown.sh
#   chmod +x /usr/local/bin/reboot-ifdown.sh
#   crontab -e
#   */5 * * * * /usr/local/bin/reboot-ifdown.sh >> /var/log/reboot-ifdown.log 2>&1
# =====
# check:
#   systemctl status cron

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}${RESET}"
    else
        echo -e "${RED} ${message}${RESET}"
        exit 1
    fi
}

# Variables
SCRIPT_NAME="cron-reboot-ifdown.sh"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
CRON_JOB="*/5 * * * * $SCRIPT_PATH >> /var/log/reboot-ifdown.log 2>&1"
CRON_FILE="/etc/cron.d/cron-reboot-ifdown"

# Check if the script already exists
if [[ -f "$SCRIPT_PATH" ]]; then
    echo "The script $SCRIPT_NAME already exists on your system."
    echo "Would you like to (u)ninstall it or (e)xit? [u/e]"
    read -r choice
    if [[ "$choice" == "u" ]]; then
        echo "Uninstalling the script and removing cron job..."
        rm -f "$SCRIPT_PATH" && status_message success "Script removed."
        rm -f "$CRON_FILE" && status_message success "Cron job removed."
        exit 0
    else
        echo "Exiting without changes."
        exit 0
    fi
fi

# Write the script content to the appropriate location
cat << 'EOF' > "$SCRIPT_PATH"
#!/bin/bash
# purpose: this script reboots proxmox if cloudflared LXC service is down

# Logging setup
LOG_FILE="/var/log/cron-reboot-ifdown.log"
exec >> "$LOG_FILE" 2>&1
echo "Script executed at $(date)"

# Timeout for commands
TIMEOUT=10

# Check if the LXC container (ID 100) is running
echo "Checking if LXC container 100 is running..."
if ! timeout $TIMEOUT /usr/sbin/pct status 100 | grep -q "status: running"; then
    echo "LXC container 100 is not running. Rebooting server."
    /sbin/reboot
    exit 0
else
    echo "LXC container 100 is running."
fi

# Check if the cloudflared service inside the LXC container is running
echo "Checking if the cloudflared service is running inside LXC container 100..."
if ! timeout $TIMEOUT /usr/sbin/pct exec 100 -- /bin/systemctl is-active --quiet cloudflared; then
    echo "Cloudflared service in LXC 100 is down. Rebooting server."
    /sbin/reboot
    exit 0
else
    echo "Cloudflared service in LXC container 100 is running."
fi

# Check network connectivity
echo "Checking network connectivity..."
if ! timeout $TIMEOUT /bin/ping -c 1 -W 2 1.1.1.1 > /dev/null 2>&1; then
    echo "Network seems down. Rebooting server."
    /sbin/reboot
    exit 0
else
    echo "Network connectivity is fine."
fi

# If all checks pass
echo "All checks passed. No reboot required."
exit 0
EOF
status_message success "Script written to $SCRIPT_PATH."

# Make the script executable
chmod +x "$SCRIPT_PATH" && status_message success "Script made executable."

# Add the cron job if not already present
if ! grep -q "$SCRIPT_PATH" "$CRON_FILE" 2>/dev/null; then
    echo "$CRON_JOB" > "$CRON_FILE" && status_message success "Cron job added to $CRON_FILE."
else
    status_message success "Cron job already exists. Skipping."
fi

# Ensure cron service is running
if ! systemctl is-active --quiet cron; then
    systemctl start cron && status_message success "Cron service started."
    systemctl enable cron && status_message success "Cron service enabled on boot."
else
    status_message success "Cron service is already running."
fi

echo "Setup complete. The script is installed and scheduled to run every 5 minutes."

