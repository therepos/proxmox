#!/usr/bin/env bash

source <(curl -s https://raw.githubusercontent.com/therepos/proxmox/main/vscodeserver.sh)

# Transform APP and SVC to lowercase and remove spaces
variables() {
  LXC_NAME=$(echo ${APP,,} | tr -d ' ')
  SVC_NAME=$(echo ${SVC,,} | tr -d ' ')
}

msg_info() { echo -e "ℹ️  $1"; }
msg_ok() { echo -e "✅  $1"; }
msg_error() { echo -e "❌  $1"; }

# Ensure variables are set
if [ -z "$APP" ] || [ -z "$SVC" ]; then
    msg_error "Required variables (APP, SVC) not loaded from vscodeserver.sh."
    exit 1
fi

# Step 1: Stop Associated Service
msg_info "Stopping service: $SVC_NAME"
if systemctl is-active --quiet "$SVC_NAME"; then
    systemctl stop "$SVC_NAME" && msg_ok "Stopped $SVC_NAME service" || msg_error "Failed to stop $SVC_NAME service"
else
    msg_ok "Service $SVC_NAME is not running"
fi

# Step 2: Stop and Destroy LXC Container
msg_info "Stopping LXC container: $LXC_NAME"
if pct status "$LXC_NAME" &>/dev/null; then
    pct stop "$LXC_NAME" && msg_ok "Stopped LXC container" || msg_error "Failed to stop LXC container"
    pct destroy "$LXC_NAME" && msg_ok "Destroyed LXC container" || msg_error "Failed to destroy LXC container"
else
    msg_ok "LXC container $LXC_NAME not found"
fi

# Step 3: Detect and Free Storage
msg_info "Detecting storage volumes for $LXC_NAME"
for STORAGE in $(pvesm list | grep "$LXC_NAME" | awk '{print $1}'); do
    msg_info "Freeing storage volume: $STORAGE"
    pvesm free "$STORAGE" && msg_ok "Freed $STORAGE" || msg_error "Failed to free $STORAGE"
done

# Step 4: Remove Configuration and Log Files
msg_info "Removing residual configuration and logs"
[ -f /etc/pve/lxc/$LXC_NAME.conf ] && rm -f /etc/pve/lxc/$LXC_NAME.conf && msg_ok "Removed configuration file" || msg_ok "Configuration file not found"
[ -d /var/lib/lxc/$LXC_NAME ] && rm -rf /var/lib/lxc/$LXC_NAME && msg_ok "Removed LXC directory" || msg_ok "LXC directory not found"
[ -d /var/log/lxc/ ] && rm -f /var/log/lxc/$LXC_NAME* && msg_ok "Removed LXC logs" || msg_ok "LXC logs not found"

# Step 5: Reload Proxmox Services
msg_info "Reloading Proxmox services"
systemctl restart pvedaemon pveproxy pvestatd && msg_ok "Proxmox services reloaded" || msg_error "Failed to reload Proxmox services"

msg_ok "Clean uninstallation of container $LXC_NAME completed successfully"
