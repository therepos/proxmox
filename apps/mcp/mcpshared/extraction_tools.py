# Purpose: document extraction tools for mcpshared (xlsx, pdf, docx -> text)
# =============================================================================
# Loaded by server.py:
#
#     from extraction_tools import register as register_extraction
#     register_extraction(mcp, _resolve, rel=_rel, guard=tool, read_only=READ_ONLY)
#
# Design rule: do the work on this box, return text. The only bytes that ever
# leave are small images (extract_sheet_images with inline=true), never a
# base64 blob of the source file. Every tool is hard-capped at MAX_CHARS and
# says so in the output when it truncates.
#
# Tools: list_sheets, read_sheet, extract_sheet_images, extract_pdf_text,
#        extract_docx_text
#
# Third-party deps (installed by mcp-setup.sh, imported lazily so the server
# still boots without them): openpyxl, pdfplumber, python-docx.
# The xlsx orientation and image tools only need the stdlib (zipfile + etree),
# so they stay O(seconds) on 100 MB workbooks: cell data is never parsed.
# =============================================================================

from __future__ import annotations

import base64
import csv
import io
import os
import posixpath
import re
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from typing import Any, Callable

from mcp.types import ImageContent, TextContent, ToolAnnotations

MAX_CHARS = 100_000              # hard cap on text returned by any tool here
MAX_INLINE_IMAGE_BYTES = 5 * 1024 * 1024
MAX_INLINE_IMAGES = 20
XLSX_EXT = {".xlsx", ".xlsm", ".xltx", ".xltm"}
IMAGE_MIME = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".webp": "image/webp",
}

NS = {
    "m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "rel": "http://schemas.openxmlformats.org/package/2006/relationships",
    "xdr": "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing",
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
}
REL_DRAWING = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing"
REL_IMAGE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

RO = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
RW = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False)


# --- Helpers -----------------------------------------------------------------
def _need(module: str, pip_name: str):  # type: ignore[no-untyped-def]
    try:
        return __import__(module)
    except ImportError as e:
        raise RuntimeError(
            f"{pip_name} is not installed in the server environment. "
            "Re-run the installer and choose 'Update server'."
        ) from e


def _cap(text: str, limit: int, hint: str = "") -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    cut = text[:limit]
    nl = cut.rfind("\n")
    if nl > limit * 0.8:
        cut = cut[:nl]
    note = f"\n\n[output truncated at {limit:,} characters]"
    if hint:
        note += f" {hint}"
    return cut + note, True


def _col_letter(idx0: int) -> str:
    """0-based column index -> Excel letters."""
    n = idx0 + 1
    s = ""
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def _cell_ref(ref: str) -> tuple[str, int, int] | None:
    m = re.fullmatch(r"\$?([A-Z]{1,3})\$?(\d+)", ref)
    if not m:
        return None
    col = 0
    for ch in m.group(1):
        col = col * 26 + (ord(ch) - 64)
    return ref.replace("$", ""), int(m.group(2)), col


def _safe_name(s: str) -> str:
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("._")
    return s[:60] or "sheet"


def _parse_pages(spec: str | None, total: int) -> list[int]:
    """'1-5,12' -> [1,2,3,4,5,12] (1-based, clipped to total)."""
    if not spec or not spec.strip():
        return list(range(1, total + 1))
    pages: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, _, b = part.partition("-")
            lo = int(a) if a.strip() else 1
            hi = int(b) if b.strip() else total
        else:
            lo = hi = int(part)
        if lo < 1 or hi < lo:
            raise ValueError(f"Bad page range: {part!r}")
        pages.extend(range(lo, min(hi, total) + 1))
    seen: set[int] = set()
    return [p for p in pages if not (p in seen or seen.add(p))]  # type: ignore[func-returns-value]


def _fmt_cell(v: Any) -> str:
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if hasattr(v, "isoformat"):
        try:
            s = v.isoformat(sep=" ") if hasattr(v, "hour") else v.isoformat()
            return s[:-9] if s.endswith(" 00:00:00") else s
        except TypeError:
            return v.isoformat()
    return str(v).replace("\r\n", " ").replace("\n", " ")


