#!/usr/bin/env bash
msg_info() {
    echo -e "ℹ️  $1"
}

msg_ok() {
    echo -e "✅  $1"
}

msg_error() {
    echo -e "❌  $1"
}

msg_info "Stopping code-server service"
if systemctl is-active --quiet code-server.service; then
    systemctl stop code-server.service && msg_ok "Stopped code-server service" || msg_error "Failed to stop code-server service"
else
    msg_ok "code-server service is not running"
fi

msg_info "Disabling code-server service"
if systemctl is-enabled --quiet code-server.service; then
    systemctl disable code-server.service && msg_ok "Disabled code-server service" || msg_error "Failed to disable code-server service"
else
    msg_ok "code-server service is not enabled"
fi

msg_info "Removing code-server binary"
if [ -f "/opt/code-server/code-server" ]; then
    rm -rf /opt/code-server && msg_ok "Removed /opt/code-server directory"
else
    msg_ok "Binary in /opt/code-server not found"
fi

if [ -f "/usr/bin/code-server" ]; then
    rm -f /usr/bin/code-server && msg_ok "Removed /usr/bin/code-server binary"
else
    msg_ok "Binary in /usr/bin/code-server not found"
fi

msg_info "Removing code-server systemd service"
if [ -f "/etc/systemd/system/code-server.service" ]; then
    rm -f /etc/systemd/system/code-server.service && msg_ok "Removed systemd service file"
else
    msg_ok "Systemd service file not found"
fi

msg_info "Cleaning up cache and logs"
rm -rf ~/.cache/code-server ~/.config/code-server /var/log/code-server*
msg_ok "Removed cache and logs"

msg_info "Reloading systemd daemon"
systemctl daemon-reload && msg_ok "Reloaded systemd daemon" || msg_error "Failed to reload systemd daemon"

msg_ok "VS Code Server has been uninstalled successfully"
