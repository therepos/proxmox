# Basic

## File System

- Key directories.

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

- Grant _root_ and _sambausers_ access to newly created folder.

```bash
chown -R root:sambausers /mnt/sec/media
chmod -R 775 /mnt/sec/media
chmod g+s /mnt/sec/media
setfacl -R -m g:sambausers:rwx /mnt/sec/media
setfacl -R -d -m g:sambausers:rwx /mnt/sec/media
```

### Monitoring 

- List open files.

```bash
lsof +D /mnt/sec/media/videos/upload/location
```

- Listen for file changes.

```bash
inotifywait -m -r /mnt/sec/media/videos/upload/location
```

### Shortcut

- Setup command alias.

```bash
alias purgedockerct='bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/purge-dockerct.sh)"'
source ~/.bashrc
purgedockerct
```

- Remove command alias.

```bash
unalias purgedockerct
```

## Network

- Verify port usage. Replace 3017 with the targeted port number.

```bash
sudo ss -tuln | grep 3017
```

## References

- [Proxmox Training](https://github.com/ondrejsika/proxmox-training)
- [Awesome List](https://github.com/sindresorhus/awesome)
- [Awesome Selfhosted](https://github.com/awesome-selfhosted/awesome-selfhosted)