# Purpose: edit existing office files in place (docx, pptx, xlsx, pdf)
# =============================================================================
# Loaded by server.py (write mode only):
#
#     from edit_tools import register as register_edit
#     register_edit(mcp, _resolve, rel=_rel, guard=tool, link=download_link_for)
#
#   edit_docx(path, replacements)    find / replace text, formatting kept
#   edit_pptx(path, replacements)    same for slides and notes
#   write_cells(path, sheet, cells)  change cells / append rows in a workbook
#   add_chart(path, sheet, chart)    native Excel chart into an existing workbook
#   pdf_pages(path, pages, dest)     extract, remove or rotate pages
#   merge_pdfs(paths, dest)          concatenate PDFs
#
# Every tool rewrites the file atomically (temp file + rename) and returns a
# download link. Word / PowerPoint edits work at run level, so bold, fonts and
# styles survive and matches split across runs are still found.
#
# write_cells refuses workbooks with parts openpyxl would drop on save
# (shapes, text boxes, slicers, form controls, in-cell pictures) unless
# force=true; pasted pictures, charts, validation and comments are kept.
#
# Deps (lazy): python-docx, python-pptx, openpyxl, pypdf.
# =============================================================================

from __future__ import annotations

import os
import re
import zipfile
from pathlib import Path
from typing import Any, Callable, Iterable

from mcp.types import ToolAnnotations

RW = ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=False, openWorldHint=False)
MAX_REPLACEMENTS = 200


def _need(module: str, pip_name: str):  # type: ignore[no-untyped-def]
    try:
        return __import__(module)
    except ImportError as e:
        raise RuntimeError(f"{pip_name} is not installed in the server environment. Re-run the installer and choose 'Update server'.") from e


def _parse_pages(spec: str | None, total: int) -> list[int]:
    if not spec or not spec.strip():
        return list(range(1, total + 1))
    out: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, _, b = part.partition("-")
            lo, hi = (int(a) if a.strip() else 1), (int(b) if b.strip() else total)
        else:
            lo = hi = int(part)
        if lo < 1 or hi < lo or lo > total:
            raise ValueError(f"Bad page range: {part!r} (document has {total} pages)")
        out.extend(range(lo, min(hi, total) + 1))
    seen: set[int] = set()
    return [p for p in out if not (p in seen or seen.add(p))]  # type: ignore[func-returns-value]


def _norm_replacements(replacements: list[dict[str, str]]) -> list[tuple[str, str]]:
    if not replacements:
        raise ValueError("replacements is empty.")
    if len(replacements) > MAX_REPLACEMENTS:
        raise ValueError(f"At most {MAX_REPLACEMENTS} replacements per call.")
    out = []
    for r in replacements:
        find = str(r.get("find", ""))
        if not find:
            raise ValueError("Each replacement needs a non-empty 'find'.")
        out.append((find, str(r.get("replace", ""))))
    return out


def _replace_in_runs(runs: list[Any], find: str, repl: str, case_sensitive: bool) -> int:
    """Replace across a run sequence sharing one paragraph; returns number of replacements."""
    texts = [r.text or "" for r in runs]
    full = "".join(texts)
    if not full:
        return 0
    hay = full if case_sensitive else full.lower()
    needle = find if case_sensitive else find.lower()
    hits = []
    pos = 0
    while True:
        i = hay.find(needle, pos)
        if i < 0:
            break
        hits.append(i)
        pos = i + len(needle)
    if not hits:
        return 0
    # work from the last hit backwards so earlier offsets stay valid
    for i in reversed(hits):
        j = i + len(find)
        offsets = []
        o = 0
        for t in texts:
            offsets.append(o)
            o += len(t)
        a = max(k for k in range(len(texts)) if offsets[k] <= i) if texts else 0
        b = max(k for k in range(len(texts)) if offsets[k] < j)
        if a == b:
            t = texts[a]
            texts[a] = t[: i - offsets[a]] + repl + t[j - offsets[a]:]
        else:
            texts[a] = texts[a][: i - offsets[a]] + repl
            for k in range(a + 1, b):
                texts[k] = ""
            texts[b] = texts[b][j - offsets[b]:]
    for r, t in zip(runs, texts):
        if (r.text or "") != t:
            r.text = t
    return len(hits)


