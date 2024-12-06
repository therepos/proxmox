#!/bin/bash

echo "Listing IPs and web-accessible ports for Containers and VMs:"
echo "-------------------------------------------------------------"

# List all containers (CTs)
echo "Containers:"
pct list | awk 'NR > 1 {print $1}' | while read CTID; do
    # Get the container's IP address
    IP=$(pct exec $CTID -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    
    # Fallback for containers with no IP
    if [ -z "$IP" ]; then
        IP="No IP Assigned"
    fi

    # Get the open ports in the container and filter for web-accessible ports
    PORTS=$(pct exec $CTID -- ss -tuln 2>/dev/null | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | grep -E '^(80|443|8080|8443)$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')

    # Fallback for containers with no web-accessible ports
    if [ -z "$PORTS" ]; then
        PORTS="No Web Ports Open"
    fi

    # Display the container ID, IP, and filtered ports
    echo "CT $CTID: IP=$IP, Web Ports=[$PORTS]"
done

echo ""
echo "VMs:"
# List all VMs
qm list | awk 'NR > 1 {print $1}' | while read VMID; do
    # Get the VM's IP address using the guest agent
    IP=$(qm guest exec $VMID -- ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    
    # Fallback for VMs with no IP
    if [ -z "$IP" ]; then
        IP="No IP Assigned"
    fi

    # Get the open ports in the VM and filter for web-accessible ports
    PORTS=$(qm guest exec $VMID -- ss -tuln 2>/dev/null | awk 'NR > 1 {print $5}' | grep -oE '[0-9]+$' | grep -E '^(80|443|8080|8443)$' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')

    # Fallback for VMs with no web-accessible ports
    if [ -z "$PORTS" ]; then
        PORTS="No Web Ports Open"
    fi

    # Display the VM ID, IP, and filtered ports
    echo "VM $VMID: IP=$IP, Web Ports=[$PORTS]"
done

echo "-------------------------------------------------------------"
