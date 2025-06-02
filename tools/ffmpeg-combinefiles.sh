#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ffmpeg-combinefiles.sh?$(date +%s))"
# purpose: combines video files and set chapter markers inside docker container

# Define the Docker container name
CONTAINER_NAME="ffmpeg"

# Check if the FFmpeg container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: FFmpeg container is not running. Starting it..."
    docker-compose up -d ffmpeg  # Start the container if it's not running
    sleep 3  # Give some time for the container to initialize
fi

# Run the processing script inside the Docker container
docker exec -it ${CONTAINER_NAME} /bin/sh -c '
    BASE_DIR="/config"

    # Loop through each subfolder
    for folder in "$BASE_DIR"/*; do
        if [ -d "$folder" ]; then
            folder_name=$(basename "$folder")
            output_video="$BASE_DIR/${folder_name}_combined.mp4"
            metadata_file="$BASE_DIR/${folder_name}_metadata.txt"
            final_output="$BASE_DIR/${folder_name}_combined_with_chapters.mp4"
            file_list="$folder/file_list.txt"

            # Cleanup old files if they exist
            rm -f "$file_list" "$metadata_file" "$output_video" "$final_output"

            echo ";FFMETADATA1" > "$metadata_file"
            start_time=0
            timebase=1000  # 1 second = 1000 ms

            # Generate file list and chapter metadata
            for video in "$folder"/*.mp4 "$folder"/*.mkv; do
                [ -f "$video" ] || continue  # Skip if no matching files
                echo "file '\''$video'\''" >> "$file_list"

                duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 "$video")
                duration_ms=$(awk "BEGIN {print int($duration * $timebase)}")
                end_time=$((start_time + duration_ms))

                # Add chapter entry
                echo "[CHAPTER]" >> "$metadata_file"
                echo "TIMEBASE=1/$timebase" >> "$metadata_file"
                echo "START=$start_time" >> "$metadata_file"
                echo "END=$end_time" >> "$metadata_file"
                echo "title=$(basename "$video")" >> "$metadata_file"

                start_time=$end_time
            done

            # Combine videos
            ffmpeg -f concat -safe 0 -i "$file_list" -c copy "$output_video"

            # Embed chapters
            ffmpeg -i "$output_video" -i "$metadata_file" -map_metadata 1 -codec copy "$final_output"

            # Cleanup unnecessary files
            rm -f "$file_list" "$metadata_file" "$output_video"

            echo "Finished processing: $folder_name → Saved as $final_output"
        fi
    done
'

echo "All videos processed successfully!"

