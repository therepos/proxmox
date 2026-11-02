---
name: zipper
description: Unzip or zip the user's password-protected transfer archives. They are 7-Zip (sometimes zip) files with the extension removed, typically named like YYYYMMDD-HHMMSS, or split into parts named YYYYMMDD-HHMMSS.001, .002, ... Use this whenever an uploaded file has no extension or a wrong extension, when files end in .001/.002, when the user says "unzip this", "unpack this", "this is a zip/7z", "add .zip and extract", or asks to zip, compress or package files for sending. Do not ask what the file is; run the script first. Applies to any content (workpapers, reports, data, code, images).
---

# Zipper: transfer archives

The user's transfer format is a password-protected 7-Zip archive with the extension
removed. Archives over 500 MB are split into numbered parts (`.001`, `.002`, ...).
The password only hides the content from email and upload scanners. The user is
not technical: never ask them to edit files, set variables or run commands.

The password is never written in this skill. The script reads `--password`, then
`$ZIPPER_PASSWORD`, then its saved settings. If the user's preferences, custom
instructions or memory give their zip password, pass it with `--password` on every
`unzip` / `zip` call instead of asking.

## Unzip

```bash
python3 <skill-folder>/scripts/zipper.py unzip <file> [<file> ...]
```

`<skill-folder>` is the folder holding this SKILL.md (e.g. `~/.claude/skills/zipper`).

- Pass every uploaded file or part. Any one part of a split set is enough; the
  script finds the others in the same folder and checks none are missing.
- Output goes to `<folder>/<name>/`: `/mnt/user-data/outputs` on claude.ai, otherwise
  `/tmp/extracted`. Override with `--out DIR`.
- One level of nested archives is extracted too.
- The last line `PRESENT: ...` lists the extracted files.

Then:
1. Show the files (`present_files` on claude.ai, `SendUserFile` in Claude Code, or the
   platform's file attachment) with a one-line summary: file count, folders, types,
   anything that looks missing.
2. Do what the user asked, picking the next skill from the content (for example
   `ia-workpaper-review` for audit workbooks, `xlsx`, `docx`, `pdf`). If they gave no
   task, stop after the summary and ask what to do with the files.

## Zip

```bash
python3 <skill-folder>/scripts/zipper.py zip <file-or-folder> [...] [--out DIR] [--split-mb N]
```

Creates `YYYYMMDD-HHMMSS` (no extension), or `.001`, `.002`, ... parts when larger
than the split size (default 500 MB). Content and file names are encrypted. Output
goes to `/mnt/user-data/outputs` on claude.ai, otherwise `~/Downloads`. Present the
result files to the user and remind them to keep all parts together.

## When the script prints NEED_PASSWORD (exit code 3)

1. Ask the user once, in plain words: "What's your zip password?"
2. Save it, then rerun the same command:
   ```bash
   printf '%s' 'THE-PASSWORD' | python3 <skill-folder>/scripts/zipper.py password set
   ```
3. In a chat app where the sandbox resets between conversations (claude.ai,
   ChatGPT), tell the user they can add one line to their personal preferences /
   custom instructions, e.g. "My zip transfer password is ...", so future chats
   never ask. Offer to save it to memory instead if the platform has memory.

If a password the user gives still fails, say the archive's password differs and
ask for that archive's password. Do not guess.

## Settings the user may ask for

| User says | Run |
|---|---|
| "change / reset my zip password" | ask for the new one, then `password set` as above |
| "forget my password" | `zipper.py password forget` |
| "save zips to X" / "unzip into X" | `zipper.py config --out X` (`--out ""` resets) |
| "split at 200 MB" / "don't split" | `zipper.py config --split-mb 200` / `--split-mb 0` |
| "what are my settings" | `zipper.py config` (never shows the password) |

## Rules

- Never ask "what is this file" before running `unzip`.
- Never print, echo or write the password into chat, files, commits or logs.
- Never extract into a repository working tree; keep outputs under `/tmp/extracted`,
  the session scratchpad or `/mnt/user-data/outputs`.
- Large `.xlsx` files (over 3 MB) usually contain many screenshots. Warn the user
  that image extraction takes several minutes before a full workpaper review.
