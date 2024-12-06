#!/usr/bin/env bash
source <(curl -s https://raw.githubusercontent.com/therepos/proxmox/main/vscodeserver.sh)

variables() {
  LXC_NAME=$(echo ${APP,,} | tr -d ' ') # This function sets the LXC_NAME variable by converting the value of the APP variable to lowercase and removing any spaces.
  SVC_NAME=$(echo ${SVC,,} | tr -d ' ') # This function sets the SVC_NAME variable by converting the value of the SVC variable to lowercase and removing any spaces.
}

msg_info() {
    echo -e "ℹ️  $1"
}

msg_ok() {
    echo -e "✅  $1"
}

msg_error() {
    echo -e "❌  $1"
}

# Step 1: Stop and Destroy LXC Container
msg_info "Stopping LXC container: $LXC_NAME"
if pct status $LXC_NAME &>/dev/null; then
    pct stop $LXC_NAME && msg_ok "Stopped LXC container" || msg_error "Failed to stop LXC container"
    pct destroy $LXC_NAME && msg_ok "Destroyed LXC container" || msg_error "Failed to destroy LXC container"
else
    msg_ok "LXC container $LXC_NAME not found"
fi

# Step 2: Clean Up Container Files
msg_info "Cleaning up container files"
STORAGE_PATH=$(pvesm list local | grep $LXC_NAME | awk '{print $2}')
if [ -n "$STORAGE_PATH" ]; then
    rm -rf "$STORAGE_PATH" && msg_ok "Removed storage files from $STORAGE_PATH" || msg_error "Failed to remove storage files from $STORAGE_PATH"
else
    msg_ok "No residual storage files found for $LXC_NAME"
fi

# Step 3: Remove Additional Configurations and Logs
msg_info "Removing residual configuration and logs"
rm -rf /etc/pve/lxc/$LXC_NAME.conf /var/lib/lxc/$LXC_NAME /var/log/lxc/$LXC_NAME*
msg_ok "Removed configuration and log files"

# Step 4: Reload Proxmox Services to Apply Changes
msg_info "Reloading Proxmox services"
systemctl restart pvedaemon pveproxy pvestatd && msg_ok "Proxmox services reloaded" || msg_error "Failed to reload Proxmox services"

# Step 5: Final Confirmation
msg_ok "Clean uninstallation of container $LXC_NAME completed successfully"