def _docx_paragraphs(doc) -> Iterable[Any]:  # type: ignore[no-untyped-def]
    def walk(container):  # type: ignore[no-untyped-def]
        for p in container.paragraphs:
            yield p
        for t in container.tables:
            for row in t.rows:
                seen = set()
                for cell in row.cells:
                    if id(cell._tc) in seen:
                        continue
                    seen.add(id(cell._tc))
                    yield from walk(cell)

    yield from walk(doc)
    for section in doc.sections:
        for part in (section.header, section.footer, section.first_page_header, section.first_page_footer,
                     section.even_page_header, section.even_page_footer):
            try:
                if part is not None and not part.is_linked_to_previous:
                    yield from walk(part)
            except Exception:  # noqa: BLE001
                continue


def _pptx_paragraphs(prs) -> Iterable[tuple[int, Any]]:  # type: ignore[no-untyped-def]
    def shapes(coll):  # type: ignore[no-untyped-def]
        for sh in coll:
            if sh.shape_type == 6 and hasattr(sh, "shapes"):  # group
                yield from shapes(sh.shapes)
            else:
                yield sh

    for n, slide in enumerate(prs.slides, 1):
        for sh in shapes(slide.shapes):
            if sh.has_text_frame:
                for p in sh.text_frame.paragraphs:
                    yield n, p
            if getattr(sh, "has_table", False) and sh.has_table:
                for row in sh.table.rows:
                    for cell in row.cells:
                        for p in cell.text_frame.paragraphs:
                            yield n, p
        if slide.has_notes_slide:
            for p in slide.notes_slide.notes_text_frame.paragraphs:
                yield n, p


UNSAFE_XLSX = {
    "xl/ctrlProps/": "form controls",
    "xl/slicers/": "slicers",
    "xl/richData/": "in-cell pictures",
    "xl/timelines/": "timelines",
}


def _xlsx_unsafe_parts(p: Path) -> list[str]:
    found: set[str] = set()
    with zipfile.ZipFile(p) as z:
        names = z.namelist()
        for n in names:
            for prefix, what in UNSAFE_XLSX.items():
                if n.startswith(prefix):
                    found.add(what)
            if n.startswith("xl/drawings/drawing") and n.endswith(".xml"):
                data = z.read(n)
                if b"<xdr:sp" in data or b"<xdr:cxnSp" in data or b"<xdr:grpSp" in data:
                    found.add("shapes or text boxes")
    return sorted(found)


