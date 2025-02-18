#!/bin/bash

INPUT_DIR="/mnt/sec/apps/ocrmypdf/input"
OUTPUT_DIR="/mnt/sec/apps/ocrmypdf/output"

# Wait for a 'close_write' event on PDF files in the input directory
inotifywait -m -e close_write --format "%f" "$INPUT_DIR" | while read filename
do
  # Check if the closed file is a PDF
  if [[ "$filename" == *.pdf ]]; then
    echo "File $filename is now closed and ready for processing."

    # Run ocrmypdf on the input file and save it to the output directory
    docker run -i --rm jbarlow83/ocrmypdf - - < "$INPUT_DIR/$filename" > "$OUTPUT_DIR/$filename"

    # Remove the original file after processing
    rm "$INPUT_DIR/$filename"
    echo "$filename has been OCR processed and removed from the input folder."
  fi
done
