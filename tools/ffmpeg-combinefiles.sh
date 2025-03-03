#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/ffmpeg-combinefiles.sh)"
# purpose: this script combines video files and set chapter markers inside docker container

BASE_DIR="/config"

# Loop through each subfolder
for folder in "$BASE_DIR"/*; do
    if [ -d "$folder" ]; then
        folder_name=$(basename "$folder")
        output_video="$BASE_DIR/${folder_name}_combined.mp4"
        metadata_file="$BASE_DIR/${folder_name}_metadata.txt"

        # Generate file list for concatenation
        file_list="$folder/file_list.txt"
        rm -f "$file_list" "$metadata_file"
        
        echo ";FFMETADATA1" > "$metadata_file"
        start_time=0
        timebase=1000  # 1 second = 1000 ms

        for video in "$folder"/*.mp4 "$folder"/*.mkv; do
            [ -f "$video" ] || continue  # Skip if no matching files
            echo "file '$video'" >> "$file_list"

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

        # Run FFmpeg to combine videos
        ffmpeg -f concat -safe 0 -i "$file_list" -c copy "$output_video"

        # Embed chapters
        ffmpeg -i "$output_video" -i "$metadata_file" -map_metadata 1 -codec copy "${output_video%.mp4}_with_chapters.mp4"

        echo "Finished processing $folder_name"
    fi
done
