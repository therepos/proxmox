#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ffmpeg-convertmkv.sh)"
# purpose: this script converts mkv video files inside docker container

# User-configurable: Define file formats to convert (space-separated, e.g., "mkv webm avi")
FILE_FORMATS="mkv webm"

# Set working directory inside Docker (mapped from Proxmox)
WORKDIR="/config"
LOGFILE="$WORKDIR/conversion.log"

# Start logging
echo "Starting video conversion..."
docker exec -i ffmpeg sh -c "echo 'Starting video conversion - \$(date)' > $LOGFILE"

# Run everything inside Docker
docker exec -i ffmpeg sh -c "
    WORKDIR='/config'
    LOGFILE='\$WORKDIR/conversion.log'
    FILE_FORMATS=\"$FILE_FORMATS\"  # Correctly pass variable

    echo 'Looking for files with formats: \$FILE_FORMATS in \$WORKDIR' >> \"\$LOGFILE\"

    # Loop through each format
    for format in \$FILE_FORMATS; do
        ls -lh \"\$WORKDIR\"/*.\$format 2>/dev/null >> \"\$LOGFILE\"

        for file in \"\$WORKDIR\"/*.\$format; do
            [ -e \"\$file\" ] || continue

            output=\"\${file%.*}.mp4\"  # Convert to .mp4 with same base name

            echo 'Processing: '\$file >> \"\$LOGFILE\"
            echo 'Converting: '\$file...

            # Use '-y' to overwrite existing files automatically
            ffmpeg -y -i \"\$file\" -c:v copy -c:a aac -b:a 192k \"\$output\" >> \"\$LOGFILE\" 2>&1

            if [ \$? -eq 0 ]; then
                echo 'Successfully converted: '\$file >> \"\$LOGFILE\"
                echo '✅ Successfully converted: '\$file
                rm -f \"\$file\"
            else
                echo 'Error converting: '\$file >> \"\$LOGFILE\"
                echo '❌ Error converting: '\$file
            fi
        done
    done

    echo 'Conversion process completed - \$(date)' >> \"\$LOGFILE\"
    echo '✅ All conversions completed!'
"
