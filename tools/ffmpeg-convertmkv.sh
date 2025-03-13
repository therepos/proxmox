#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ffmpeg-convertmkv.sh)"
# purpose: this script converts mkv video files inside docker container

# User-configurable variables
WORKDIR="/config"  # Path inside Docker where files are located
FILE_FORMATS="mkv webm"  # Space-separated list of file formats to convert

# Start logging
echo "Starting video conversion..."
docker exec -i ffmpeg sh -c "
    LOGFILE='$WORKDIR/conversion.log'

    # Ensure the working directory exists inside the container
    mkdir -p \"$WORKDIR\"
    echo 'Starting video conversion - \$(date)' > \"$LOGFILE\"

    echo 'Looking for files with formats: $FILE_FORMATS in $WORKDIR' >> \"$LOGFILE\"

    for format in $FILE_FORMATS; do
        ls -lh \"$WORKDIR\"/*.\$format 2>/dev/null >> \"$LOGFILE\"

        for file in \"$WORKDIR\"/*.\$format; do
            [ -e \"$file\" ] || continue

            output=\"\${file%.*}.mp4\"

            echo 'Processing: '\$file >> \"$LOGFILE\"
            echo 'Converting: '\$file...

            ffmpeg -y -i \"$file\" -c:v copy -c:a aac -b:a 192k \"$output\" >> \"$LOGFILE\" 2>&1

            if [ \$? -eq 0 ]; then
                echo 'Successfully converted: '\$file >> \"$LOGFILE\"
                echo '✅ Successfully converted: '\$file'
                rm -f \"$file\"
            else
                echo 'Error converting: '\$file >> \"$LOGFILE\"
                echo '❌ Error converting: '\$file'
            fi
        done
    done

    echo 'Conversion process completed - \$(date)' >> \"$LOGFILE\"
    echo '✅ All conversions completed!'
"

