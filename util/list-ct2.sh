#!/bin/bash

# bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/util/list-ct2.sh)"
# bash -c "$(curl -fsSL https://github.com/therepos/proxmox/raw/main/util/list-ct2.sh)"

echo "$(date)"
echo "Containers:"
# Headers for container output
printf "%-40s %-20s %-30s %-15s\n" "Container" "IP" "Access Ports" "Status"
pct list | awk 'NR > 1 {print $1, $2}' | while read CTID STATUS; do
    # Get the container's IP
    IP=$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -z "$IP" ] && IP="Unknown"

    # Detect web ports
    PORTS=$(pct exec "$CTID" -- ss -tuln 2>/dev/null | awk 'NR > 1 {print $5}' | awk -F':' '{print $NF}' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
    [ -z "$PORTS" ] && PORTS="Unknown"

    # Print aligned container information
    printf "%-40s %-20s %-30s %-15s\n" "CT $CTID" "$IP" "$PORTS" "$STATUS"
done

echo ""
echo "VMs:"
# Headers for VM output
printf "%-40s %-20s %-30s %-15s\n" "VM" "IP" "Access Ports" "Status"
qm list | awk 'NR > 1 {print $1, $3}' | while read VMID STATUS; do
    # Check if the guest agent is responding
    if qm guest exec "$VMID" -- echo "Guest Agent OK" >/dev/null 2>&1; then
        # Extract IP from guest
        IP=$(qm guest exec "$VMID" -- ip -4 -o addr show 2>/dev/null | awk '!/127\\.0\\.0\\.1/ {print $4}' | cut -d/ -f1 | head -n 1)
        [ -z "$IP" ] && IP="Unknown"

        # Detect web ports dynamically
        PORTS=$(qm guest exec "$VMID" -- ss -tuln 2>/dev/null | awk 'NR > 1 {print $5}' | awk -F':' '{print $NF}' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
        [ -z "$PORTS" ] && PORTS="Unknown"
    else
        # If guest agent is unavailable
        IP="Guest Agent Unavailable"
        PORTS="Unknown"
    fi

    # Print VM information
    printf "%-40s %-20s %-30s %-15s\n" "VM $VMID" "$IP" "$PORTS" "$STATUS"
done
