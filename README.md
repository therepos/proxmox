# Proxmox Helper Scripts

A collection of scripts designed to simplify the installation, management, and uninstallation of various services on Proxmox VE. These scripts are lightweight, easy to use, and automate common setup tasks for LXC containers.

---

## Features

- **Easy Installations**: Set up services like VS Code Server with minimal effort.
- **Automated Uninstallation**: Cleanly remove services and their associated containers.
- **Customizable**: Modify scripts to suit your environment.

---

## How to Use

### Install a Service
Run the following command to install a service. Replace `<name_of_script>` with the name of the desired script:

```bash
bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/<name_of_script>.sh)"
```
### Example: Install VS Code Server

```bash
bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/vscodeserver.sh)"
```

### Uninstall a Service
Run the following command to uninstall a service. Replace <name_of_script> with the name of the service you want to remove:

```bash
bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/ct/<name_of_script>-uninstall.sh)"
```

### Example: Uninstall VS Code Server

```bash
bash -c "$(wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/ct/vscodeserver-uninstall.sh)"
```

---

```bash
wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/installer/install-postpve.sh | bash

wget --no-cache -qLO- https://github.com/tteck/Proxmox/raw/main/misc/filebrowser.sh | bash

wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash

wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiact.sh | bash

wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/install-docker.sh | bash

wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/install-portainer.sh | bash

wget --no-cache -qLO- https://raw.githubusercontent.com/therepos/proxmox/main/install-openwebui.sh | bash

wget --no-cache -qLO- https://github.com/tteck/Proxmox/raw/main/ct/cloudflared.sh | bash

wget --no-cache -qLO- https://github.com/therepos/proxmox/raw/main/install-vscodeserver.sh | bash

```
---

### Customization
All scripts are designed to be easily customizable. You can:

1. Edit variables such as PORT or SVC_NAME at the top of each script.
2. Modify paths or commands to match your environment.
3. Use these scripts as templates for creating your own.

### Acknowledgments
Inspired by and built upon tteck's Proxmox Helper Scripts.
