# mcpshared

Exposes one folder on the host to Claude over remote MCP. Every path is relative to the share
root and jailed there (symlinks and `..` that leave the share are rejected).

## Tools

| Group | Tools |
|---|---|
| Browse | `list_directory`, `directory_tree`, `search_files`, `search_content`, `get_file_info`, `disk_usage` |
| Read | `read_file` (paged text), `view_image` (png/jpg/gif/webp ≤ 8 MB), `read_file_base64` (small binaries) |
| Write (unless read-only) | `write_file`, `create_directory`, `move_path`, `copy_path`, `delete_path` |
| Extract (`extraction_tools.py`) | `list_sheets`, `read_sheet`, `extract_sheet_images`, `extract_pdf_text`, `view_pdf_page`, `extract_docx_text`, `extract_pptx_text` |
| Transfer (`transfer.py`) | `download_link`, `upload_link`, `fetch_url` |
| Build (`build_tools.py`, unless read-only) | `build_xlsx`, `build_docx`, `build_pptx`, `build_pdf` |
| Host (`host_tools.py`) | `list_archive`, `extract_archive`, `ocr_text`, `convert_to_pdf` |
| Edit in place (`edit_tools.py`, unless read-only) | `edit_docx`, `edit_pptx`, `write_cells`, `add_chart`, `pdf_pages`, `merge_pdfs` |

## Extraction

The bottleneck is the model's context window, so office files are unpacked on the host and
returned as text. Every extraction tool is hard-capped at 100k characters and says when it truncates.

| Tool | What it does |
|---|---|
| `list_sheets(path)` | Sheet names, declared range (rows × cols), image count per sheet. Reads only the package XML, so it takes seconds on a 100 MB workbook. |
| `read_sheet(path, sheet, start_row, max_rows, max_cols, format, formulas)` | One sheet as markdown or CSV, streamed with `openpyxl` read-only mode. First column is the Excel row number. Paged like `read_file`. `formulas=true` shows formulas instead of cached values. |
| `extract_sheet_images(path, sheet, out_dir, inline)` | Walks `xl/drawings` + rels, writes every embedded picture to `<folder>/_images/<workbook>/<sheet>_<cell>.png` and returns a manifest (sheet, anchor cell, file). `inline=true` returns up to 20 images ≤ 5 MB in the response instead (for read-only shares). Media not anchored to any sheet lands in `_unplaced/`. |
| `extract_pdf_text(path, pages, max_chars)` | Page text via `pdfplumber`; `pages="1-5,12"`. Pages without a text layer are reported as scanned. No OCR. |
| `view_pdf_page(path, page, dpi)` | Renders one page as a JPEG so Claude can look at scanned pages, signatures, stamps and layouts. |
| `extract_docx_text(path, max_chars)` | Headings, paragraphs, lists and tables as markdown via `python-docx`. |
| `extract_pptx_text(path, max_chars)` | Slide titles, bullets, tables and speaker notes via `python-pptx`. |
| `extract_document_images(path, out_dir, inline)` | Pictures out of a docx (order of appearance) or pptx (slide number). |

Extras (`openpyxl`, `pdfplumber`, `python-docx`, `python-pptx`, `reportlab`) are installed by the
installer; if one is missing the tool that needs it says so and the rest of the server keeps working.

## Build

Claude writes markdown or CSV, the server assembles the real file and the result carries a signed
download link, so the user gets a one-click download like file output in a chat.

| Tool | Input |
|---|---|
| `build_xlsx(path, csv_text \| sheets, charts)` | CSV or markdown tables, one or many sheets. Numbers become numeric cells; header bold, frozen, filterable. `charts` adds native Excel charts (column, bar, line, pie, scatter, area, doughnut) drawn from the cells: editable in Excel, no images. |
| `build_docx(path, markdown, title)` | Word document. |
| `build_pptx(path, markdown)` | Slides: every `# Heading` or `---` starts a slide, `Notes:` lines become speaker notes. |
| `build_pdf(path, markdown, title)` | A4 PDF. |

Markdown subset: `#` headings, paragraphs, `-` and `1.` lists (two levels), `| tables |`,
fenced code, `**bold**`, `*italic*`, `` `code` ``, and a `---` line for a page break.
Existing files are not overwritten unless `overwrite=true`.

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
links only work on the LAN. Cloudflare's free plan caps uploads at 100 MB per file. Every link also comes
as `lan_url` (the host's LAN address), which bypasses Cloudflare when you are at home or connected
through the Tailscale subnet router, and as `tailscale_url` when the host itself runs Tailscale.
`MCP_PRIVATE_URL` overrides the private address (e.g. a MagicDNS name). Per-file caps:
`MCP_UPLOAD_MAX_BYTES`, `MCP_FETCH_MAX_BYTES` (4 GiB).

## Edit in place

Same idea as editing a file in a chat: the existing file is changed and handed back with a download
link. Writes are atomic (temp file, then rename).

| Tool | What it does |
|---|---|
| `edit_docx(path, replacements, case_sensitive)` | Find / replace in body, tables, headers and footers. Works at run level so fonts and styles survive, and matches split across formatting are still found. |
| `edit_pptx(path, replacements, case_sensitive)` | Same for slides, tables, grouped shapes and speaker notes. |
| `add_chart(path, sheet, chart, force)` | Native Excel chart into an existing workbook, same spec as `build_xlsx` charts. |
| `write_cells(path, sheet, cells, append_rows, new_sheet, force)` | Change cells (`"=..."` becomes a formula) or append rows. Pictures, charts, comments and validation are kept. Workbooks with shapes, text boxes, slicers, form controls or in-cell pictures are refused unless `force=true`, because saving would drop them. |
| `pdf_pages(path, pages, destination, remove, rotate)` | Extract or remove pages into a new PDF, optionally rotated. |
| `merge_pdfs(paths, destination)` | Concatenate PDFs. |

## Archives, OCR, conversion

| Tool | What it does |
|---|---|
| `list_archive(path, pattern)` | Members of a zip or tar archive, index only, fine on multi-GB files. |
| `extract_archive(path, members, destination)` | Unpacks selected members (names or globs) into the share. Members that try to escape are skipped. Capped by `MCP_EXTRACT_MAX_BYTES` (4 GiB). |
| `ocr_text(path, pages, lang)` | Tesseract OCR on scanned PDFs (20 pages per call) and images. Needs the optional `tesseract-ocr` package; other languages need `tesseract-ocr-<lang>`. |
| `convert_to_pdf(path, destination)` | LibreOffice headless conversion of docx, xlsx, pptx, odt, ods, odp, rtf, csv, txt, html to PDF, with a download link. Needs the optional LibreOffice packages (about 500 MB). |

The installer asks once whether to install each optional package (install and update). Without
it the matching tool explains what is missing; everything else keeps working.

## Environment

| Variable | Meaning |
|---|---|
| `MCP_ROOT` | folder to expose (required) |
| `MCP_READ_ONLY` | `1` hides the write tools; `extract_sheet_images` then needs `inline=true` |
| `MCP_NAME` | connector name shown to Claude |
| `MCP_PUBLIC_URL` | `https://<host>` used in download / upload links |
| `MCP_PRIVATE_URL` | override for the LAN / Tailscale link address |
| `MCP_LINK_MINUTES` | default link lifetime (60) |
| `MCP_UPLOAD_MAX_BYTES`, `MCP_FETCH_MAX_BYTES`, `MCP_EXTRACT_MAX_BYTES` | per-call caps (4 GiB) |
| `MCP_OCR_LANG` | default tesseract language (`eng`) |
