#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/install-mediacms.sh)"
# purpose: this script installs the MediaCMS Docker container.

#!/bin/bash

# Start the default app processes
./deploy/docker/start.sh &

# Wait for the app and DB to be ready
echo "Waiting for database to initialize..."
sleep 15

# Reset admin password (optional one-time init logic)
echo "Resetting admin password..."
python manage.py shell <<EOF
from users.models import User
user, created = User.objects.get_or_create(username='admin')
user.set_password('password')
user.email = 'admin@localhost'
user.is_staff = True
user.is_superuser = True
user.save()
EOF

# Wait so main process doesn't exit
wait