# --- Registration ------------------------------------------------------------
def register(
    mcp,  # type: ignore[no-untyped-def]
    resolve: Callable[..., Path],
    *,
    rel: Callable[[Path], str],
    guard: Callable[[ToolAnnotations], Callable],
    link: Callable[[Path], dict[str, Any]],
) -> None:
    def _file(path: str, *exts: str) -> Path:
        p = resolve(path)
        if not p.is_file():
            raise IsADirectoryError(f"Not a file: {path}")
        if exts and p.suffix.lower() not in exts:
            raise ValueError(f"Expected {' / '.join(exts)}: {path}")
        return p

    def _atomic_save(p: Path, save: Callable[[str], None]) -> None:
        tmp = p.with_name(f".{p.name}.tmp")
        try:
            save(str(tmp))
            os.replace(tmp, p)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise

    def _out(path: str | None, src: Path, suffix: str) -> Path:
        if path:
            d = resolve(path, must_exist=False)
            if d.is_dir() or path.endswith("/"):
                d = d / (src.stem + suffix)
            elif d.suffix.lower() != ".pdf":
                d = d.with_name(d.name + ".pdf")
        else:
            d = src.with_name(src.stem + suffix)
        if d.exists() and d != src:
            raise FileExistsError(f"Destination exists: {rel(d)} (pick another destination)")
        d.parent.mkdir(parents=True, exist_ok=True)
        return d

    # --- docx ----------------------------------------------------------------------
    @guard(RW)
    def edit_docx(path: str, replacements: list[dict[str, str]], case_sensitive: bool = True) -> dict[str, Any]:
        """Find and replace text in an existing Word document, in place, keeping fonts, styles,
        tables, headers and footers intact. Matches that span formatting boundaries are handled.
        Read the document first (extract_docx_text) so the 'find' strings are exact.

        Args:
            path: .docx relative to the share root.
            replacements: [{"find": "old text", "replace": "new text"}, ...] applied in order.
            case_sensitive: match case exactly.
        """
        docx = _need("docx", "python-docx")
        p = _file(path, ".docx")
        pairs = _norm_replacements(replacements)
        doc = docx.Document(str(p))
        counts = {f: 0 for f, _ in pairs}
        for par in _docx_paragraphs(doc):
            runs = list(par.runs)
            if not runs:
                continue
            for f, r in pairs:
                counts[f] += _replace_in_runs(runs, f, r, case_sensitive)
        total = sum(counts.values())
        if total:
            _atomic_save(p, doc.save)
        out: dict[str, Any] = {"saved": rel(p), "replacements": total, "per_find": counts}
        if not total:
            out["note"] = "Nothing matched. Check the exact wording with extract_docx_text."
        else:
            out["download"] = link(p)
        return out

    # --- pptx ----------------------------------------------------------------------
    @guard(RW)
    def edit_pptx(path: str, replacements: list[dict[str, str]], case_sensitive: bool = True) -> dict[str, Any]:
        """Find and replace text in an existing PowerPoint deck, in place: titles, bullets, tables,
        grouped shapes and speaker notes, formatting kept.

        Args:
            path: .pptx relative to the share root.
            replacements: [{"find": "old", "replace": "new"}, ...].
            case_sensitive: match case exactly.
        """
        pptx = _need("pptx", "python-pptx")
        p = _file(path, ".pptx")
        pairs = _norm_replacements(replacements)
        prs = pptx.Presentation(str(p))
        counts = {f: 0 for f, _ in pairs}
        slides_touched: set[int] = set()
        for n, par in _pptx_paragraphs(prs):
            runs = list(par.runs)
            if not runs:
                continue
            for f, r in pairs:
                c = _replace_in_runs(runs, f, r, case_sensitive)
                counts[f] += c
                if c:
                    slides_touched.add(n)
        total = sum(counts.values())
        if total:
            _atomic_save(p, prs.save)
        out: dict[str, Any] = {"saved": rel(p), "replacements": total, "per_find": counts, "slides_changed": sorted(slides_touched)}
        if not total:
            out["note"] = "Nothing matched. Check the exact wording with extract_pptx_text."
        else:
            out["download"] = link(p)
        return out

    # --- xlsx ----------------------------------------------------------------------
    @guard(RW)
    def write_cells(
        path: str,
        sheet: str | None = None,
        cells: dict[str, Any] | None = None,
        append_rows: list[list[Any]] | None = None,
        new_sheet: bool = False,
        force: bool = False,
    ) -> dict[str, Any]:
        """Change cells in an existing workbook, in place. Values starting with "=" are written as
        formulas. Formatting, other sheets, pasted pictures, charts, comments and validation are
        kept. Workbooks containing shapes, text boxes, slicers, form controls or in-cell pictures
        are refused unless force=true, because saving would drop them.

        Args:
            path: .xlsx or .xlsm relative to the share root.
            sheet: sheet name or 1-based index. Default: active sheet.
            cells: {"B3": 42, "C4": "=SUM(C1:C3)", "A10": "text"}.
            append_rows: rows to add after the last used row, e.g. [["R31", "Risk", 12.5]].
            new_sheet: create the sheet if it does not exist.
            force: save even if unsupported parts would be lost.
        """
        openpyxl = _need("openpyxl", "openpyxl")
        p = _file(path, ".xlsx", ".xlsm")
        if not cells and not append_rows:
            raise ValueError("Pass cells and/or append_rows.")
        unsafe = _xlsx_unsafe_parts(p)
        if unsafe and not force:
            raise ValueError(
                "This workbook contains " + ", ".join(unsafe) + " which would be lost on save. "
                "Pass force=true to proceed anyway, or build a new workbook with build_xlsx."
            )
        wb = openpyxl.load_workbook(p, keep_vba=p.suffix.lower() == ".xlsm")
        if sheet in (None, ""):
            ws = wb.active
        elif isinstance(sheet, str) and sheet.isdigit() and 1 <= int(sheet) <= len(wb.sheetnames):
            ws = wb.worksheets[int(sheet) - 1]
        elif sheet in wb.sheetnames:
            ws = wb[sheet]
        elif new_sheet:
            ws = wb.create_sheet(str(sheet)[:31])
        else:
            raise ValueError(f"No sheet named {sheet!r}. Sheets: {wb.sheetnames}")
        written = 0
        for ref, val in (cells or {}).items():
            if not re.fullmatch(r"[A-Za-z]{1,3}\d{1,7}", ref):
                raise ValueError(f"Bad cell reference: {ref}")
            ws[ref.upper()] = val
            written += 1
        appended = 0
        for row in append_rows or []:
            ws.append(list(row))
            appended += 1
        _atomic_save(p, wb.save)
        out = {"saved": rel(p), "sheet": ws.title, "cells_written": written, "rows_appended": appended, "download": link(p)}
        if unsafe:
            out["warning"] = "Saved with force=true; lost: " + ", ".join(unsafe)
        return out

    @guard(RW)
    def add_chart(path: str, sheet: str, chart: dict[str, Any], force: bool = False) -> dict[str, Any]:
        """Add a native Excel chart (editable, not an image) to an existing workbook, drawn from
        cells already in it. Same safety rule as write_cells.

        Args:
            path: .xlsx or .xlsm relative to the share root.
            sheet: sheet that receives the chart (name or 1-based index).
            chart: {"type": "column|bar|line|pie|scatter|area|doughnut", "data": "B1:C13"
                (first row = series names), "categories": "A2:A13", "title": "...", "x_title": "...",
                "y_title": "...", "anchor": "E2", "stacked": false, "sheet": "<data sheet if different>"}.
            force: save even if unsupported parts would be lost.
        """
        openpyxl = _need("openpyxl", "openpyxl")
        from build_tools import add_native_chart
        p = _file(path, ".xlsx", ".xlsm")
        unsafe = _xlsx_unsafe_parts(p)
        if unsafe and not force:
            raise ValueError("This workbook contains " + ", ".join(unsafe) + " which would be lost on save. Pass force=true to proceed anyway.")
        wb = openpyxl.load_workbook(p, keep_vba=p.suffix.lower() == ".xlsm")
        if isinstance(sheet, str) and sheet.isdigit() and 1 <= int(sheet) <= len(wb.sheetnames):
            ws = wb.worksheets[int(sheet) - 1]
        elif sheet in wb.sheetnames:
            ws = wb[sheet]
        else:
            raise ValueError(f"No sheet named {sheet!r}. Sheets: {wb.sheetnames}")
        note = add_native_chart(wb, ws, dict(chart))
        _atomic_save(p, wb.save)
        out = {"saved": rel(p), "chart": note, "download": link(p)}
        if unsafe:
            out["warning"] = "Saved with force=true; lost: " + ", ".join(unsafe)
        return out

    # --- pdf -----------------------------------------------------------------------
    @guard(RW)
    def pdf_pages(
        path: str,
        pages: str,
        destination: str | None = None,
        remove: bool = False,
        rotate: int = 0,
    ) -> dict[str, Any]:
        """Extract pages from a PDF into a new file, or remove them, optionally rotating.
        Use it to split a document or pull the signed page out of a pack.

        Args:
            path: source PDF relative to the share root.
            pages: 1-based selection, e.g. "1-3,7".
            destination: output .pdf path or folder. Default: "<name>-pages.pdf" next to the source.
            remove: keep every page except the selection instead.
            rotate: 90, 180 or 270 degrees clockwise applied to the output pages.
        """
        pypdf = _need("pypdf", "pypdf")
        if rotate not in (0, 90, 180, 270):
            raise ValueError("rotate must be 0, 90, 180 or 270.")
        src = _file(path, ".pdf")
        reader = pypdf.PdfReader(str(src))
        if reader.is_encrypted:
            try:
                reader.decrypt("")
            except Exception as e:  # noqa: BLE001
                raise ValueError("PDF is password-protected.") from e
        total = len(reader.pages)
        chosen = set(_parse_pages(pages, total))
        keep = [n for n in range(1, total + 1) if (n not in chosen) == remove]
        if not keep:
            raise ValueError("No pages left to write.")
        dest = _out(destination, src, "-pages.pdf")
        writer = pypdf.PdfWriter()
        for n in keep:
            page = reader.pages[n - 1]
            if rotate:
                page.rotate(rotate)
            writer.add_page(page)
        _atomic_save(dest, lambda tmp: writer.write(tmp))
        return {"source": rel(src), "saved": rel(dest), "pages": len(keep), "of": total, "download": link(dest)}

    @guard(RW)
    def merge_pdfs(paths: list[str], destination: str) -> dict[str, Any]:
        """Concatenate several PDFs into one, in the order given.

        Args:
            paths: source PDFs relative to the share root.
            destination: output .pdf path relative to the share root.
        """
        pypdf = _need("pypdf", "pypdf")
        if len(paths) < 2:
            raise ValueError("Give at least two PDFs.")
        srcs = [_file(x, ".pdf") for x in paths]
        dest = _out(destination, srcs[0], "-merged.pdf")
        writer = pypdf.PdfWriter()
        pages = 0
        for s in srcs:
            r = pypdf.PdfReader(str(s))
            if r.is_encrypted:
                r.decrypt("")
            for page in r.pages:
                writer.add_page(page)
                pages += 1
        _atomic_save(dest, lambda tmp: writer.write(tmp))
        return {"saved": rel(dest), "sources": [rel(s) for s in srcs], "pages": pages, "download": link(dest)}
