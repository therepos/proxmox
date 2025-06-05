#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/ocrmypdf-scantopaperless.sh?$(date +%s))"
# purpose: ocr scans files from ocrmypdf folder to paperless-ngx consume folder

# Define script URLs (Replace with your actual GitHub repository URLs)
OCR_SCRIPT_URL="https://github.com/therepos/proxmox/raw/main/apps/tools/ocrmypdf-paperless-scanfiles.sh"
MOVE_SCRIPT_URL="https://github.com/therepos/proxmox/raw/main/apps/tools/ocrmypdf-paperless-movefiles.sh"

# Fetch and run the OCR process script
echo "Starting OCR process..."
bash -c "$(wget -qO- "$OCR_SCRIPT_URL")"
if [ $? -ne 0 ]; then
  echo "OCR process failed. Exiting."
  exit 1
fi

# Fetch and run the move-to-Paperless script
echo "Moving processed files to Paperless consume folder..."
bash -c "$(wget -qO- "$MOVE_SCRIPT_URL")"
if [ $? -ne 0 ]; then
  echo "Moving files to Paperless failed. Exiting."
  exit 1
fi

echo "OCR and file transfer process completed successfully."
