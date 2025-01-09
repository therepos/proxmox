#!/bin/bash
# reboot proxmox if cloudflared lxc service is down
# via shell:
# chmod +x /usr/local/bin/reboot-ifdown.sh
# sed -i 's/\r//' /usr/local/bin/reboot-ifdown.sh
# via crontab-ui:
# command: /usr/local/bin/reboot-ifdown.sh >> /var/log/reboot-ifdown.log 2>&1
# schedule: */5 * * * * 
# check:
# journalctl -u cron

# reboot proxmox if cloudflared LXC service is down
# Logging setup
LOG_FILE="/var/log/reboot-ifdown.log"
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
