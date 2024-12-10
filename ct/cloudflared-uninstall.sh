#!/usr/bin/env bash

# bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/ct/cloudflared-uninstall.sh)"
# bash -c "$(curl -fsSL https://github.com/therepos/proxmox/raw/main/ct/cloudflared-uninstall.sh)"

LXC_NAME="cloudflared"
SVC_NAME="cloudflared"

msg_info() { echo -e "ℹ️  $1"; }
msg_ok() { echo -e "✅  $1"; }
msg_error() { echo -e "❌  $1"; }

# Step 1: Detect VMID based on LXC_NAME
msg_info "Detecting VMID for LXC name: $LXC_NAME"
VMID=$(pct list | awk -v name="$LXC_NAME" '$3 == name {print $1}')
if [ -z "$VMID" ]; then
    msg_error "No container found with the name: $LXC_NAME"
    exit 1
fi
msg_ok "Detected container VMID: $VMID"

# Step 2: Stop Associated Service
msg_info "Stopping service: $SVC_NAME"
if systemctl is-active --quiet "$SVC_NAME"; then
    systemctl stop "$SVC_NAME" && msg_ok "Stopped $SVC_NAME service" || msg_error "Failed to stop $SVC_NAME service"
else
    msg_ok "Service $SVC_NAME is not running"
fi

# Step 3: Stop and Destroy LXC Container
msg_info "Stopping LXC container: $LXC_NAME (VMID: $VMID)"
if pct status "$VMID" &>/dev/null; then
    pct stop "$VMID" && msg_ok "Stopped LXC container" || msg_error "Failed to stop LXC container"
    pct destroy "$VMID" && msg_ok "Destroyed LXC container" || {
        msg_error "Failed to destroy LXC container; attempting force cleanup"
        rm -rf /var/lib/lxc/$VMID
        rm -f /etc/pve/lxc/$VMID.conf
        rm -f /var/log/lxc/$VMID*
        msg_ok "Force cleaned container $LXC_NAME"
    }
else
    msg_ok "LXC container $LXC_NAME not found"
fi

# Step 4: Detect and Free Storage
msg_info "Detecting storage volumes for VMID: $VMID"
STORAGES=$(pvesm status -content rootdir | awk 'NR>1 {print $1}')
if [ -z "$STORAGES" ]; then
    msg_ok "No storage volumes found for VMID: $VMID"
else
    for STORAGE in $STORAGES; do
        msg_info "Checking storage: $STORAGE for volumes related to VMID: $VMID"
        VOLUMES=$(pvesm list $STORAGE | grep "$VMID" | awk '{print $1}')
        for VOLUME in $VOLUMES; do
            msg_info "Freeing storage volume: $VOLUME in $STORAGE"
            pvesm free $VOLUME && msg_ok "Freed $VOLUME" || msg_error "Failed to free $VOLUME"
        done
    done
fi

# Step 5: Remove Configuration and Log Files
msg_info "Removing residual configuration and logs"
[ -f /etc/pve/lxc/$VMID.conf ] && rm -f /etc/pve/lxc/$VMID.conf && msg_ok "Removed configuration file" || msg_ok "Configuration file not found"
[ -d /var/lib/lxc/$VMID ] && rm -rf /var/lib/lxc/$VMID && msg_ok "Removed LXC directory" || msg_ok "LXC directory not found"
[ -d /var/log/lxc/ ] && rm -f /var/log/lxc/$VMID* && msg_ok "Removed LXC logs" || msg_ok "LXC logs not found"

msg_ok "Clean uninstallation of container $LXC_NAME (VMID: $VMID) completed successfully"
