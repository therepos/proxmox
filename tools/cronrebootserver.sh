#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/cronrebootserver.sh)"

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to display status messages with color
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# Step 1: Write the check_cloudflared_pct.sh script to the necessary directory
status_message "success" "Writing the check_cloudflared_pct.sh script to /usr/local/bin..."

cat <<'EOF' > /usr/local/bin/check_cloudflared_pct.sh
#!/bin/bash

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Function to display status messages with color
function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# Set the Proxmox container ID (replace with your actual container ID)
PCT_CONTAINER_ID="100"  # Replace with your container ID

# Grace period of 30 minutes (1800 seconds)
GRACE_PERIOD=1800
CURRENT_TIME=$(date +%s)

# Get the last time the service was active using systemctl
LAST_ACTIVE_TIME=$(pct exec $PCT_CONTAINER_ID -- systemctl show cloudflared --property=ActiveEnterTimestamp --value)

# Convert the time to seconds since epoch
LAST_ACTIVE_SECONDS=$(date -d "$LAST_ACTIVE_TIME" +%s)

# Calculate the time difference between now and the last active time
TIME_DIFF=$((CURRENT_TIME - LAST_ACTIVE_SECONDS))

# Check if cloudflared is running inside the container
if ! pct exec $PCT_CONTAINER_ID -- pgrep -x "cloudflared" > /dev/null
then
    status_message "failure" "Cloudflared is not running inside the container."

    # If the service has been down for at least 30 minutes, reboot the Proxmox host
    if [ $TIME_DIFF -ge $GRACE_PERIOD ]; then
        status_message "failure" "Cloudflared has been down for at least 30 minutes. Rebooting Proxmox host."
        /sbin/reboot
    else
        status_message "success" "Cloudflared has been down for less than 30 minutes. Skipping reboot."
    fi
else
    status_message "success" "Cloudflared is running inside the container."
fi
EOF

# Step 2: Make the script executable
status_message "success" "Making the script executable..."
chmod +x /usr/local/bin/check_cloudflared_pct.sh

# Step 3: Set up the cron job to run the script every 2 minutes
status_message "success" "Setting up the cron job to run the script every 2 minutes..."

# Add the cron job to the root crontab
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/check_cloudflared_pct.sh") | crontab -

# Step 4: Confirmation message
status_message "success" "The script has been written to /usr/local/bin, made executable, and the cron job has been set up to run every 2 minutes."

# Optional: Print the current cron jobs to verify
echo "Current cron jobs:"
crontab -l