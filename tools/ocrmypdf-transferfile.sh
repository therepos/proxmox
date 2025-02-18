#!/bin/bash

OUTPUT_DIR="/mnt/sec/apps/ocrmypdf/output"
PAPERLESS_CONSUME_DIR="/mnt/sec/apps/paperless/consume"

# Wait for a 'close_write' event on PDF files in the output directory
inotifywait -m -e close_write --format "%f" "$OUTPUT_DIR" | while read filename
do
  # Check if the closed file is a PDF
  if [[ "$filename" == *.pdf ]]; then
    echo "File $filename is now closed and ready to be moved."

    # Move the file to the Paperless consume folder
    mv "$OUTPUT_DIR/$filename" "$PAPERLESS_CONSUME_DIR/$filename"
    echo "$filename has been moved to the Paperless consume folder."
  fi
done
