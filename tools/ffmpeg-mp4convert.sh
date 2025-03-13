#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ffmpeg-mp4convert.sh)"
# purpose: this script converts other video format to mp4 inside docker container

# User-configurable variables
WORKDIR="/config"
LOGFILE="$WORKDIR/conversion.log"
FILE_FORMATS="mkv webm"
TIMESTAMP=$(date)  # Expand date before passing it to docker exec

# Start logging
echo "Starting video conversion..."
docker exec -i ffmpeg sh -c "
    mkdir -p \"$WORKDIR\"
    echo 'Starting video conversion - $TIMESTAMP' > \"$LOGFILE\"

    echo 'Looking for files in $WORKDIR:' >> \"$LOGFILE\"
    ls -lh \"$WORKDIR\" >> \"$LOGFILE\" 2>&1

    # Track if any files were found
    files_found=0

    # Process each format
    for format in $FILE_FORMATS; do
        for file in \"$WORKDIR\"/*.\$format; do
            [ -e \"\$file\" ] || continue

            files_found=1  # Mark that we found at least one file

            output=\"\${file%.*}.mp4\"

            echo 'Processing: \"'\$file'\"' >> \"$LOGFILE\"
            echo 'Converting: \"'\$file'\"'...

            # Detect video codec
            VIDEO_CODEC=\$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 \"\$file\")

            if [ \"\$VIDEO_CODEC\" = \"vp8\" ] || [ \"\$VIDEO_CODEC\" = \"vp9\" ]; then
                echo '⚠️ VP8/VP9 detected. Re-encoding to H.264...' >> \"$LOGFILE\"
                ffmpeg -y -i \"\$file\" -c:v libx264 -crf 23 -preset fast -c:a aac -b:a 192k \"\$output\" >> \"$LOGFILE\" 2>&1
            else
                echo '✅ H.264 detected. Copying without re-encoding...' >> \"$LOGFILE\"
                ffmpeg -y -i \"\$file\" -c:v copy -c:a aac -b:a 192k \"\$output\" >> \"$LOGFILE\" 2>&1
            fi

            if [ \$? -eq 0 ]; then
                echo '✅ Successfully converted: \"'\$file'\"' >> \"$LOGFILE\"
                rm -f \"\$file\"  # Delete original file only if conversion succeeds
            else
                echo '❌ Error converting: \"'\$file'\"' >> \"$LOGFILE\"
            fi
        done
    done

    # If no files were found, log it correctly
    if [ \$files_found -eq 0 ]; then
        echo '⚠️ No matching files found for conversion.' >> \"$LOGFILE\"
        echo '⚠️ No matching files found for conversion.'
    fi

    echo 'Conversion process completed - \$(date)' >> \"$LOGFILE\"
    echo '✅ All conversions completed!'
"
