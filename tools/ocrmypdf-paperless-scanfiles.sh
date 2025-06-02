#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ocrmypdf-scanfiles.sh?$(date +%s))"
# purpose: ocr scans files from the input folder to the output folder

INPUT_DIR="/mnt/sec/apps/ocrmypdf/input"
OUTPUT_DIR="/mnt/sec/apps/ocrmypdf/output"

# Ensure the input directory exists
if [ ! -d "$INPUT_DIR" ]; then
  echo "Input directory $INPUT_DIR does not exist!"
  exit 1
fi

# Process all PDF files in the input folder
for filename in "$INPUT_DIR"/*.pdf; do
  # Skip if no PDF files exist
  if [ ! -f "$filename" ]; then
    echo "No PDF files found in $INPUT_DIR."
    break
  fi

  echo "Processing file: $filename"

  # Run ocrmypdf on the input file and save it to the output directory
  docker run -i --rm jbarlow83/ocrmypdf - - < "$filename" > "$OUTPUT_DIR/$(basename "$filename")"

  # Remove the original file after processing
  rm "$filename"
  echo "$filename has been OCR processed and removed from the input folder."
done
