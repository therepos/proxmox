#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/mediacms-import.sh)"

WEB_CONTAINER="mediacms-web-1"
DB_CONTAINER="mediacms-db-1"
UPLOAD_SCRIPT="/opt/mediacms-upload.py"
LINK_SCRIPT="/opt/mediacms-playlist.sh"
UPLOAD_FILE="/mnt/sec/media/temp/uploaded_videos.txt"
MEDIA_FOLDER="/mnt/sec/media/temp"

echo "Starting MediaCMS Import Process..."

# Step 1: Run the Upload Script in Web Container
echo "Uploading videos in $WEB_CONTAINER..."
docker exec "$WEB_CONTAINER" python3 "$UPLOAD_SCRIPT"

# Step 2: Check if the upload process created the required file
if docker exec "$WEB_CONTAINER" test -f "$UPLOAD_FILE"; then
    echo "Video upload complete. Proceeding to database linking..."
else
    echo "Error: Upload file not found. Something went wrong!"
    exit 1
fi

# Step 3: Run the Database Linking Script in DB Container
echo "Linking videos to playlists in $DB_CONTAINER..."
docker exec "$DB_CONTAINER" sh "$LINK_SCRIPT"

# Step 4: Remove processed folders
echo "Removing processed folders..."
docker exec "$WEB_CONTAINER" sh -c "find $MEDIA_FOLDER -mindepth 1 -type d -empty -exec rm -rf {} +"

echo "MediaCMS import process completed successfully."
