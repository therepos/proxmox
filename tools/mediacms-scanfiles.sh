#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/mediacms-scanfiles.sh)"
# purpose: this script scans files from media temp folder for uploads to mediacms

# Define variables
GITHUB_REPO="https://github.com/therepos/proxmox/raw/main/tools"
CONTAINER_NAME="mediacms-web-1"  # Replace with your actual container name
MEDIA_FOLDER="/mnt/sec/media/temp"  # Change this if needed
SCRIPT_NAME="mediacms-uploadmedia.py"
WATCHER_SCRIPT="watch-media-folder.sh"
SCRIPT_PATH="/opt/$SCRIPT_NAME"
WATCHER_PATH="/opt/$WATCHER_SCRIPT"

echo "Setting up MediaCMS auto-upload inside Docker container..."

# Step 1: Install Python and dependencies inside the container
echo "Installing Python and requests inside the container..."
docker exec -it $CONTAINER_NAME apt update
docker exec -it $CONTAINER_NAME apt install -y python3 python3-pip inotify-tools
docker exec -it $CONTAINER_NAME pip3 install requests

# Step 2: Download the Python upload script from GitHub and copy it into the container
echo "Downloading upload script from GitHub..."
wget -O $SCRIPT_NAME "$GITHUB_REPO/$SCRIPT_NAME"

echo "Copying upload script to container..."
docker cp $SCRIPT_NAME $CONTAINER_NAME:$SCRIPT_PATH

# Step 3: Create a file watcher script
echo "Creating file watcher script..."
cat <<EOF > $WATCHER_SCRIPT
#!/bin/bash
WATCH_DIR="$MEDIA_FOLDER"
UPLOAD_SCRIPT="$SCRIPT_PATH"

inotifywait -m -e create "$WATCH_DIR" --format '%f' |
while read FILE; do
    if [[ "\$FILE" =~ \.(mp4|mov|mkv)$ ]]; then
        echo "New file detected: \$FILE"
        python3 "\$UPLOAD_SCRIPT"
    fi
done
EOF

# Copy the watcher script into the container
docker cp $WATCHER_SCRIPT $CONTAINER_NAME:$WATCHER_PATH
docker exec -it $CONTAINER_NAME chmod +x $WATCHER_PATH

# Step 4: Start the watcher as a background process inside the container
echo "Starting file watcher in the background..."
docker exec -it -d $CONTAINER_NAME bash -c "$WATCHER_PATH"

echo "Setup complete. New media files in $MEDIA_FOLDER will be uploaded automatically!"
