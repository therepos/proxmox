#!/bin/bash

# Base URL for Debian ISO
BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"

# Destination directory (Proxmox ISO storage)
DEST_DIR="/var/lib/vz/template/iso"

# Fetch the latest ISO file name
echo "Fetching the latest Debian ISO file..."
LATEST_ISO=$(curl -s $BASE_URL/ | grep -oP 'href="debian-\d+\.\d+\.\d+-amd64-netinst\.iso"' | cut -d'"' -f2 | sort -V | tail -n 1)

if [ -z "$LATEST_ISO" ]; then
    echo "Failed to determine the latest Debian ISO file."
    exit 1
fi

# Full URL for the latest ISO
ISO_URL="$BASE_URL/$LATEST_ISO"

# Output file name
OUTPUT_FILE="$DEST_DIR/$LATEST_ISO"

# Download the ISO
echo "Downloading $ISO_URL..."
curl -o "$OUTPUT_FILE" "$ISO_URL"

# Verify the download
if [ $? -eq 0 ]; then
    echo "ISO downloaded successfully to $OUTPUT_FILE."
else
    echo "Failed to download ISO."
    exit 1
fi
