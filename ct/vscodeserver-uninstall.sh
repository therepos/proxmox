#!/usr/bin/env bash

LXC_NAME="vscodeserver"
SVC_NAME="code-server"

msg_info() { echo -e "ℹ️  $1"; }
msg_ok() { echo -e "✅  $1"; }
msg_error() { echo -e "❌  $1"; }

# Step 1: Stop Associated Service
msg_info "Stopping service: $SVC_NAME"
if systemctl is-active --quiet "$SVC_NAME"; then
    systemctl stop "$SVC_NAME" && msg_ok "Stopped $SVC_NAME service" || msg_error "Failed to stop $SVC_NAME service"
else
    msg_ok "Service $SVC_NAME is not running"
fi

# Step 2: Stop and Destroy LXC Container
if pct status "$LXC_NAME" &>/dev/null; then
    pct stop "$LXC_NAME" && msg_ok "Stopped LXC container" || msg_error "Failed to stop LXC container"
    pct destroy "$LXC_NAME" && msg_ok "Destroyed LXC container" || {
        msg_error "Failed to destroy LXC container; attempting force cleanup"
        rm -rf /var/lib/lxc/$LXC_NAME
        rm -f /etc/pve/lxc/$LXC_NAME.conf
        rm -f /var/log/lxc/$LXC_NAME*
        msg_ok "Force cleaned container $LXC_NAME"
    }
else
    msg_ok "LXC container $LXC_NAME not found"
fi

# Step 3: Detect and Free Storage
msg_info "Detecting storage volumes for $LXC_NAME"
STORAGES=$(pvesm status -content rootdir | awk 'NR>1 {print $1}')
if [ -z "$STORAGES" ]; then
    msg_ok "No storage volumes found for $LXC_NAME"
else
    for STORAGE in $STORAGES; do
        msg_info "Checking storage: $STORAGE for volumes related to $LXC_NAME"
        VOLUMES=$(pvesm list $STORAGE | grep "$LXC_NAME" | awk '{print $1}')
        for VOLUME in $VOLUMES; do
            msg_info "Freeing storage volume: $VOLUME in $STORAGE"
            pvesm free $VOLUME && msg_ok "Freed $VOLUME" || msg_error "Failed to free $VOLUME"
        done
    done
fi

# Step 4: Remove Configuration and Log Files
msg_info "Removing residual configuration and logs"
[ -f /etc/pve/lxc/$LXC_NAME.conf ] && rm -f /etc/pve/lxc/$LXC_NAME.conf && msg_ok "Removed configuration file" || msg_ok "Configuration file not found"
[ -d /var/lib/lxc/$LXC_NAME ] && rm -rf /var/lib/lxc/$LXC_NAME && msg_ok "Removed LXC directory" || msg_ok "LXC directory not found"
[ -d /var/log/lxc/ ] && rm -f /var/log/lxc/$LXC_NAME* && msg_ok "Removed LXC logs" || msg_ok "LXC logs not found"

msg_ok "Clean uninstallation of container $LXC_NAME completed successfully"
