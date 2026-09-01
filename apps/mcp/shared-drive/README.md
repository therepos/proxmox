# shared-drive

Exposes one folder on the Proxmox host (default `/mnt/sec/media/shared`) to Claude.
Install and connect steps: see [apps/mcp/README.md](../README.md).

```
claude.ai / Desktop / Claude Code
        │  https://<hostname>/<TOKEN>/mcp
        ▼
Cloudflare Tunnel (LXC, cloudflared-setup.sh)
        │  http://<host-ip>:8765
        ▼
mcp-shared-drive.service on the PVE host  ──►  /mnt/sec/media/shared
```

## Tools

| Tool | Notes |
|---|---|
| `list_directory`, `directory_tree` | browse |
| `search_files`, `search_content` | glob by name, substring inside text files |
| `read_file`, `read_file_base64`, `view_image` | paged text, raw bytes (2 MB cap), images (8 MB cap) |
| `get_file_info`, `disk_usage` | metadata, free space |
| `write_file`, `create_directory`, `copy_path`, `move_path`, `delete_path` | read/write mode only |

Paths are relative to the share root. `..`, absolute paths and symlinks pointing outside are rejected.

## Settings (`/etc/mcp/shared-drive.env`)

| Variable | Meaning |
|---|---|
| `MCP_ROOT` | folder to expose |
| `MCP_READ_ONLY` | `1` hides the write tools and mounts the folder read-only in the unit |
| `MCP_NAME` | name shown in Claude |
| `MCP_TOKEN`, `MCP_PORT`, `MCP_PUBLIC_URL` | common to every server |

Files are created with umask 0002 (664 / 775), matching the Samba share settings.
