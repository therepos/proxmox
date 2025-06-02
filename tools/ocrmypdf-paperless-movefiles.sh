#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ocrmypdf-movefiles.sh?$(date +%s))"
# purpose: transfer files in the output folder to paperless-ngx consume folder

OUTPUT_DIR="/mnt/sec/apps/ocrmypdf/output"
PAPERLESS_CONSUME_DIR="/mnt/sec/apps/paperless/consume"

# Ensure the output directory exists
if [ ! -d "$OUTPUT_DIR" ]; then
  echo "Output directory $OUTPUT_DIR does not exist!"
  exit 1
fi

# Process all PDF files in the output folder
for filename in "$OUTPUT_DIR"/*.pdf; do
  # Skip if no PDF files exist
  if [ ! -f "$filename" ]; then
    echo "No PDF files found in $OUTPUT_DIR."
    break
  fi

  echo "Moving file to Paperless consume folder: $filename"

  # Move the file to the Paperless consume folder
  mv "$filename" "$PAPERLESS_CONSUME_DIR/$(basename "$filename")"
  echo "$filename has been moved to the Paperless consume folder."
done
