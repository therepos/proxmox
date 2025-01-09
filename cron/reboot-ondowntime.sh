#!/bin/bash
# reboot proxmox if cloudflared lxc service is down
# via shell:
# chmod +x /usr/local/bin/reboot-ondowntime.sh
# via crontab-ui:
# command: /usr/local/bin/reboot-ondowntime.sh >> /var/log/reboot-ondowntime.log 2>&1
# schedule: /5 * * * *

# Timeout for commands
TIMEOUT=10

# Check if the LXC container (ID 100) is running
if ! timeout $TIMEOUT pct status 100 | grep -q "status: running"; then
    echo "LXC container 100 is not running. Rebooting server."
    /sbin/reboot
    exit 0
fi

# Check if the cloudflared service inside the LXC container is running
if ! timeout $TIMEOUT pct exec 100 -- systemctl is-active --quiet cloudflared; then
    echo "Cloudflared service in LXC 100 is down. Rebooting server."
    /sbin/reboot
    exit 0
fi

# Add more checks if necessary, e.g., network connectivity
if ! timeout $TIMEOUT ping -c 1 -W 2 1.1.1.1 > /dev/null 2>&1; then
    echo "Network seems down. Rebooting server."
    /sbin/reboot
    exit 0
fi

# If all checks pass, exit without rebooting
exit 0
