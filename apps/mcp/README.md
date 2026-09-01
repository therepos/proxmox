# MCP shared folder for Claude

Exposes one folder on the Proxmox host (default `/mnt/sec/media/shared`) to Claude as a
remote [MCP](https://modelcontextprotocol.io) server over Streamable HTTP.

```
claude.ai / Desktop / Claude Code
        │  https://mcp.<domain>/<TOKEN>/mcp
        ▼
Cloudflare Tunnel (LXC 110, cloudflared-setup.sh)
        │  http://192.168.0.111:8765
        ▼
mcp-fs.service on the PVE host  ──►  /mnt/sec/media/shared
```

## Install

On the Proxmox host:

```bash
bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/mcp-setup.sh?$(date +%s))"
```

Pick the folder, port, read/write or read-only, and a connector name. The installer prints
the URL that contains the secret token.

## Connect

1. **Cloudflare**: Zero Trust → Networks → Tunnels → your tunnel → Public Hostname → Add.
   Subdomain `mcp`, type HTTP, URL `<host-ip>:8765`.
2. **claude.ai / Claude Desktop**: Settings → Connectors → Add custom connector.
   URL `https://mcp.<domain>/<TOKEN>/mcp`, no OAuth fields.
3. **Claude Code**: `claude mcp add --transport http shared-drive https://mcp.<domain>/<TOKEN>/mcp`

On the LAN the same works with `http://<host-ip>:8765/<TOKEN>/mcp`. A Bearer header
(`Authorization: Bearer <TOKEN>`) against `/mcp` is accepted too.

## Tools

| Tool | Notes |
|---|---|
| `list_directory`, `directory_tree` | browse |
| `search_files`, `search_content` | glob by name, substring inside text files |
| `read_file`, `read_file_base64`, `view_image` | paged text, raw bytes (2 MB cap), images (8 MB cap) |
| `get_file_info`, `disk_usage` | metadata, free space |
| `write_file`, `create_directory`, `copy_path`, `move_path`, `delete_path` | read/write mode only |

## Security

- The token in the URL is the only credential. Anyone with the URL has the access level you chose. Rotate it from the installer menu (option 5).
- Every path is resolved and checked against the share; `..`, absolute paths and symlinks pointing outside are rejected.
- The systemd unit runs with `ProtectSystem=strict`: the entire host is read-only to the process except the share (`ReadWritePaths`), and `/etc/pve`, `/var/lib/vz`, `/etc/ssh`, `/root` are inaccessible.
- Wrong or missing token returns a plain 404, so nothing is discoverable by scanning.
- Files are created with umask 0002 (664 / 775), matching the Samba share settings.

## Files

| Path | Purpose |
|---|---|
| `/opt/mcp-fs/server.py` | server (copy of `apps/mcp/server.py`) |
| `/opt/mcp-fs/venv` | Python env with `mcp>=2,<3` and `uvicorn` |
| `/etc/mcp-fs/env` | settings and token (mode 600) |
| `/etc/systemd/system/mcp-fs.service` | unit |
