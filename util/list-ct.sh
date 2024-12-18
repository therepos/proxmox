#!/bin/bash

# bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/util/list-ct.sh)"
# bash -c "$(curl -fsSL https://github.com/therepos/proxmox/raw/main/util/list-ct.sh)"

echo "Listing container and VM IPs with detected access ports and statuses:"
echo "-------------------------------------------------------------"

# Helper function to detect web-accessible ports dynamically
detect_web_ports() {
    ID=$1
    IS_CONTAINER=$2
    if [ "$IS_CONTAINER" = "true" ]; then
        # For containers
        WEB_PORTS=$(pct exec "$ID" -- ss -tuln 2>/dev/null | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | sort -n | uniq)
    else
        # For VMs
        WEB_PORTS=$(qm guest exec "$ID" -- ss -tuln 2>/dev/null | jq -r '.["out-data"]' | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | sort -n | uniq)
    fi

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
pct list | awk 'NR > 1 {print $1, $2}' | while read CTID STATUS; do
    # Get the container's IP
    IP=$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -z "$IP" ] && IP="No IP Assigned"

    # Detect web ports
    PORTS=$(detect_web_ports "$CTID" "true")

    # Output
    echo "CT $CTID: Status=$STATUS, IP=$IP, Access Ports=$PORTS"
done

echo ""
echo "VMs:"
qm list | awk 'NR > 1 {print $1, $3}' | while read VMID STATUS; do
    # Check if the guest agent is responding
    if qm guest exec "$VMID" -- echo "Guest Agent OK" >/dev/null 2>&1; then
        # Extract and clean raw out-data
        RAW_DATA=$(qm guest exec "$VMID" -- ip -4 -o addr show 2>/dev/null | jq -r '.["out-data"]' | sed 's/\\//g')

        # Parse for the primary external IP (exclude loopback and internal IPs)
        IP=$(echo "$RAW_DATA" | awk '!/127\.0\.0\.1/ && /inet / && !/(hassio|docker0)/ {print $4}' | cut -d/ -f1 | head -n 1)

        if [ -z "$IP" ]; then
            IP="No IP Assigned"
        fi

        # Detect web-accessible ports dynamically
        WEB_PORTS=$(qm guest exec "$VMID" -- ss -tuln 2>/dev/null | jq -r '.["out-data"]' | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | grep -E '^(80|443|8080|8443|8000|8081|3000|9090|[1-9][0-9]{3,4})$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')

        if [ -z "$WEB_PORTS" ]; then
            WEB_PORTS="No Recognized Web Ports"
        fi
    else
        # If the guest agent is not available, set defaults
        IP="Guest Agent Unavailable"
        WEB_PORTS="No Recognized Web Ports"
    fi

    # Output
    echo "VM $VMID: Status=$STATUS, IP=$IP, Access Ports=$WEB_PORTS"
done

echo "Services:"
systemctl list-units --type=service --state=running | awk 'NR > 1 {printf "Service: %s, Status: %s\\n", $1, $4}'

echo "-------------------------------------------------------------"
