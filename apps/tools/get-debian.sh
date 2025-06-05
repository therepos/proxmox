#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/install-debian.sh?$(date +%s))"
# purpose: downloads the latest debian ISO

# Variables
ISO_STORAGE="local"       # Storage where the ISO is stored
ISO_DIR="/var/lib/vz/template/iso"  # Directory for ISO storage

# Function to detect or download the latest ISO
find_or_download_iso() {
    echo "Searching for a local Debian ISO file..."
    local_iso=$(find "$ISO_DIR" -type f -name "debian-*.iso" -size +0c | sort | tail -n 1)

    if [ -z "$local_iso" ]; then
        echo "No valid local Debian ISO file found. Downloading the latest ISO..."
        local latest_iso_url
        latest_iso_url=$(curl -s https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | \
            grep -oP 'href="debian-\d+\.\d+\.\d+-amd64-netinst\.iso"' | cut -d'"' -f2 | sort -V | tail -n 1)
        curl -o "$ISO_DIR/$latest_iso_url" "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$latest_iso_url"
        local_iso="$ISO_DIR/$latest_iso_url"
    fi

    echo "Using local Debian ISO: $local_iso"
    echo "$local_iso"
}

# Detect or download ISO
ISO_FILE=$(find_or_download_iso)