# --- xlsx package walker (stdlib only) --------------------------------------
class _Xlsx:
    """Reads the parts of an xlsx zip needed for orientation and images, never the cells."""

    def __init__(self, path: Path):
        try:
            self.z = zipfile.ZipFile(path)
        except zipfile.BadZipFile as e:
            raise ValueError("Not a valid xlsx file (not a zip archive). Is it an old .xls?") from e
        self.names = set(self.z.namelist())

    def close(self) -> None:
        self.z.close()

    def xml(self, part: str) -> ET.Element | None:
        if part not in self.names:
            return None
        with self.z.open(part) as fh:
            return ET.parse(fh).getroot()

    def rels(self, part: str) -> dict[str, tuple[str, str]]:
        """Relationships for a part: rId -> (type, absolute target part)."""
        d, f = posixpath.split(part)
        root = self.xml(posixpath.join(d, "_rels", f + ".rels"))
        out: dict[str, tuple[str, str]] = {}
        if root is None:
            return out
        for r in root.findall("rel:Relationship", NS):
            target = r.get("Target", "")
            if r.get("TargetMode") == "External":
                continue
            absolute = target.lstrip("/") if target.startswith("/") else posixpath.normpath(posixpath.join(d, target))
            out[r.get("Id", "")] = (r.get("Type", ""), absolute)
        return out

    def sheets(self) -> list[dict[str, Any]]:
        """[{index, name, part, state}] in workbook order."""
        wb = self.xml("xl/workbook.xml")
        if wb is None:
            raise ValueError("Not a valid xlsx file (xl/workbook.xml missing).")
        rels = self.rels("xl/workbook.xml")
        out = []
        for i, s in enumerate(wb.findall("m:sheets/m:sheet", NS), 1):
            rid = s.get(f"{{{NS['r']}}}id", "")
            part = rels.get(rid, ("", ""))[1]
            out.append({"index": i, "name": s.get("name", f"Sheet{i}"), "part": part, "state": s.get("state", "visible")})
        return out

    def dimension(self, sheet_part: str) -> tuple[int | None, int | None]:
        """(rows, cols) from the <dimension> element, streaming; None if the writer omitted it."""
        if sheet_part not in self.names:
            return None, None
        with self.z.open(sheet_part) as fh:
            for _ev, el in ET.iterparse(fh, events=("end",)):
                tag = el.tag.rsplit("}", 1)[-1]
                if tag == "dimension":
                    ref = el.get("ref", "")
                    end = ref.split(":")[-1]
                    c = _cell_ref(end)
                    if c and ":" in ref:
                        return c[1], c[2]
                    if c:  # single cell like "A1": empty or one-cell sheet
                        return c[1], c[2]
                    return None, None
                if tag == "sheetData":     # no dimension before the data: give up cheaply
                    return None, None
        return None, None

    def drawing_parts(self, sheet_part: str) -> list[str]:
        return [t for typ, t in self.rels(sheet_part).values() if typ == REL_DRAWING]

    def pictures(self, drawing_part: str) -> list[dict[str, Any]]:
        """Anchored pictures in a drawing: [{cell, row, col, media, name, ext}]."""
        root = self.xml(drawing_part)
        if root is None:
            return []
        rels = self.rels(drawing_part)
        pics: list[dict[str, Any]] = []
        for anchor in root:
            atag = anchor.tag.rsplit("}", 1)[-1]
            if atag not in ("twoCellAnchor", "oneCellAnchor", "absoluteAnchor"):
                continue
            for pic in anchor.iter(f"{{{NS['xdr']}}}pic"):
                blip = pic.find("xdr:blipFill/a:blip", NS)
                if blip is None:
                    continue
                rid = blip.get(f"{{{NS['r']}}}embed") or blip.get(f"{{{NS['r']}}}link") or ""
                media = rels.get(rid, ("", ""))[1]
                if not media:
                    continue
                frm = anchor.find("xdr:from", NS)
                if frm is not None:
                    col = int(frm.findtext("xdr:col", "0", NS))
                    row = int(frm.findtext("xdr:row", "0", NS))
                    cell = f"{_col_letter(col)}{row + 1}"
                else:
                    col, row, cell = -1, -1, "(absolute)"
                cnv = pic.find("xdr:nvPicPr/xdr:cNvPr", NS)
                pics.append({
                    "cell": cell, "row": row + 1, "col": col + 1, "media": media,
                    "name": (cnv.get("name") if cnv is not None else "") or "",
                    "descr": (cnv.get("descr") if cnv is not None else "") or "",
                    "ext": posixpath.splitext(media)[1].lower(),
                })
        return pics

    def media(self) -> list[str]:
        return sorted(n for n in self.names if n.startswith("xl/media/") and not n.endswith("/"))


