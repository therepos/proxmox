#!/bin/sh

# Set working directory inside Docker (mapped from Proxmox)
WORKDIR="/config"
LOGFILE="$WORKDIR/conversion.log"

# Start logging
echo "Starting MKV to MP4 conversion..."
docker exec -i ffmpeg sh -c "echo 'Starting MKV to MP4 conversion - \$(date)' > $LOGFILE"

# Run everything inside Docker
docker exec -i ffmpeg sh -c '
    WORKDIR="/config"
    LOGFILE="$WORKDIR/conversion.log"

    echo "Looking for MKV files in: $WORKDIR" >> "$LOGFILE"
    ls -lh "$WORKDIR"/*.mkv >> "$LOGFILE"

    for file in "$WORKDIR"/*.mkv; do
        [ -e "$file" ] || continue

        output="${file%.mkv}.mp4"

        echo "Processing: $file" >> "$LOGFILE"
        echo "Converting: $file..."

        # Use '-y' to overwrite existing files automatically
        ffmpeg -y -i "$file" -c:v copy -c:a aac -b:a 192k "$output" >> "$LOGFILE" 2>&1

        if [ $? -eq 0 ]; then
            echo "Successfully converted: $file" >> "$LOGFILE"
            echo "✅ Successfully converted: $file"
            rm -f "$file"
        else
            echo "Error converting: $file" >> "$LOGFILE"
            echo "❌ Error converting: $file"
        fi
    done

    echo "Conversion process completed - \$(date)" >> "$LOGFILE"
    echo "✅ All conversions completed!"
'
