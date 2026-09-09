---
name: archive-extract
description: Extract archives the user transfers as a 7-Zip or zip file with the extension removed and password 123 (typical names look like log-YYYYMMDD-HHMM-xxx). Use this whenever an uploaded file has no extension or a wrong extension, whenever the user says "add .zip and extract", "password is 123", "this is a zip/7z", "unpack this", or when unzip fails on an upload. Do not ask what the file is; run the extractor first. Applies to any content (workpapers, reports, data, code, images), not only audit files.
---

# Archive transfer extraction

The user's standard transfer format is a 7-Zip archive with the extension removed and
password `123`. Some are zip. The user may call either one "a zip". `file` reports
"7-zip archive data" for most of them; the script handles both.

## Steps

1. Run the extractor. It detects zip vs 7z from the file signature, applies the
   password, extracts one level of nested archives and prints the extracted paths
   after `PRESENT:`. Output goes to `/tmp/extracted/<name>/` (or `EXTRACT_DIR`);
   on claude.ai it also copies to `/mnt/user-data/outputs/<name>/`.

   ```bash
   python3 .claude/skills/archive-extract/scripts/extract.py <uploaded-file>
   # optional: --password XXXX   --no-copy   --out DIR
   ```

   Run it from the repo root, or use the absolute path of this skill folder.

2. Show the extracted files to the user (`present_files` on claude.ai, `SendUserFile`
   in Claude Code) and give a one-line summary: file count, folder names, file types,
   anything the naming suggests is missing.

3. Then do whatever the user asked. Pick the next skill from the content, for
   example `ia-workpaper-review` for audit workbooks, `ia-report-writing` for draft
   findings, `xlsx` or `docx` for other Office files, `pdf` for PDFs. If the user
   gave no task, stop after the summary and ask what to do with the files.

## Rules

- Never ask "what is this file" before trying the extractor.
- If password 123 fails the script retries with no password; if that also fails,
  ask the user for the password.
- Never extract into the repo working tree; keep outputs under `/tmp/extracted`,
  the session scratchpad or `/mnt/user-data/outputs`.
- Large `.xlsx` files (over 3 MB) usually contain many screenshots. Warn the
  user that image extraction takes several minutes before starting a full
  workpaper review.
