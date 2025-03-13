#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ffmpeg-convertmkv.sh)"
# purpose: this script converts mkv files to mp4 files inside docker container

# Set working directory
WORKDIR="/config"
LOGFILE="$WORKDIR/conversion.log"

# Start logging
echo "Starting MKV to MP4 conversion - $(date)" > "$LOGFILE"

# Loop through all MKV files in the directory
for file in "$WORKDIR"/*.mkv; do
    # Skip if no MKV files exist
    [ -e "$file" ] || continue

    # Define output file name
    output="${file%.mkv}.mp4"

    echo "Processing: $file" >> "$LOGFILE"

    # Convert MKV to MP4 (lossless video, convert audio to AAC for compatibility)
    docker exec -it ffmpeg ffmpeg -i "$file" -c:v copy -c:a aac -b:a 192k "$output" >> "$LOGFILE" 2>&1

    # Check if conversion was successful
    if [ $? -eq 0 ]; then
        echo "Successfully converted: $file" >> "$LOGFILE"
        rm "$file"  # Delete the original MKV file
    else
        echo "Error converting: $file" >> "$LOGFILE"
    fi
done

echo "Conversion process completed - $(date)" >> "$LOGFILE"
