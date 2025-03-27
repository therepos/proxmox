#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-swapfile.sh)"
# purpose: this script toggle swapfile to change available memory

SWAPFILE="/mnt/sec/swapfile"

enable_swap() {
  echo "Creating 16G swap file at $SWAPFILE..."
  dd if=/dev/zero of=$SWAPFILE bs=1G count=16 status=progress
  chmod 600 $SWAPFILE
  mkswap $SWAPFILE
  swapon $SWAPFILE
  echo "Swap enabled."
}

disable_swap() {
  echo "Disabling and removing swap..."
  swapoff $SWAPFILE
  rm -f $SWAPFILE
  echo "Swap disabled and file removed."
}

echo "Select an option:"
echo "1) Enable swap"
echo "2) Disable swap"
read -p "Enter choice [1 or 2]: " choice

case $choice in
  1)
    enable_swap
    ;;
  2)
    disable_swap
    ;;
  *)
    echo "Invalid choice."
    ;;
esac
