#!/bin/sh
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/docker/mediacms-import.sh)"
# purpose: this controller scripts that uploads all videos in a folder to a new playlist

WEB_CONTAINER="mediacms-web-1"
DB_CONTAINER="mediacms-db-1"
REPO_URL="https://github.com/therepos/proxmox/raw/main/tools"
UPLOAD_SCRIPT="/opt/mediacms-upload.py"
PLAYLIST_SCRIPT="/opt/mediacms-addplaylist.sh"
UPLOAD_FILE="/mnt/sec/media/temp/uploaded_videos.txt"
MEDIA_FOLDER="/mnt/sec/media/temp"

echo "Starting MediaCMS Import Process..."

# Function to check and update scripts if needed
update_script() {
    CONTAINER=$1
    FILE_PATH=$2
    FILE_NAME=$(basename "$FILE_PATH")
    TEMP_FILE="/tmp/$FILE_NAME"

    echo "Checking $FILE_NAME in $CONTAINER..."

    # Download the latest version from GitHub to a temp file
    wget -qO "$TEMP_FILE" "$REPO_URL/$FILE_NAME"

    # If the file doesn't exist locally, install it
    if ! docker exec "$CONTAINER" test -f "$FILE_PATH"; then
        echo "$FILE_NAME not found in $CONTAINER. Installing..."
        docker cp "$TEMP_FILE" "$CONTAINER:$FILE_PATH"
        docker exec "$CONTAINER" chmod +x "$FILE_PATH"
        return
    fi

    # Compare the downloaded file with the existing file inside the container
    DIFF_OUTPUT=$(docker exec "$CONTAINER" sh -c "diff -q $FILE_PATH -" < "$TEMP_FILE")

    if [ -z "$DIFF_OUTPUT" ]; then
        echo "✅ $FILE_NAME is up to date in $CONTAINER."
    else
        echo "🔄 Updating $FILE_NAME in $CONTAINER..."
        docker cp "$TEMP_FILE" "$CONTAINER:$FILE_PATH"
        docker exec "$CONTAINER" chmod +x "$FILE_PATH"
        echo "✅ Updated $FILE_NAME in $CONTAINER."
    fi

    rm "$TEMP_FILE"  # Cleanup temporary file
}

# Check and update required scripts in their respective containers
update_script "$WEB_CONTAINER" "$UPLOAD_SCRIPT"
update_script "$DB_CONTAINER" "$PLAYLIST_SCRIPT"

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
docker exec "$DB_CONTAINER" sh "$PLAYLIST_SCRIPT"

# Step 4: Remove processed folders
echo "Removing processed folders..."
docker exec "$WEB_CONTAINER" sh -c "find $MEDIA_FOLDER -mindepth 1 -type d -empty -exec rm -rf {} +"

echo "MediaCMS import process completed successfully."
