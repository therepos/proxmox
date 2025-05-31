---
sidebar_position: 1
---
# About

This site chronicles my journey into self-hosting, during which I explored technologies such as [Proxmox], [Docker], [Git], [Markdown], [Docusaurus], and [MkDocs].

## Structure

The [Proxmox repository](https://github.com/therepos/proxmox) stores a collection of scripts that I used to simplify my Proxmox setup and open-sourced applications running in Docker containers. 

```
proxmox/
├── apps/       # One-click installation scripts (inspired by tteck).
├── docker/     # Ready-to-run docker compose files.
├── docs/       # Documentation and notes.
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

<!-- Reference Links -->

[Proxmox]: https://www.proxmox.com/en/
[Docker]: https://www.docker.com/
[Git]: https://git-scm.com/
[Markdown]: https://www.markdownguide.org/
[Docusaurus]: https://docusaurus.io/
[MkDocs]: https://www.mkdocs.org/