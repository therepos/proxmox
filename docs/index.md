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

The current Proxmox homelab runs on [Lenovo P3 Ultra](https://www.youtube.com/watch?v=SSRAPUTpOic) with:
- Intel i7-14700.
- 64GB ECC RAM _(max 128GB)_.  
- SSD 1TB zfs (root) + 4TB ext4 (storage).  
  _SSD 2.5" SATA 7.68TB (1x) + SSD M.2 NVME 4TB (2x)_ 
- NVIDIA RTX A2000 12GB.  
  _NVIDIA RTX 4000 SFF Ada Generation 20GB GDDR6_  
  _NVIDIA RTX 2000 Ada Generation 16GB GDDR6_

## License

This work is licensed under [MIT](https://choosealicense.com/licenses/mit/). 

## Resources

- [Self-managed life](https://wiki.futo.org/index.php/Introduction_to_a_Self_Managed_Life:_a_13_hour_%26_28_minute_presentation_by_FUTO_software)
- [GitHub finest](https://github.com/arbal/awesome-stars)

<!-- Reference Links -->

[Proxmox]: https://www.proxmox.com/en/
[Docker]: https://www.docker.com/
[Git]: https://learngitbranching.js.org/
[GitHub]: https://skills.github.com/
[Markdown]: https://www.markdownguide.org/
