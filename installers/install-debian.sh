#!/bin/bash

# URL of the ISO file
ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.1.0-amd64-netinst.iso"

# Destination directory (Proxmox ISO storage)
DEST_DIR="/var/lib/vz/template/iso"

# Download the ISO
echo "Downloading ISO file..."
wget -O "$DEST_DIR/debian.iso" "$ISO_URL"

# Verify the download
if [ $? -eq 0 ]; then
    echo "ISO downloaded successfully to $DEST_DIR."
else
    echo "Failed to download ISO."
    exit 1
fi
