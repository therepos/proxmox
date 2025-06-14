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

```bash title="List open files"
lsof +D /mnt/sec/media
```
```bash title="Listen for file changes"
inotifywait -m -r /mnt/sec/media
```
```bash title="Check for GPU"
lspci | grep -i vga
```
```bash title="Monitor GPU usage"
watch -n 1 nvidia-smi
```

### Shortcuts

Setup alias for script.

```bash
alias purgeapps='...'
source ~/.bashrc
```

Remove command alias.

```bash
unalias purgedockerct
nano ~/.bashrc
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
