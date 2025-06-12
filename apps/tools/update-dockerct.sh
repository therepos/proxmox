#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/update-dockerct.sh?$(date +%s))"
# purpose: update all Docker Compose apps

BASE_DIR="/mnt/sec/apps"

for dir in "$BASE_DIR"/*; do
  if [ -f "$dir/docker-compose.yml" ]; then
    echo "Updating in $dir..."
    (cd "$dir" && docker-compose pull && docker-compose up -d)
  fi
done

# cleanup
docker image prune -f
