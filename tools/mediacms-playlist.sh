#!/bin/sh

DB_NAME="mediacms"
DB_USER="mediacms"
UPLOAD_FILE="/mnt/sec/media/temp/uploaded_videos.txt"

if [ ! -f "$UPLOAD_FILE" ]; then
    echo "Error: File $UPLOAD_FILE not found!"
    exit 1
fi

echo "Processing uploaded videos..."

while IFS=',' read -r PLAYLIST_NAME MEDIA_TOKEN; do
    echo "Processing video with token: $MEDIA_TOKEN for playlist: $PLAYLIST_NAME"

    PLAYLIST_ID=$(psql -U $DB_USER -d $DB_NAME -t -c "SELECT id FROM files_playlist WHERE title = '$PLAYLIST_NAME';" | xargs)
    
    if [ -z "$PLAYLIST_ID" ]; then
        echo "Error: Playlist '$PLAYLIST_NAME' not found!"
        continue
    fi

    MEDIA_ID=$(psql -U $DB_USER -d $DB_NAME -t -c "SELECT id FROM files_media WHERE friendly_token = '$MEDIA_TOKEN';" | xargs)

    if [ -z "$MEDIA_ID" ]; then
        echo "Error: Media ID not found for token '$MEDIA_TOKEN'!"
        continue
    fi

    psql -U $DB_USER -d $DB_NAME -c "
    INSERT INTO files_playlistmedia (action_date, ordering, media_id, playlist_id)
    VALUES (NOW(), (SELECT COUNT(*) FROM files_playlistmedia WHERE playlist_id = $PLAYLIST_ID) + 1, $MEDIA_ID, $PLAYLIST_ID);
    "

    echo "Added video ID $MEDIA_ID to playlist ID $PLAYLIST_ID."
done < "$UPLOAD_FILE"

echo "All videos have been linked to their playlists."
