#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-guacamole.sh)"

# Set up directories for the project
mkdir -p /mnt/sec/apps/guacamole
cd /mnt/sec/apps/guacamole

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
      MYSQL_PASSWORD: password
      MYSQL_USER: admin
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
      MYSQL_ROOT_PASSWORD: password
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

# Start the Docker services
docker-compose up -d

# Output instructions for accessing Guacamole
cat <<END
Setup Complete!

Guacamole Web Interface: http://192.168.1.111:8080

Default credentials for MySQL (change these in production):
User: guacamole_user
Password: pass

Please ensure the Proxmox environment allows these ports.
END
