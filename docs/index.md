---
sidebar_position: 1
---
# About

This site documents the key pointers noted during my journey into self-hosting. The technologies covered include [Proxmox], [Docker], [Git], [GitHub] and [Markdown]. 

## Products

The Proxmox [repository](https://github.com/therepos/proxmox) stores a collection of scripts created during the process to simplify both setup and maintenance. 

```
proxmox/
├── apps/       # One-click installation scripts (inspired by tteck).
├── docker/     # Ready-to-run docker compose files.
├── docs/       # Documentation and notes.
├── old/        # Superceded scripts.
├── tools/      # One-click tool scripts for specific task.
```

## Hardware

The current Proxmox homelab runs on [ThinkStation P3 Ultra](https://www.youtube.com/watch?v=SSRAPUTpOic) with:
- [x] CPU Intel i7-14700.
- [x] RAM SK Hynix 32GB DDR5-SODIMM 5600MTs ECC HMCG88AGBAA095N (max). 
- [x] RAM SK Hynix 32GB DDR5-SODIMM 5600MTs ECC HMCG88AGBAA095N (max). 
- [x] SSD M.2 NVME 1.00TB zfs (max 4TB).
- [x] SSD M.2 NVME 4.00TB ext4 Lexar NM790 (max).  
- ⭐ SSD 2.5 SATA 7.68TB (max).
- ⭐ GPU NVIDIA RTX 4000 SFF Ada Generation 20GB GDDR6.

## Essentials

Some essential configurations at initial setup:

### PVE Subscription

    ```bash title="Configures no PVE subscription prompt and repositories"
    bash -c "$(curl -fsSL https://github.com/therepos/proxmox/raw/main/apps/tools/fix-pvenosub.sh)"
    ```

### Networking

    ```bash title="etc/network/interfaces"
    auto lo
    iface lo inet loopback
    iface enp3s0 inet manual
    auto vmbr0
    iface vmbr0 inet static
        address 192.168.1.XXX/24
        gateway 192.168.1.1
        dns-nameservers 8.8.8.8 8.8.4.4
        bridge-ports enp3s0
        bridge-stp off
        bridge-fd 0
    iface enp4s0 inet manual
    iface wlo1 inet manual
    source /etc/network/interfaces.d/*
    ```
    ```bash title="etc/resolv.conf"
    nameserver 8.8.8.8              # ideally router IPv4 DNS uses the same nameservers
    nameserver 8.8.4.4
    ```
    ```bash title="Install ifupdown2"
    apt update && apt install ifupdown2 -y
    ```

#### Cloudflared

- _Cloudflare > Networks > Tunnels >_ ***Install and run a connector***.
- Install a service.
- `systemctl restart cloudflared` to refresh cache.

#### Tailscale

    ```bash title="Install Tailscale for LAN access"
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up --accept-dns=false
    ```
    ```bash title="Reloads network configurations"
    ifreload -a                     # without rebooting, or
    systemctl restart networking    # reboots
    ```
    ```bash title="Verify configuration"
    ping google.com
    ```

### Administration

    ```bash title="Install Filebrowser"
    bash -c "$(curl -fsSL https://github.com/therepos/proxmox/raw/main/apps/installer/install-filebrowser.sh)"
    ```
    ```bash title="Install Webmin System Administration"
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/addon/webmin.sh)"
    ```

## License

This work is licensed under [MIT](https://choosealicense.com/licenses/mit/). 

## Resources

- [Self-managed life](https://wiki.futo.org/index.php/Introduction_to_a_Self_Managed_Life:_a_13_hour_%26_28_minute_presentation_by_FUTO_software)
- [GitHub finest](https://github.com/arbal/awesome-stars)
- [Proxmox helper script](https://community-scripts.github.io/ProxmoxVE/)

<!-- Reference Links -->

[Proxmox]: https://www.proxmox.com/en/
[Docker]: https://www.docker.com/
[Git]: https://learngitbranching.js.org/
[GitHub]: https://skills.github.com/
[Markdown]: https://www.markdownguide.org/
