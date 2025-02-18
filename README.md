# Proxmox Helper Scripts
A collection of scripts designed to simplify the installation, management, and uninstallation of various services on Proxmox VE. Use [apps scripts] to automate setup for applications and tool scripts to automate common setup tasks.

## Tool Scripts
```bash
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/format-disk.sh)"
```
```bash
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/mount-drive.sh)"
```
```bash
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/print-sysinfo.sh)"
```
```bash
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/purge-dockerct.sh)"
```
```bash
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/purge-lxc.sh)"
```
```bash
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-gpu.sh)"
```

## References
- [Self-managed life](https://wiki.futo.org/index.php/Introduction_to_a_Self_Managed_Life:_a_13_hour_%26_28_minute_presentation_by_FUTO_software)

## Explore
- [GPU in LXC](https://yomis.blog/nvidia-gpu-in-proxmox-lxc/)
- [GitHub finest](https://github.com/arbal/awesome-stars)

[apps scripts]: page-apps.md
