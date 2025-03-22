#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-mediacms.sh)"
# purpose: this script installs the MediaCMS Docker container.

# Define colors and status symbols
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
RESET="\e[0m"

function status_message() {
    local status=$1
    local message=$2
    if [[ "$status" == "success" ]]; then
        echo -e "${GREEN} ${message}"
    else
        echo -e "${RED} ${message}"
        exit 1
    fi
}

# Step 1: Clone MediaCMS Repository
echo "Cloning MediaCMS repository..."
if git clone https://github.com/mediacms-io/mediacms /mnt/sec/apps/mediacms; then
    status_message "success" "MediaCMS repository cloned successfully."
else
    status_message "error" "Failed to clone MediaCMS repository."
fi

cd /mnt/sec/apps/mediacms || status_message "error" "Failed to enter MediaCMS directory."

# Step 2: Modify `docker-compose.yaml`
echo "Modifying MediaCMS configuration..."

# Change port from 80 to 3025
if sed -i 's/80:80/3025:80/g' docker-compose.yaml; then
    status_message "success" "Port changed from 80 to 3025."
else
    status_message "error" "Failed to change port."
fi

# Modify db service to use named volume for postgres data
if sed -i '/db:/,/volumes:/s|\(volumes:\)[^#]*|\1\n      - postgres_data:/var/lib/postgresql/data|' docker-compose.yaml; then
    status_message "success" "Updated db service to use named volume for postgres data."
else
    status_message "error" "Failed to update db service for named volume."
fi

# Ensure volumes section exists and add the named volume definition for postgres_data
if ! grep -q "volumes:" docker-compose.yaml; then
    echo -e "\nvolumes:\n  postgres_data:" >> docker-compose.yaml
    status_message "success" "Created volumes section and added named volume definition for postgres_data."
else
    # Check only within the volumes block
    if ! awk '/volumes:/ {found=1; next} /^[^[:space:]]/ {found=0} found && /postgres_data:/ {exit 1}' docker-compose.yaml; then
        echo -e "\n  postgres_data:" >> docker-compose.yaml
        status_message "success" "Added named volume definition for postgres_data."
    else
        status_message "info" "Named volume postgres_data already defined."
    fi
fi

# Add volume mount for `/mnt/sec/media/temp`
if sed -i '/web:/,/volumes:/s|\(volumes:\)|\1\n      - /mnt/sec/media/videos/uploads:/mnt/sec/media/videos/uploads|' docker-compose.yaml; then
    status_message "success" "Mounted /mnt/sec/media/temp."
else
    status_message "error" "Failed to mount media volume."
fi

# Add volume mount for `/mnt/sec/apps/mediacsm/opt`
if sed -i '/web:/,/volumes:/s|\(volumes:\)|\1\n      - /mnt/sec/apps/mediacsm/opt:/opt|' docker-compose.yaml; then
    status_message "success" "Mounted /mnt/sec/apps/mediacsm/opt."
else
    status_message "error" "Failed to mount opt volume."
fi

# Change database timezone to Asia/Singapore
if sed -i 's/TZ: Europe\/London/TZ: Asia\/Singapore/g' docker-compose.yaml; then
    status_message "success" "Database timezone changed to Asia/Singapore."
else
    status_message "error" "Failed to change database timezone."
fi

# Step 3: Start MediaCMS Containers
echo "Starting MediaCMS using Docker Compose..."
if docker-compose up -d; then
    status_message "success" "MediaCMS containers started successfully."
else
    status_message "error" "Failed to start MediaCMS containers."
fi

# Wait for containers to initialize
echo "Waiting for containers to initialize..."
sleep 15

# Step 4: Locate the MediaCMS Web Container
CONTAINER_ID=$(docker ps --format "{{.ID}}\t{{.Names}}" | grep "mediacms-web" | awk '{print $1}')

if [ -z "$CONTAINER_ID" ]; then
    status_message "error" "MediaCMS web container not found!"
else
    status_message "success" "MediaCMS web container found: $CONTAINER_ID."
fi

# Step 5: Reset Admin Password
echo "Resetting admin password..."
if docker exec -i "$CONTAINER_ID" bash <<EOF
python manage.py shell <<PYTHON_SCRIPT
from users.models import User
user = User.objects.get(username='admin')
user.set_password('password')
user.save()
exit()
PYTHON_SCRIPT
EOF
then
    status_message "success" "Admin password reset successfully."
else
    status_message "error" "Failed to reset admin password."
fi

# Step 6: Restart MediaCMS to Apply Changes
echo "Restarting MediaCMS containers..."
if docker-compose restart; then
    status_message "success" "MediaCMS restarted successfully."
else
    status_message "error" "Failed to restart MediaCMS."
fi

echo "Installation and password reset complete!"
echo "Access MediaCMS at: http://yourip:3025"
echo "Access API at: https://yourip:3025/swagger/"
