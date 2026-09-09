# mcpshared

Exposes one folder on the host to Claude over remote MCP. Every path is relative to the share
root and jailed there (symlinks and `..` that leave the share are rejected).

## Tools

| Group | Tools |
|---|---|
| Browse | `list_directory`, `directory_tree`, `search_files`, `search_content`, `get_file_info`, `disk_usage` |
| Read | `read_file` (paged text), `view_image` (png/jpg/gif/webp ≤ 8 MB), `read_file_base64` (small binaries) |
| Write (unless read-only) | `write_file`, `create_directory`, `move_path`, `copy_path`, `delete_path` |
| Extract (`extraction_tools.py`) | `list_sheets`, `read_sheet`, `extract_sheet_images`, `extract_pdf_text`, `extract_docx_text` |
| Transfer (`transfer.py`) | `download_link`, `upload_link`, `fetch_url` |

## Extraction

The bottleneck is the model's context window, so office files are unpacked on the host and
returned as text. Every extraction tool is hard-capped at 100k characters and says when it truncates.

| Tool | What it does |
|---|---|
| `list_sheets(path)` | Sheet names, declared range (rows × cols), image count per sheet. Reads only the package XML, so it takes seconds on a 100 MB workbook. |
| `read_sheet(path, sheet, start_row, max_rows, max_cols, format)` | One sheet as markdown or CSV, streamed with `openpyxl` read-only mode. First column is the Excel row number. Paged like `read_file`. |
| `extract_sheet_images(path, sheet, out_dir, inline)` | Walks `xl/drawings` + rels, writes every embedded picture to `<folder>/_images/<workbook>/<sheet>_<cell>.png` and returns a manifest (sheet, anchor cell, file). `inline=true` returns up to 20 images ≤ 5 MB in the response instead (for read-only shares). Media not anchored to any sheet lands in `_unplaced/`. |
| `extract_pdf_text(path, pages, max_chars)` | Page text via `pdfplumber`; `pages="1-5,12"`. Pages without a text layer are reported as scanned. No OCR. |
| `extract_docx_text(path, max_chars)` | Headings, paragraphs, lists and tables as markdown via `python-docx`. |

Extras (`openpyxl`, `pdfplumber`, `python-docx`) are installed by the installer; if one is missing
the tool that needs it says so and the rest of the server keeps working.

## Transfer

MCP cannot move a file between your device and the server: tool results pass through the
model's context. Like other connectors, mcpshared hands out links instead.

| Tool | What it does |
|---|---|
| `download_link(path, expires_minutes)` | Signed URL; open it in any browser to download the file. A folder arrives as a streamed zip. |
| `upload_link(directory, expires_minutes)` | Signed URL that opens a drop-zone page (phone or PC). Files land in that folder; existing names get a numbered copy. `curl -T file "<url>/"` works too. |
| `fetch_url(url, destination, overwrite)` | Server pulls a public http(s) URL straight into the share (Drive `uc?export=download&id=`, Dropbox `?dl=1`, GitHub releases). Private and LAN addresses are refused. |

Links live under `/files/` and are signed with an HMAC derived from the token, so the token never
appears in a link and rotating it (installer option 5) voids every link. Default lifetime is 60
minutes (`MCP_LINK_MINUTES`), maximum 7 days. Set the public URL (installer option 4) or the
links only work on the LAN. Cloudflare's free plan caps uploads at 100 MB per file: use the
`lan_url` for bigger ones. Per-file caps: `MCP_UPLOAD_MAX_BYTES`, `MCP_FETCH_MAX_BYTES` (4 GiB).

## Environment

| Variable | Meaning |
|---|---|
| `MCP_ROOT` | folder to expose (required) |
| `MCP_READ_ONLY` | `1` hides the write tools; `extract_sheet_images` then needs `inline=true` |
| `MCP_NAME` | connector name shown to Claude |
| `MCP_PUBLIC_URL` | `https://<host>` used in download / upload links |
| `MCP_LINK_MINUTES` | default link lifetime (60) |
| `MCP_UPLOAD_MAX_BYTES`, `MCP_FETCH_MAX_BYTES` | per-file caps (4 GiB) |
