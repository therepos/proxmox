---
sidebar_position: 1
---
# About

This is a collection of scripts that I used to simplify my setup of Proxmox and open-sourced applications running in Docker containers. 

## Structure

The [repository](https://github.com/therepos/proxmox) structure is as follows:

```
proxmox/
├── apps/       # One-click installation scripts (inspired by tteck).
├── docker/     # Ready-to-run docker compose files.
├── docs/       # Documentation.
├── old/        # Superceded scripts.
├── tools/      # One-click tool scripts for specific task.
```

## Shortcut

```sh
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/format-disk.sh)"
```
```sh
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/mount-drive.sh)"
```
```sh
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/print-sysinfo.sh)"
```
```sh
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/purge-lxc.sh)"
```
```sh
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/set-gpu.sh)"
```

## License

This work is licensed under [MIT](https://choosealicense.com/licenses/mit/). 

## Resources

- [Self-managed life](https://wiki.futo.org/index.php/Introduction_to_a_Self_Managed_Life:_a_13_hour_%26_28_minute_presentation_by_FUTO_software)
- [GitHub finest](https://github.com/arbal/awesome-stars)