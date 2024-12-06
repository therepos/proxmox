#!/bin/bash

# bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/main/util/list-ct.sh)"
# bash -c "$(curl -fsSL https://github.com/therepos/proxmox/main/util/list-ct.sh)"

echo "Listing container IPs and open ports:"
echo "-------------------------------------------"

# Get a list of all container IDs
pct list | awk 'NR > 1 {print $1}' | while read CTID; do
    # Get the container's IP address
    IP=$(pct exec $CTID -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    
    # Fallback for containers with no IP
    if [ -z "$IP" ]; then
        IP="No IP Assigned"
    fi

    # Get the open ports in the container
    PORTS=$(pct exec $CTID -- ss -tuln 2>/dev/null | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')

    # Fallback for containers with no open ports
    if [ -z "$PORTS" ]; then
        PORTS="No Ports Open"
    fi

    # Display the container ID, IP, and open ports
    echo "CT $CTID: IP=$IP, Ports=[$PORTS]"
done

echo "-------------------------------------------"
