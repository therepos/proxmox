#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/mediacms-import.sh)"
# purpose: this controller scripts that uploads all videos in a folder to a new playlist

WEB_CONTAINER="mediacms-web-1"
DB_CONTAINER="mediacms-db-1"
UPLOAD_SCRIPT="/opt/mediacms-upload.py"     # dependent
LINK_SCRIPT="/opt/mediacms-addplaylist.sh"  # dependent
UPLOAD_FILE="/mnt/sec/media/temp/uploaded_videos.txt"
MEDIA_FOLDER="/mnt/sec/media/temp"
REPO_URL="https://github.com/therepos/proxmox/raw/main/tools"

echo "Starting MediaCMS Import Process..."

# Ensure scripts exist, download if missing
download_if_missing() {
    CONTAINER=$1
    FILE_PATH=$2
    FILE_NAME=$(basename "$FILE_PATH")

    if docker exec "$CONTAINER" test -f "$FILE_PATH"; then
        echo "$FILE_NAME exists in $CONTAINER."
    else
        echo "$FILE_NAME is missing in $CONTAINER. Downloading..."
        docker exec "$CONTAINER" sh -c "wget -qO $FILE_PATH $REPO_URL/$FILE_NAME && chmod +x $FILE_PATH"

        if docker exec "$CONTAINER" test -f "$FILE_PATH"; then
            echo "$FILE_NAME successfully downloaded in $CONTAINER."
        else
            echo "Error: Failed to download $FILE_NAME in $CONTAINER."
            exit 1
        fi
    fi
}

# Check and download required scripts
download_if_missing "$WEB_CONTAINER" "$UPLOAD_SCRIPT"
download_if_missing "$DB_CONTAINER" "$LINK_SCRIPT"

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
