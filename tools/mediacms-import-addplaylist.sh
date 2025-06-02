#!/bin/sh
# purpose: worker script that adds a video playlist on mediacms
# notes: precedent to mediacms-import.sh

DB_NAME="mediacms"
DB_USER="mediacms"
UPLOAD_FILE="/mnt/sec/media/videos/uploaded_videos.txt"

if [ ! -f "$UPLOAD_FILE" ]; then
    echo "Error: File $UPLOAD_FILE not found!"
    exit 1
fi

echo "Processing uploaded videos..."

# Read the uploaded videos file and process them
sort "$UPLOAD_FILE" | while IFS=',' read -r PLAYLIST_NAME MEDIA_TOKEN; do
    echo "Processing video with token: $MEDIA_TOKEN for playlist: $PLAYLIST_NAME"

    # Check if the playlist exists
    PLAYLIST_ID=$(psql -U $DB_USER -d $DB_NAME -t -c "SELECT id FROM files_playlist WHERE title = '$PLAYLIST_NAME';" | xargs)
    
    if [ -z "$PLAYLIST_ID" ]; then
        echo "Playlist '$PLAYLIST_NAME' not found! Creating it now..."
        PLAYLIST_ID=$(psql -U $DB_USER -d $DB_NAME -t -c "
        INSERT INTO files_playlist (title, add_date, description, friendly_token, uid, user_id)
        VALUES ('$PLAYLIST_NAME', NOW(), 'Auto-created playlist for $PLAYLIST_NAME', 
        LEFT(MD5(RANDOM()::TEXT), 12), gen_random_uuid(), 1) RETURNING id;" | xargs)

        if [ -z "$PLAYLIST_ID" ]; then
            echo "❌ Failed to create playlist '$PLAYLIST_NAME'!"
            continue
        fi

        echo "✅ Created playlist '$PLAYLIST_NAME' with ID $PLAYLIST_ID."
    else
        echo "✅ Playlist '$PLAYLIST_NAME' already exists with ID $PLAYLIST_ID."
    fi

    # Get media ID from friendly_token
    MEDIA_ID=$(psql -U $DB_USER -d $DB_NAME -t -c "SELECT id FROM files_media WHERE friendly_token = '$MEDIA_TOKEN';" | xargs)

    if [ -z "$MEDIA_ID" ]; then
        echo "❌ Error: Media ID not found for token '$MEDIA_TOKEN'!"
        continue
    fi

    # Insert into files_playlistmedia
    psql -U $DB_USER -d $DB_NAME -c "
    INSERT INTO files_playlistmedia (action_date, ordering, media_id, playlist_id)
    VALUES (NOW(), 999, $MEDIA_ID, $PLAYLIST_ID);"
    
    echo "✅ Added video ID $MEDIA_ID to playlist ID $PLAYLIST_ID."

done

echo "✅ Sorting videos in playlists..."

# Force sorting of videos in the playlist
psql -U $DB_USER -d $DB_NAME -c "
DO \$\$
DECLARE 
    video RECORD;
    counter INTEGER := 1;
BEGIN
    FOR video IN 
        SELECT id FROM files_playlistmedia 
        WHERE playlist_id IN (SELECT id FROM files_playlist) 
        ORDER BY (SELECT title FROM files_media WHERE id = media_id) ASC
    LOOP
        UPDATE files_playlistmedia SET ordering = counter WHERE id = video.id;
        counter := counter + 1;
    END LOOP;
END \$\$;
"

echo "✅ All videos have been sorted alphabetically in their playlists."
