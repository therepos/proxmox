---
sidebar_position: 2
---
# Bash

## File System

### Navigation
Key directories.

```
/var/lib
└── vz
    ├── dump/                 # Virtual machine backups
    └── template
        ├── iso/              # ISO templates
        └── cache/            # LXC templates
└── docker
    ├── volumes/              # Docker volumes
    ├── containers/           # Docker container data
    └── logs/                 # Docker logs
```

Grant _root_ and _sambausers_ access to newly created folder.

```bash
chown -R root:sambausers /mnt/sec/media
chmod -R 775 /mnt/sec/media
chmod g+s /mnt/sec/media
setfacl -R -m g:sambausers:rwx /mnt/sec/media
setfacl -R -d -m g:sambausers:rwx /mnt/sec/media
```

### Monitoring 

List open files.

```bash
lsof +D /mnt/sec/media
```

Listen for file changes.

```bash
inotifywait -m -r /mnt/sec/media
```

Check for GPU
```bash
lspci | grep -i vga
```

### Shortcuts

Setup alias for script.

```bash
alias purgedockerct='bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/purge-dockerct.sh)"'
source ~/.bashrc
purgedockerct
```

Remove command alias.

```bash
unalias purgedockerct
```

## Network

`tuln` checks both TCP and UDP ports.  
`tlnp` checks open TCP port and processes. 

To verify specific port e.g. 3017:

```bash
ss -tuln | grep 3017
```

## SSH

Remotely access Proxmox from Android using Termux:

1. Install OpenSSH in Termux.

    ```bash
    pkg update && pkg install openssh
    ```

2. Log into Proxmox.

    ```
    ssh root@<tailscale_ip>
    ```

## Resources

- [Proxmox Training](https://github.com/ondrejsika/proxmox-training)
- [Awesome List](https://github.com/sindresorhus/awesome)
- [Awesome Selfhosted](https://github.com/awesome-selfhosted/awesome-selfhosted)
