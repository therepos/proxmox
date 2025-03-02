#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-mediacms.sh)"
# purpose: this script installs mediacms docker container
# note:
# api access: https://mediacms.threeminuteslab.com/swagger/

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

# Step 1: Clone MediaCMS Repository
echo "Cloning MediaCMS repository..."
git clone https://github.com/mediacms-io/mediacms /mnt/sec/apps/mediacms
cd /mnt/sec/apps/mediacms || { echo "Failed to enter directory"; exit 1; }

# Step 2: Change Port from 80 to 3025 in docker-compose.yaml
echo "Changing port from 80 to 3025..."
sed -i 's/80:80/3025:80/g' docker-compose.yaml

# Step 2.1: Add volume mount for /mnt/sec/media/videos under the "web" service
echo "Adding volume mount for /mnt/sec/media/videos to the 'web' service..."
sed -i '/web:/,/volumes:/ { /volumes:/ a \ \ \ \ \ \ - /mnt/sec/media/videos:/media_files/videos' docker-compose.yaml

# Step 2.2: Change timezone (TZ) for the database service
echo "Changing database timezone to Asia/Singapore..."
sed -i 's/TZ: Europe\/London/TZ: Asia\/Singapore/g' docker-compose.yaml

# Step 3: Start MediaCMS Containers
echo "Starting MediaCMS using Docker Compose..."
docker-compose up -d

# Wait for containers to start
sleep 15

# Step 4: Locate the MediaCMS Web Container Dynamically
CONTAINER_ID=$(docker ps --format "{{.ID}}\t{{.Names}}" | grep "mediacms-web" | awk '{print $1}')

if [ -z "$CONTAINER_ID" ]; then
    echo "Error: MediaCMS web container not found!"
    exit 1
fi

echo "Found MediaCMS web container: $CONTAINER_ID"

# Step 5: Reset Admin Password
echo "Resetting admin password..."
docker exec -i "$CONTAINER_ID" bash <<EOF
python manage.py shell <<PYTHON_SCRIPT
from users.models import User
user = User.objects.get(username='admin')
user.set_password('Keywords@cmS01')
user.save()
exit()
PYTHON_SCRIPT
EOF

echo "Password reset complete!"

# Step 6: Restart MediaCMS to Apply Changes
docker-compose restart

echo "Installation and password reset complete!"
echo "Access MediaCMS at: http://mediacms.threeminuteslab.com:3025/admin/"
