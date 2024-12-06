#!/bin/bash

# bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/util/list-ct.sh)"
# bash -c "$(curl -fsSL https://github.com/therepos/proxmox/raw/main/util/list-ct.sh)"

echo "Listing container and VM IPs with detected access ports:"
echo "-------------------------------------------------------------"

# Helper function to detect web-accessible ports dynamically
detect_web_ports() {
    CTID=$1
    # Check for open ports and filter likely web-related ports
    WEB_PORTS=$(pct exec "$CTID" -- ss -tuln 2>/dev/null | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | sort -n | uniq)
    
    # Narrow down to ports typically used for web access
    FILTERED_PORTS=$(echo "$WEB_PORTS" | grep -E '^(80|443|8080|8443|8000|8081|3000|9090|[1-9][0-9]{3,4})$' | tr '\n' ',' | sed 's/,$//')
    
    if [ -z "$FILTERED_PORTS" ]; then
        echo "No Recognized Web Ports"
    else
        echo "$FILTERED_PORTS"
    fi
}

# Containers
echo "Containers:"
pct list | awk 'NR > 1 {print $1}' | while read CTID; do
    # Get the container's IP
    IP=$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -z "$IP" ] && IP="No IP Assigned"

    # Detect web ports
    PORTS=$(detect_web_ports "$CTID")

    # Output
    echo "CT $CTID: IP=$IP, Access Ports=$PORTS"
done

echo ""
echo "VMs:"
qm list | awk 'NR > 1 {print $1}' | while read VMID; do
    # Check if the guest agent is responding
    if qm guest exec "$VMID" -- echo "Guest Agent OK" >/dev/null 2>&1; then
        # Extract and clean raw out-data
        RAW_DATA=$(qm guest exec "$VMID" -- ip -4 -o addr show 2>/dev/null | jq -r '.["out-data"]' | sed 's/\\//g')

        # Parse for the primary external IP (exclude loopback and internal IPs)
        IP=$(echo "$RAW_DATA" | awk '!/127\.0\.0\.1/ && /inet / && !/(hassio|docker0)/ {print $4}' | cut -d/ -f1 | head -n 1)

        if [ -z "$IP" ] || [ "$IP" = "127.0.0.1" ]; then
            IP="No IP Assigned"
        fi

        # Detect web-accessible ports dynamically
        WEB_PORTS=$(qm guest exec "$VMID" -- ss -tuln 2>/dev/null | jq -r '.["out-data"]' | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | grep -E '^(80|443|8080|8443|8000|8081|3000|9090|[1-9][0-9]{3,4})$' | tr '\n' ',' | sed 's/,$//')
        if [ -z "$WEB_PORTS" ]; then
            WEB_PORTS="No Recognized Web Ports"
        fi
    else
        # If the guest agent is not available, set defaults
        IP="Guest Agent Unavailable"
        WEB_PORTS="No Recognized Web Ports"
    fi

    # Output
    echo "VM $VMID: IP=$IP, Access Ports=$WEB_PORTS"
done

echo "-------------------------------------------------------------"
