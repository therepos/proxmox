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

## Environment

| Variable | Meaning |
|---|---|
| `MCP_ROOT` | folder to expose (required) |
| `MCP_READ_ONLY` | `1` hides the write tools; `extract_sheet_images` then needs `inline=true` |
| `MCP_NAME` | connector name shown to Claude |
