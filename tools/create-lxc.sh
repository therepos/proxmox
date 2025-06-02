#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/create-lxc.sh?$(date +%s))"
# purpose: creates an empty lxc container

# Variables for customization
DISK_SIZE="4"                 # Disk size in GB
CORES="2"                     # Number of cores
MEMORY="1024"                 # Memory size in MB
PASSWORD="password"           # Default root password
BRIDGE="vmbr0"                # Network bridge
TEMPLATE_DIR="/var/lib/vz/template/cache"
DHCP="1"                      # Enable DHCP (1 for true, 0 for false)
FIREWALL="0"                  # Disable firewall (1 for true, 0 for false)
FEATURES="nesting=1"          # Enable nesting for containers

# Function to find the latest Debian template
get_latest_debian_template() {
    find "$TEMPLATE_DIR" -type f -name "debian*.tar.*" | sort -r | head -n 1
}

# Function to dynamically determine storage for LXC containers
get_lxc_storage() {
    for storage in $(pvesm status | awk '/active/ {print $1}'); do
        if pvesm list $storage | grep -q rootdir; then
            echo "$storage"
            return
        fi
    done
    echo "No storage found for LXC containers. Exiting." >&2
    exit 1
}

# Main script
read -p "Enter hostname for the container: " HOSTNAME
if [[ -z "$HOSTNAME" ]]; then
    echo "Hostname cannot be empty. Exiting."
    exit 1
fi

TEMPLATE=$(get_latest_debian_template)
if [[ -z "$TEMPLATE" ]]; then
    echo "No Debian template found in $TEMPLATE_DIR. Exiting."
    exit 1
fi

STORAGE=$(get_lxc_storage)
if [[ -z "$STORAGE" ]]; then
    echo "No valid storage detected. Exiting."
    exit 1
fi

# Generate a unique container ID
CTID=$(pvesh get /cluster/nextid)

# Create the LXC container
echo "Creating LXC container with CTID $CTID and hostname $HOSTNAME on storage $STORAGE..."

pct create $CTID "$TEMPLATE" \
    -storage "$STORAGE" \
    -hostname "$HOSTNAME" \
    -cores "$CORES" \
    -memory "$MEMORY" \
    -net0 name=eth0,bridge="$BRIDGE",ip=dhcp,firewall=$FIREWALL \
    -password "$PASSWORD" \
    -rootfs "$STORAGE:$DISK_SIZE" \
    --features "$FEATURES" \
    --unprivileged 1

if [[ $? -eq 0 ]]; then
    echo "LXC container $CTID created successfully."
else
    echo "Failed to create LXC container."
    exit 1
fi

# Start the container
echo "Starting container $CTID..."
pct start $CTID

if [[ $? -eq 0 ]]; then
    echo "Container $CTID started successfully."
else
    echo "Failed to start container $CTID."
    exit 1
fi

echo "LXC container setup complete."
