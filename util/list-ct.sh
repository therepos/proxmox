#!/bin/bash

# wget --no-cache -qLO- https://github.com/therepos/proxmox/raw/main/util/list-ct.sh | bash
# curl -fsSL https://github.com/therepos/proxmox/raw/main/util/list-ct.sh | bash

echo "$(date)"
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
printf "%-40s %-15s %-40s %-10s\n" "Container" "IP" "Access Ports" "Status"
pct list | awk 'NR > 1 {print $1, $2}' | while read CTID STATUS; do
    IP=$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -z "$IP" ] && IP="No IP Assigned"
    PORTS=$(detect_web_ports "$CTID" "true")
    printf "%-40s %-15s %-40s %-10s\n" "CT $CTID" "$IP" "$PORTS" "$STATUS"
done
echo ""
echo "-------------------------------------------------------------"

echo ""
# VMs
printf "%-40s %-15s %-40s %-10s\n" "VM" "IP" "Access Ports" "Status"
qm list | awk 'NR > 1 {print $1, $3}' | while read VMID STATUS; do
    # Check if the guest agent is responding
    if qm guest exec "$VMID" -- echo "Guest Agent OK" >/dev/null 2>&1; then
        # Extract and clean raw out-data
        RAW_DATA=$(qm guest exec "$VMID" -- ip -4 -o addr show 2>/dev/null | jq -r '."out-data"' | sed 's/\\//g')

        # Parse for the primary external IP (exclude loopback and internal IPs)
        IP=$(echo "$RAW_DATA" | awk '!/127\.0\.0\.1/ && /inet / && !/(hassio|docker0)/ {print $4}' | cut -d/ -f1 | head -n 1)

        if [ -z "$IP" ]; then
            IP="No IP Assigned"
        fi

        # Detect web-accessible ports dynamically
        WEB_PORTS=$(qm guest exec "$VMID" -- ss -tuln 2>/dev/null | jq -r '."out-data"' | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | grep -E '^(80|443|8080|8443|8000|8081|3000|9090|[1-9][0-9]{3,4})$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')

        if [ -z "$WEB_PORTS" ]; then
            WEB_PORTS="No Recognized Web Ports"
        fi
    else
        # If the guest agent is not available, set defaults
        IP="Guest Agent Unavailable"
        WEB_PORTS="No Recognized Web Ports"
    fi

    # Output
    printf "%-40s %-15s %-40s %-10s\n" "VM $VMID" "$IP" "$WEB_PORTS" "$STATUS"
done
echo ""
echo "-------------------------------------------------------------"

echo ""
# Dockers
printf "%-40s %-15s %-40s %-10s\n" "Docker" "IP" "Access Ports" "Status"
docker ps --format '{{.Names}} {{.ID}} {{.State}} {{.Ports}}' | while read NAME ID STATE PORTS; do
    IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$ID")
    [ -z "$IP" ] && IP="No IP Assigned"
    FORMATTED_PORTS=$(echo "$PORTS" | grep -oE '[0-9]+/tcp' | cut -d/ -f1 | tr '\n' ',' | sed 's/,$//')
    [ -z "$FORMATTED_PORTS" ] && FORMATTED_PORTS="No Recognized Ports"
    printf "%-40s %-15s %-40s %-10s\n" "$NAME" "$IP" "$FORMATTED_PORTS" "$STATE"
done
echo ""
echo "-------------------------------------------------------------"

echo ""
# Services
printf "%-40s %-15s %-40s %-10s\n" "Service" "IP" "Access Ports" "Status"
systemctl list-units --type=service --state=running | awk 'NR > 1 && NF > 1 {print $1}' | while read SERVICE; do
    # Skip invalid entries or empty lines
    if [[ ! $SERVICE =~ \.service$ ]]; then
        continue
    fi

    # Get IP of the Proxmox host
    IP=$(hostname -I | awk '{print $1}')
    [ -z "$IP" ] && IP="Unknown"

    # Detect access ports dynamically
    # Step 1: Try ss for ports associated with the service name
    PORTS=$(ss -tulnp | grep -i "$SERVICE" | awk '{print $5}' | awk -F':' '{print $NF}' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')

    # Step 2: Fallback to PID-based detection if no ports found
    if [ -z "$PORTS" ]; then
        PID=$(systemctl show --property=MainPID "$SERVICE" | awk -F= '{print $2}')
        if [ -n "$PID" ] && [ "$PID" -gt 0 ]; then
            PORTS=$(ss -tulnp | grep "$PID" | awk '{print $5}' | awk -F':' '{print $NF}' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
        fi
    fi

    # Step 3: Fallback to lsof if still no ports found
    if [ -z "$PORTS" ]; then
        PORTS=$(lsof -i -P -n | grep "$SERVICE" | awk -F':' '{print $2}' | awk '{print $1}' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
    fi

    # If no ports are detected, mark as Unknown
    [ -z "$PORTS" ] && PORTS="Unknown"

    # Get service status
    STATUS=$(systemctl is-active "$SERVICE")

    # Format output as a table
    printf "%-40s %-15s %-40s %-10s\n" "$SERVICE" "$IP" "$PORTS" "$STATUS"
done
echo ""
echo "-------------------------------------------------------------"
