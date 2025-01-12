#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-guacamole2.sh)"

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

# Variables
APP_DIR="/mnt/sec/apps/guacamole"
COMPOSE_FILE_PATH="$APP_DIR/docker-compose.yml"
CONTAINER_NAMES=("guacd" "guac_web" "guac-sql")
DOCKER_COMPOSE_URL="https://github.com/docker/compose/releases/download/$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)/docker-compose-$(uname -s)-$(uname -m)"

# Check if Guacamole Docker is already installed
if docker ps -a --format '{{.Names}}' | grep -Eq "^guacd$|^guac_web$|^guac-sql$"; then
    echo "Guacamole Docker setup is already installed."
    read -p "Do you want to uninstall it? (y/N): " uninstall_choice
    if [[ "$uninstall_choice" =~ ^[Yy]$ ]]; then
        echo "Stopping and removing Guacamole containers, images, volumes, and files..."

        # Stop and remove containers
        docker-compose -f "$COMPOSE_FILE_PATH" down --volumes &>/dev/null
        status_message "success" "Stopped and removed containers."

        # Remove all associated images
        for container in "${CONTAINER_NAMES[@]}"; do
            image_id=$(docker images --filter=reference="guacamole/*" --format "{{.ID}}")
            if [[ -n "$image_id" ]]; then
                docker rmi "$image_id" &>/dev/null
                status_message "success" "Removed image for $container."
            fi
        done

        # Prune unused Docker volumes
        docker volume prune -f &>/dev/null
        status_message "success" "Pruned unused Docker volumes."

        # Prune unused Docker networks
        docker network prune -f &>/dev/null
        status_message "success" "Pruned unused Docker networks."

        # Remove associated files
        rm -rf "$APP_DIR"
        status_message "success" "Removed application directory and files ($APP_DIR)."

        exit 0
    else
        status_message "error" "Installation aborted as Guacamole is already installed."
    fi
fi

# Check for dependencies
if ! command -v docker &>/dev/null; then
    echo "Docker is not installed. Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh &>/dev/null
    rm get-docker.sh
    status_message "success" "Installed Docker."
fi

if ! command -v docker-compose &>/dev/null; then
    echo "Docker Compose is not installed. Installing Docker Compose..."
    sudo curl -L "$DOCKER_COMPOSE_URL" -o /usr/local/bin/docker-compose &>/dev/null
    sudo chmod +x /usr/local/bin/docker-compose
    status_message "success" "Installed Docker Compose."
fi

# Set up directories for the project
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Create the Docker Compose file
cat <<EOF > docker-compose.yml
version: "3.8"

services:
  guacd:
    container_name: guacd
    image: guacamole/guacd
    restart: unless-stopped
    networks:
      - guac-net

  guacweb:
    container_name: guac_web
    image: guacamole/guacamole
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      MYSQL_DATABASE: guacamole_db
      MYSQL_HOSTNAME: guacamole-sql
      MYSQL_PASSWORD: pass
      MYSQL_USER: guacamole_user
      GUACD_HOSTNAME: guacd
    depends_on:
      - guacamole-sql
      - guacd
    networks:
      - guac-net

  guacamole-sql:
    container_name: guac-sql
    image: mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: pass
    volumes:
      - dbdata:/var/lib/mysql
    networks:
      - guac-net

volumes:
  dbdata:

networks:
  guac-net:
    driver: bridge
EOF

status_message "success" "Created Docker Compose file."

# Start the Docker services
docker-compose up -d &>/dev/null
status_message "success" "Started Guacamole services."

# Output instructions for accessing Guacamole
cat <<END
Setup Complete!

Guacamole Web Interface: http://192.168.1.111:8080

Default credentials for MySQL (change these in production):
User: guacamole_user
Password: pass

Please ensure the Proxmox environment allows these ports.
END
