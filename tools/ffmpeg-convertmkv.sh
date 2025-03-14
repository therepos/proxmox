#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ffmpeg-convertmkv.sh)"
# purpose: this script converts other video format to mp4 inside docker container

# User-configurable variables
WORKDIR="/config"
LOGFILE="$WORKDIR/conversion.log"
FILE_FORMATS="mkv"
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

    # Process MKV files
    for file in \"$WORKDIR\"/*.mkv; do
        [ -e \"\$file\" ] || continue

        files_found=1  # Mark that we found at least one file

        output=\"\${file%.*}.mp4\"

        echo 'Processing: \"'\$file'\"' >> \"$LOGFILE\"
        echo 'Converting: \"'\$file'\"'...

        # Lossless MKV to MP4 conversion (copy video and audio streams)
        ffmpeg -y -i \"\$file\" -c:v copy -c:a copy \"\$output\" >> \"$LOGFILE\" 2>&1

        if [ \$? -eq 0 ]; then
            echo '✅ Successfully converted: \"'\$file'\"' >> \"$LOGFILE\"
            rm -f \"\$file\"  # Delete original file only if conversion succeeds
        else
            echo '❌ Error converting: \"'\$file'\"' >> \"$LOGFILE\"
        fi
    done

    # If no files were found, log it correctly
    if [ \$files_found -eq 0 ]; then
        echo '⚠️ No matching files found for conversion.' >> \"$LOGFILE\"
        echo '⚠️ No matching files found for conversion.'
    fi

    echo 'Conversion process completed - \$(date)' >> \"$LOGFILE\"
    echo '✅ All conversions completed!'
"