# --- Registration ------------------------------------------------------------
def register(
    mcp,  # type: ignore[no-untyped-def]
    resolve: Callable[..., Path],
    *,
    rel: Callable[[Path], str] | None = None,
    guard: Callable[[ToolAnnotations], Callable] | None = None,
    read_only: bool = False,
    max_chars: int = MAX_CHARS,
) -> None:
    """Register the extraction tools on an MCPServer.

    resolve(rel_path, must_exist=True) -> absolute Path inside the share; must raise on escape.
    rel(Path) -> share-relative display string.
    guard(annotations) -> decorator (server.py's `tool`); falls back to mcp.tool().
    """
    _rel = rel or (lambda p: str(p))
    _tool = guard or (lambda ann: mcp.tool(annotations=ann))

    def _xlsx_path(path: str) -> Path:
        p = resolve(path)
        if not p.is_file():
            raise IsADirectoryError(f"Not a file: {path}")
        if p.suffix.lower() not in XLSX_EXT:
            raise ValueError(f"Not an xlsx workbook: {path} (supported: {', '.join(sorted(XLSX_EXT))}).")
        return p

    def _pick_sheet(sheets: list[dict[str, Any]], sheet: str | int | None) -> dict[str, Any]:
        if sheet is None or sheet == "":
            return sheets[0]
        if isinstance(sheet, int) or (isinstance(sheet, str) and sheet.isdigit()):
            i = int(sheet)
            if 1 <= i <= len(sheets):
                return sheets[i - 1]
        for s in sheets:
            if s["name"] == sheet:
                return s
        for s in sheets:
            if s["name"].lower() == str(sheet).lower():
                return s
        raise ValueError(f"No sheet named {sheet!r}. Sheets: {[s['name'] for s in sheets]}")

    # 1 ---------------------------------------------------------------------
    @_tool(RO)
    def list_sheets(path: str) -> dict[str, Any]:
        """List the sheets in an xlsx workbook: name, size (rows x cols) and how many embedded
        images each holds. Cheap orientation call that works on 100 MB workbooks because it reads
        the package XML only, never the cell data. Call this before read_sheet.

        Args:
            path: workbook relative to the share root (.xlsx / .xlsm).
        """
        p = _xlsx_path(path)
        x = _Xlsx(p)
        try:
            out = []
            for s in x.sheets():
                rows, cols = x.dimension(s["part"])
                n_img = sum(len(x.pictures(d)) for d in x.drawing_parts(s["part"]))
                out.append({
                    "index": s["index"], "name": s["name"],
                    "rows": rows, "cols": cols,
                    "range": f"A1:{_col_letter(cols - 1)}{rows}" if rows and cols else None,
                    "images": n_img,
                    "hidden": s["state"] != "visible",
                })
            media = x.media()
            placed = sum(o["images"] for o in out)
        finally:
            x.close()
        return {
            "path": _rel(p),
            "size_bytes": p.stat().st_size,
            "sheets": out,
            "media_files": len(media),
            "unplaced_images": max(0, len(media) - placed),
            "note": "rows/cols come from each sheet's declared range and may include trailing blanks. "
                    "Use read_sheet(path, sheet, start_row, max_rows) to page through cells and "
                    "extract_sheet_images to pull the pictures out.",
        }

    # 2 ---------------------------------------------------------------------
    @_tool(RO)
    def read_sheet(
        path: str,
        sheet: str | None = None,
        start_row: int = 1,
        max_rows: int = 500,
        max_cols: int | None = None,
        format: str = "markdown",
        skip_empty_rows: bool = True,
    ) -> str:
        """Read one sheet of an xlsx workbook as text. Paged like read_file: pass start_row to
        continue. Streams the file, so it is safe on very large workbooks. The first column of the
        output is the Excel row number so results can be cross-referenced with images and formulas.

        Args:
            path: workbook relative to the share root.
            sheet: sheet name or 1-based index. Default: first sheet.
            start_row: first Excel row to return (1-based).
            max_rows: how many rows to return (empty rows are skipped and not counted when skip_empty_rows).
            max_cols: stop after this many columns (default: all).
            format: "markdown" (table) or "csv".
            skip_empty_rows: drop rows with no values at all.
        """
        openpyxl = _need("openpyxl", "openpyxl")
        p = _xlsx_path(path)
        x = _Xlsx(p)
        try:
            meta = _pick_sheet(x.sheets(), sheet)
            total_rows, _ = x.dimension(meta["part"])
        finally:
            x.close()
        if format not in ("markdown", "csv"):
            raise ValueError("format must be 'markdown' or 'csv'")
        start = max(1, int(start_row))
        max_rows = max(1, int(max_rows))
        # Rows are streamed from start_row; the stop bound is generous so blank rows do not
        # eat the budget, but is finite so a sheet of blanks cannot spin forever.
        stop = start + max_rows * (20 if skip_empty_rows else 1) - 1
        if total_rows:
            stop = min(stop, total_rows)

        wb = openpyxl.load_workbook(p, read_only=True, data_only=True, keep_links=False)
        try:
            ws = wb[meta["name"]]
            rows: list[tuple[int, list[str]]] = []
            width = 0
            last_row = start - 1
            for r_idx, row in enumerate(ws.iter_rows(min_row=start, max_row=stop, max_col=max_cols, values_only=True), start):
                vals = [_fmt_cell(v) for v in row]
                while vals and vals[-1] == "":
                    vals.pop()
                last_row = r_idx
                if not vals and skip_empty_rows:
                    continue
                rows.append((r_idx, vals))
                width = max(width, len(vals))
                if len(rows) >= max_rows:
                    break
        finally:
            wb.close()

        # Build the table line by line and stop at the character cap, so the
        # "continue with" hint always points at the first row not shown.
        if format == "csv":
            def line(cells: list[str]) -> str:
                buf = io.StringIO()
                csv.writer(buf, lineterminator="").writerow(cells)
                return buf.getvalue()
            lines = [line(["row"] + [_col_letter(i) for i in range(width)])]
        else:
            def line(cells: list[str]) -> str:
                return "| " + " | ".join(c.replace("|", "\\|") for c in cells) + " |"
            lines = [line(["row"] + [_col_letter(i) for i in range(width)]), "|" + "---|" * (width + 1)]
        used = sum(len(x) + 1 for x in lines)
        shown = 0
        truncated = False
        for r_idx, vals in rows:
            ln = line([str(r_idx)] + vals + [""] * (width - len(vals)))
            if used + len(ln) > max_chars:
                truncated = True
                break
            lines.append(ln)
            used += len(ln) + 1
            shown += 1
        body = "\n".join(lines) if rows else "(no data in this range)"

        end = rows[shown - 1][0] if shown else last_row
        footer = f"\n\n[sheet '{meta['name']}': rows {start}-{max(start, end)}"
        footer += f" of {total_rows}" if total_rows else ""
        footer += f", {shown} non-empty]" if skip_empty_rows else "]"
        if truncated:
            footer += f" [output truncated at {max_chars:,} characters; continue with start_row={end + 1} or use max_cols]"
        elif shown and (not total_rows or end < total_rows):
            footer += f" (continue with start_row={end + 1})"
        return body + footer

    # 3 ---------------------------------------------------------------------
    @_tool(RW if not read_only else RO)
    def extract_sheet_images(
        path: str,
        sheet: str | None = None,
        out_dir: str | None = None,
        inline: bool = False,
    ) -> Any:
        """Pull the pictures embedded in an xlsx workbook (screenshots pasted as evidence, etc.) out
        to files and return a manifest of sheet, anchor cell and output path. View them afterwards
        with view_image. Reads the zip package directly, so it is fast on huge workbooks.

        Args:
            path: workbook relative to the share root.
            sheet: only this sheet (name or 1-based index). Default: every sheet.
            out_dir: folder to write into (relative to share root). Default: "<workbook folder>/_images/<workbook name>".
            inline: return the images (up to 20, each under 5 MB) in the response instead of writing files.
                    Use this when the share is read-only.
        """
        p = _xlsx_path(path)
        x = _Xlsx(p)
        try:
            sheets = x.sheets()
            if sheet not in (None, ""):
                sheets = [_pick_sheet(sheets, sheet)]
            found: list[dict[str, Any]] = []
            used_media: set[str] = set()
            for s in sheets:
                for d in x.drawing_parts(s["part"]):
                    for pic in x.pictures(d):
                        pic["sheet"] = s["name"]
                        found.append(pic)
                        used_media.add(pic["media"])
            unplaced = [m for m in x.media() if m not in used_media] if sheet in (None, "") else []

            manifest: list[dict[str, Any]] = []
            contents: list[ImageContent | TextContent] = []
            written = 0
            skipped: list[str] = []

            def _emit(name: str, member: str, entry: dict[str, Any], dest_dir: Path | None) -> None:
                nonlocal written
                info = x.z.getinfo(member)
                ext = posixpath.splitext(member)[1].lower()
                entry["bytes"] = info.file_size
                entry["viewable"] = ext in IMAGE_MIME
                if inline:
                    if ext not in IMAGE_MIME:
                        skipped.append(f"{name}: {ext} is not viewable inline")
                    elif info.file_size > MAX_INLINE_IMAGE_BYTES:
                        skipped.append(f"{name}: {info.file_size:,} bytes exceeds the inline cap")
                    elif len(contents) >= MAX_INLINE_IMAGES:
                        skipped.append(f"{name}: inline limit of {MAX_INLINE_IMAGES} images reached")
                    else:
                        data = x.z.read(member)
                        contents.append(ImageContent(type="image", data=base64.b64encode(data).decode(), mimeType=IMAGE_MIME[ext]))
                        entry["returned_inline"] = True
                    manifest.append(entry)
                    return
                assert dest_dir is not None
                dest = dest_dir / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                with x.z.open(member) as src, open(dest, "wb") as dst:
                    while chunk := src.read(1 << 20):
                        dst.write(chunk)
                written += 1
                entry["file"] = _rel(dest)
                manifest.append(entry)

            dest_dir: Path | None = None
            if not inline:
                if read_only:
                    raise PermissionError("This share is read-only; call with inline=true to see the images.")
                if out_dir:
                    dest_dir = resolve(out_dir, must_exist=False)
                else:
                    dest_dir = resolve(_rel(p.parent / "_images" / p.stem), must_exist=False)
                if dest_dir.exists() and not dest_dir.is_dir():
                    raise NotADirectoryError(f"out_dir is not a directory: {out_dir}")

            counter: dict[str, int] = {}
            for pic in found:
                key = f"{_safe_name(pic['sheet'])}_{pic['cell']}"
                counter[key] = counter.get(key, 0) + 1
                suffix = f"_{counter[key]}" if counter[key] > 1 else ""
                name = f"{key}{suffix}{pic['ext'] or '.bin'}"
                entry = {"sheet": pic["sheet"], "cell": pic["cell"], "row": pic["row"], "col": pic["col"]}
                if pic["descr"]:
                    entry["alt_text"] = pic["descr"][:200]
                _emit(name, pic["media"], entry, dest_dir)
            for m in unplaced:
                name = "_unplaced/" + posixpath.basename(m)
                _emit(name, m, {"sheet": None, "cell": None, "note": "in the package but not anchored to any sheet (in-cell picture or orphan)"}, dest_dir)
        finally:
            x.close()

        result: dict[str, Any] = {
            "path": _rel(p),
            "sheets_scanned": [s["name"] for s in sheets],
            "images": len(manifest),
            "manifest": manifest,
        }
        if not inline:
            result["out_dir"] = _rel(dest_dir) if dest_dir else None
            result["written"] = written
            result["next"] = "Use view_image(file) on any entry with viewable=true." if written else "No embedded images found."
        if skipped:
            result["skipped"] = skipped
        if not found and not unplaced:
            result["note"] = "No pictures found in this workbook (charts and shapes are not pictures)."
        if inline:
            text = _cap(_json(result), max_chars)[0]
            return [TextContent(type="text", text=text), *contents]
        return result

    # 4 ---------------------------------------------------------------------
    @_tool(RO)
    def extract_pdf_text(path: str, pages: str | None = None, max_chars: int = MAX_CHARS) -> str:
        """Extract the text of a PDF, page by page. Scanned pages (image only, no text layer) are
        reported as such rather than returned empty. There is no OCR.

        Args:
            path: PDF relative to the share root.
            pages: page selection, 1-based, e.g. "1-5,12" or "3-". Default: all pages.
            max_chars: cap on returned characters (hard limit 100k).
        """
        pdfplumber = _need("pdfplumber", "pdfplumber")
        p = resolve(path)
        if not p.is_file():
            raise IsADirectoryError(f"Not a file: {path}")
        limit = max(1_000, min(int(max_chars), MAX_CHARS))
        chunks: list[str] = []
        scanned: list[int] = []
        empty: list[int] = []
        used = 0
        stopped_at: int | None = None
        with pdfplumber.open(p) as pdf:
            total = len(pdf.pages)
            wanted = _parse_pages(pages, total)
            if not wanted:
                raise ValueError(f"No pages selected (document has {total}).")
            for n in wanted:
                if used >= limit:
                    stopped_at = n
                    break
                page = pdf.pages[n - 1]
                try:
                    text = (page.extract_text() or "").strip()
                except Exception as e:  # noqa: BLE001  broken page, keep going
                    text = f"[could not extract page {n}: {type(e).__name__}]"
                if not text:
                    if page.images:
                        scanned.append(n)
                        text = "[no text layer: scanned image]"
                    else:
                        empty.append(n)
                        text = "[blank page]"
                block = f"--- page {n} of {total} ---\n{text}"
                chunks.append(block)
                used += len(block) + 2
                if hasattr(page, "flush_cache"):
                    page.flush_cache()
        body = "\n\n".join(chunks)
        body, truncated = _cap(body, limit, "Request fewer pages with pages=\"a-b\".")
        notes = [f"[{len(wanted)} of {total} pages requested]"]
        if scanned:
            if len(scanned) == len(wanted):
                notes.append("This PDF is a scanned image with no text layer. OCR is not available on this server.")
            else:
                notes.append(f"Scanned pages (no text layer): {_ranges(scanned)}.")
        if empty and len(empty) == len(wanted):
            notes.append("No text found on any requested page.")
        if stopped_at is not None and not truncated:
            notes.append(f"Stopped before page {stopped_at} at the character cap; continue with pages=\"{stopped_at}-\".")
        return body + "\n\n" + " ".join(notes)

    # 5 ---------------------------------------------------------------------
    @_tool(RO)
    def extract_docx_text(path: str, max_chars: int = MAX_CHARS) -> str:
        """Convert a Word .docx to markdown text: headings, paragraphs, lists and tables in document
        order. Embedded pictures are counted, not returned.

        Args:
            path: document relative to the share root.
            max_chars: cap on returned characters (hard limit 100k).
        """
        docx = _need("docx", "python-docx")
        from docx.table import Table
        from docx.text.paragraph import Paragraph

        p = resolve(path)
        if not p.is_file():
            raise IsADirectoryError(f"Not a file: {path}")
        if p.suffix.lower() != ".docx":
            raise ValueError("Only .docx is supported (save .doc as .docx first).")
        limit = max(1_000, min(int(max_chars), MAX_CHARS))
        doc = docx.Document(str(p))
        out: list[str] = []

        def para_md(para: Paragraph) -> str:
            text = para.text.strip()
            if not text:
                return ""
            style = (para.style.name if para.style is not None else "") or ""
            m = re.match(r"heading\s*(\d)", style, re.I)
            if m:
                return "#" * min(int(m.group(1)), 6) + " " + text
            if style.lower() == "title":
                return "# " + text
            if "list" in style.lower() or para._p.find(".//{http://schemas.openxmlformats.org/wordprocessingml/2006/main}numPr") is not None:
                return "- " + text
            return text

        def table_md(tbl: Table) -> str:
            rows: list[list[str]] = []
            for r in tbl.rows:
                cells = []
                seen = set()
                for c in r.cells:
                    if id(c._tc) in seen:   # merged cells repeat the same element
                        continue
                    seen.add(id(c._tc))
                    cells.append(" ".join(c.text.split()).replace("|", "\\|"))
                rows.append(cells)
            if not rows:
                return ""
            width = max(len(r) for r in rows)
            rows = [r + [""] * (width - len(r)) for r in rows]
            lines = ["| " + " | ".join(rows[0]) + " |", "|" + "---|" * width]
            lines += ["| " + " | ".join(r) + " |" for r in rows[1:]]
            return "\n".join(lines)

        body_el = doc.element.body
        for child in body_el.iterchildren():
            tag = child.tag.rsplit("}", 1)[-1]
            if tag == "p":
                s = para_md(Paragraph(child, doc))
            elif tag == "tbl":
                s = table_md(Table(child, doc))
            else:
                continue
            if s:
                out.append(s)
        n_images = sum(1 for r in doc.part.rels.values() if "image" in r.reltype)
        text = "\n\n".join(out)
        text, _ = _cap(text, limit, "The document is longer than the cap.")
        notes = [f"[{len(doc.paragraphs)} paragraphs, {len(doc.tables)} tables"]
        if n_images:
            notes.append(f"{n_images} embedded pictures not extracted")
        return text + "\n\n" + ", ".join(notes) + "]"


def _ranges(nums: list[int]) -> str:
    out: list[str] = []
    start = prev = nums[0]
    for n in nums[1:] + [None]:  # type: ignore[list-item]
        if n is not None and n == prev + 1:
            prev = n
            continue
        out.append(str(start) if start == prev else f"{start}-{prev}")
        if n is not None:
            start = prev = n
    return ", ".join(out)


def _json(obj: Any) -> str:
    import json
    return json.dumps(obj, indent=2, ensure_ascii=False, default=str)
