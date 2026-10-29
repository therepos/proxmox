#!/usr/bin/env python3
"""
zipper.py
---------
Compress files/folders into a password-protected 7z archive,
or extract a password-protected 7z archive.
Auto-installs 7-Zip if not present (Windows / macOS / Linux).

ZIP MODE
  Output filename : YYYYMMDD-HHMMSS   (no extension, placed next to script)
  Password        : prompts (press Enter to use the default 'Zip@2026!')

UNZIP MODE
  Input           : a 7z archive (with or without .7z extension)
  Password        : prompts (press Enter to use the default 'Zip@2026!';
                    will re-prompt if wrong)
  Output          : a folder next to the archive (or a path you choose)

Usage
  python zipper.py                              (GUI window docked right, always on top)
  python zipper.py --cli                        (console menu — asks zip or unzip)
  python zipper.py --zip   <file_or_folder> ...
  python zipper.py --unzip <archive> [output_dir]
  python zipper.py --password <pw> --zip <file_or_folder> ...
  python zipper.py <file_or_folder> ...         (legacy: defaults to zip)

GUI
  Drag any number of files/folders from Explorer onto the window (or use
  Add files / Add folder). The window docks to the right edge of the screen
  and stays on top so Explorer remains usable beside it.

Flags
  --cli                   console menu instead of the GUI
  --zip / -z              compress mode
  --unzip / -u / -x       extract mode
  --password <pw> / -p    skip the password prompt and use this value
"""

import sys
import os
import subprocess
import shutil
import platform
from datetime import datetime
from pathlib import Path


DEFAULT_PASSWORD = "Zip@2026!"

# Standard install locations 7-Zip uses on Windows
WIN_PATHS = [
    r"C:\Program Files\7-Zip\7z.exe",
    r"C:\Program Files (x86)\7-Zip\7z.exe",
]


# ──────────────────────────────────────────────
# 1.  FIND 7-ZIP
# ──────────────────────────────────────────────

def find_7z() -> str | None:
    """Return path to 7z executable, or None if not found."""
    for candidate in ("7z", "7za", "7zz"):
        found = shutil.which(candidate)
        if found:
            return found
    for p in WIN_PATHS:
        if os.path.isfile(p):
            return p
    return None


# ──────────────────────────────────────────────
# 2.  AUTO-INSTALL HELPERS
# ──────────────────────────────────────────────

def _install_windows() -> str:
    """Install via winget (Win 10/11). Falls back to direct MSI download."""
    if shutil.which("winget"):
        print("[*] Installing 7-Zip via winget ...")
        result = subprocess.run(
            ["winget", "install", "-e", "--id", "7zip.7zip",
             "--accept-package-agreements", "--accept-source-agreements"],
            capture_output=False,
            text=True,
        )
        if result.returncode == 0:
            os.environ["PATH"] += r";C:\Program Files\7-Zip"
            found = find_7z()
            if found:
                return found

    # Fallback: download MSI directly
    import urllib.request, tempfile
    print("[*] winget unavailable - downloading 7-Zip MSI installer ...")
    url = "https://www.7-zip.org/a/7z2409-x64.msi"
    tmp = os.path.join(tempfile.gettempdir(), "7zip_installer.msi")
    urllib.request.urlretrieve(url, tmp)
    print("[*] Running silent install ...")
    subprocess.run(["msiexec", "/i", tmp, "/quiet", "/norestart"], check=True)
    os.environ["PATH"] += r";C:\Program Files\7-Zip"
    found = find_7z()
    if found:
        return found
    raise RuntimeError("7-Zip installation finished but executable still not found.")


def _install_macos() -> str:
    """Install via Homebrew."""
    if not shutil.which("brew"):
        raise RuntimeError(
            "Homebrew is not installed. Install it from https://brew.sh then re-run."
        )
    print("[*] Installing p7zip via Homebrew ...")
    subprocess.run(["brew", "install", "p7zip"], check=True, capture_output=False)
    found = find_7z()
    if found:
        return found
    raise RuntimeError("p7zip installed but executable not found.")


def _install_linux() -> str:
    """Try apt, dnf, pacman, zypper in order."""
    managers = [
        (["apt-get", "install", "-y", "p7zip-full"],             "apt-get"),
        (["dnf",     "install", "-y", "p7zip", "p7zip-plugins"], "dnf"),
        (["pacman",  "-S", "--noconfirm", "p7zip"],              "pacman"),
        (["zypper",  "install", "-y", "p7zip"],                  "zypper"),
    ]
    for cmd, name in managers:
        if shutil.which(cmd[0]):
            print(f"[*] Installing p7zip via {name} ...")
            subprocess.run(["sudo"] + cmd, check=True, capture_output=False)
            found = find_7z()
            if found:
                return found
            raise RuntimeError(f"{name} finished but executable not found.")
    raise RuntimeError(
        "No supported package manager found (apt, dnf, pacman, zypper). "
        "Please install p7zip manually and re-run."
    )


def ensure_7z() -> str:
    """Return path to 7z, auto-installing if necessary."""
    found = find_7z()
    if found:
        return found

    system = platform.system()
    print(f"[!] 7-Zip not found. Auto-installing for {system} ...\n")

    if system == "Windows":
        return _install_windows()
    elif system == "Darwin":
        return _install_macos()
    elif system == "Linux":
        return _install_linux()
    else:
        raise RuntimeError(
            f"Unsupported OS '{system}'. Install 7-Zip manually and re-run."
        )


# ──────────────────────────────────────────────
# 3.  COLLECT & VALIDATE TARGETS  (for ZIP mode)
# ──────────────────────────────────────────────

def collect_targets(raw_paths: list[str]) -> list[Path]:
    """
    Resolve and validate a list of raw path strings.
    Skips duplicates (by resolved path). Exits if any path is invalid.
    """
    seen:    set[Path]  = set()
    targets: list[Path] = []
    errors:  list[str]  = []

    for raw in raw_paths:
        p = Path(raw.strip().strip('"').strip("'")).expanduser().resolve()
        if not p.exists():
            errors.append(f"  [!] Not found     : {p}")
        elif not p.is_file() and not p.is_dir():
            errors.append(f"  [!] Not a file/dir: {p}")
        elif p in seen:
            print(f"  [-] Duplicate skip: {p}")
        else:
            seen.add(p)
            targets.append(p)

    if errors:
        print("\n[!] Some paths could not be resolved:")
        for e in errors:
            print(e)
        sys.exit(1)

    return targets


def split_dropped(line: str) -> list[str]:
    """
    Dropping several files into a console pastes them on one line,
    space separated, with quotes only around paths containing spaces.
    A line that is itself an existing path is kept whole.
    """
    line = line.strip()
    if Path(line.strip('"').strip("'")).expanduser().exists():
        return [line]
    import re
    return [a or b for a, b in re.findall(r'"([^"]+)"|(\S+)', line)]


def prompt_targets() -> list[Path]:
    """
    Interactive mode: ask the user to enter paths one by one.
    Several paths dropped on one line are split apart.
    An empty line (or 'done') finishes input.
    """
    print("Enter or drop file/folder paths to archive (several per line is fine).")
    print("Press Enter on an empty line when done.\n")

    raw_paths: list[str] = []
    while True:
        try:
            line = input(f"  Path {len(raw_paths) + 1}: ").strip()
        except EOFError:
            break
        if line.lower() in ("", "done", "q", "quit"):
            break
        raw_paths.extend(split_dropped(line))

    if not raw_paths:
        print("[!] No paths provided. Exiting.")
        sys.exit(0)

    return collect_targets(raw_paths)


# ──────────────────────────────────────────────
# 3b. PASSWORD PROMPT
# ──────────────────────────────────────────────

def prompt_password(action: str, *, confirm: bool = False) -> str:
    """
    Ask the user for a password, hiding input where possible.
    Press Enter on an empty line to accept DEFAULT_PASSWORD.

    `action` is just a label used in the prompt (e.g. "encrypt", "extract").
    `confirm` re-prompts and verifies the entry matches (used for zipping).
    """
    # Use getpass so the password isn't echoed to the terminal. If stdin
    # isn't a real TTY (e.g. piped input), getpass falls back to plain input.
    import getpass

    prompt = (
        f"  Password for {action} "
        f"(press Enter for default '{DEFAULT_PASSWORD}'): "
    )

    try:
        pw = getpass.getpass(prompt)
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(0)

    if not pw:
        print(f"  [-] Using default password.")
        return DEFAULT_PASSWORD

    if confirm:
        try:
            pw2 = getpass.getpass("  Confirm password: ")
        except (EOFError, KeyboardInterrupt):
            print()
            sys.exit(0)
        if pw != pw2:
            print("  [!] Passwords do not match. Try again.\n")
            return prompt_password(action, confirm=True)

    return pw


# ──────────────────────────────────────────────
# 4.  COMPRESS
# ──────────────────────────────────────────────

def new_output_path() -> Path:
    """YYYYMMDD-HHMMSS next to the script, no extension."""
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path(__file__).resolve().parent / timestamp


def zip_cmd(seven_z: str, password: str, output_path: Path,
            targets: list[Path]) -> list[str]:
    return [
        seven_z,
        "a",               # add / create archive
        "-t7z",            # 7z format
        f"-p{password}",   # password
        "-mhe=on",         # encrypt file headers too
        "-mx=5",           # compression level 0-9
        str(output_path),  # destination (no .7z suffix -- intentional)
        *[str(t) for t in targets],   # ← all sources
    ]


def strip_7z_ext(output_path: Path) -> bool:
    """Some 7z builds silently append .7z -- strip it back off."""
    with_ext = Path(str(output_path) + ".7z")
    if with_ext.exists() and not output_path.exists():
        with_ext.rename(output_path)
        return True
    return False


def make_archive(targets: list[Path], seven_z: str,
                 password: str = DEFAULT_PASSWORD) -> Path:
    output_path = new_output_path()

    # Print a summary of what will be archived
    print(f"[*] Items to archive : {len(targets)}")
    for t in targets:
        kind = "Folder" if t.is_dir() else "File"
        print(f"    {kind:<8} : {t}")
    print(f"[*] Output           : {output_path}")
    print(f"[*] Password         : {'*' * len(password)} ({len(password)} chars)")
    print()

    cmd = zip_cmd(seven_z, password, output_path, targets)
    result = subprocess.run(cmd, capture_output=False, text=True)

    if result.returncode != 0:
        raise RuntimeError(f"7z exited with code {result.returncode}")

    if strip_7z_ext(output_path):
        print(f"[*] Removed auto-added extension -> '{output_path.name}'")

    return output_path


# ──────────────────────────────────────────────
# 5.  EXTRACT
# ──────────────────────────────────────────────

def resolve_archive(raw: str) -> Path:
    """
    Resolve the input archive path. Accepts the bare name (no extension),
    a name with .7z, or any path. Exits if it can't be found.
    """
    p = Path(raw.strip().strip('"').strip("'")).expanduser().resolve()

    candidates = [p, Path(str(p) + ".7z")]
    for c in candidates:
        if c.is_file():
            return c

    print(f"[!] Archive not found: {p}")
    sys.exit(1)


def prompt_extract_inputs() -> tuple[Path, Path]:
    """
    Interactive mode for extraction.
    Returns (archive_path, output_dir).
    """
    print("Enter the path to the archive to extract.")
    try:
        raw = input("  Archive: ").strip()
    except EOFError:
        raw = ""
    if not raw:
        print("[!] No archive provided. Exiting.")
        sys.exit(0)

    archive = resolve_archive(raw)

    print("\nEnter the output folder (press Enter to use a folder next to the archive).")
    try:
        raw_out = input("  Output : ").strip()
    except EOFError:
        raw_out = ""

    if raw_out:
        out_dir = Path(raw_out.strip('"').strip("'")).expanduser().resolve()
    else:
        out_dir = archive.parent / f"{archive.stem}-extracted"

    return archive, out_dir


def unzip_cmd(seven_z: str, password: str, archive: Path,
              out_dir: Path) -> list[str]:
    return [
        seven_z,
        "x",                  # extract WITH full paths
        f"-p{password}",
        "-y",                 # assume Yes on prompts (overwrite, etc.)
        f"-o{out_dir}",       # output dir (no space after -o)
        str(archive),
    ]


def extract_archive(archive: Path, out_dir: Path, seven_z: str,
                    password: str = DEFAULT_PASSWORD) -> Path:
    """
    Extract `archive` into `out_dir`. If the password fails,
    prompt the user for the correct one (up to 3 attempts).
    """
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[*] Archive          : {archive}")
    print(f"[*] Output folder    : {out_dir}")
    print(f"[*] Password         : {'*' * len(password)} ({len(password)} chars)")
    print()

    def _run(pw: str) -> int:
        cmd = unzip_cmd(seven_z, pw, archive, out_dir)
        return subprocess.run(cmd, capture_output=False, text=True).returncode

    rc = _run(password)

    # 7-Zip returns non-zero for fatal errors (wrong password is one of them).
    # Allow up to 3 retry attempts.
    import getpass
    attempts = 0
    while rc != 0 and attempts < 3:
        attempts += 1
        print(f"\n[!] Extraction failed (exit code {rc}). "
              "The password may be wrong.")
        try:
            new_pw = getpass.getpass(
                f"  Enter password (attempt {attempts}/3, blank to abort): "
            ).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            new_pw = ""
        if not new_pw:
            raise RuntimeError("Extraction aborted.")
        rc = _run(new_pw)

    if rc != 0:
        raise RuntimeError(f"7z exited with code {rc}")

    return out_dir


# ──────────────────────────────────────────────
# 6b. GUI  (tkinter, stdlib only)
# ──────────────────────────────────────────────

def _enable_windows_drop(widget, on_drop) -> bool:
    """
    Accept files dragged from Explorer onto `widget` (Windows only).
    Hooks WM_DROPFILES with ctypes so no third-party package is needed.
    Dropped paths are queued and handed to `on_drop` from the Tk loop.
    """
    if platform.system() != "Windows":
        return False
    import ctypes
    from ctypes import wintypes

    user32, shell32 = ctypes.windll.user32, ctypes.windll.shell32
    WM_DROPFILES, GWLP_WNDPROC = 0x0233, -4
    LRESULT = ctypes.c_ssize_t
    WNDPROC = ctypes.WINFUNCTYPE(LRESULT, wintypes.HWND, wintypes.UINT,
                                 wintypes.WPARAM, wintypes.LPARAM)

    shell32.DragQueryFileW.argtypes = [wintypes.HANDLE, wintypes.UINT,
                                       wintypes.LPWSTR, wintypes.UINT]
    shell32.DragQueryFileW.restype = wintypes.UINT
    shell32.DragFinish.argtypes = [wintypes.HANDLE]
    shell32.DragAcceptFiles.argtypes = [wintypes.HWND, wintypes.BOOL]
    user32.CallWindowProcW.argtypes = [ctypes.c_void_p, wintypes.HWND,
                                       wintypes.UINT, wintypes.WPARAM,
                                       wintypes.LPARAM]
    user32.CallWindowProcW.restype = LRESULT
    set_proc = getattr(user32, "SetWindowLongPtrW", user32.SetWindowLongW)
    set_proc.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_void_p]
    set_proc.restype = ctypes.c_void_p

    hwnd = widget.winfo_id()
    pending: list[str] = []

    def proc(h, msg, wp, lp):
        if msg == WM_DROPFILES:
            count = shell32.DragQueryFileW(wp, 0xFFFFFFFF, None, 0)
            for i in range(count):
                size = shell32.DragQueryFileW(wp, i, None, 0) + 1
                buf = ctypes.create_unicode_buffer(size)
                shell32.DragQueryFileW(wp, i, buf, size)
                pending.append(buf.value)
            shell32.DragFinish(wp)
            return 0
        return user32.CallWindowProcW(old_proc, h, msg, wp, lp)

    # Calling into Tcl from inside the window procedure can crash,
    # so drops are collected here and picked up by a Tk timer.
    def poll():
        if pending:
            files = pending[:]
            pending.clear()
            on_drop(files)
        widget.after(150, poll)

    new_proc = WNDPROC(proc)
    widget._drop_proc = new_proc            # keep the callback alive
    old_proc = set_proc(hwnd, GWLP_WNDPROC, ctypes.cast(new_proc, ctypes.c_void_p))
    shell32.DragAcceptFiles(hwnd, True)

    # Let a non-elevated Explorer drop onto an elevated window.
    try:
        for m in (WM_DROPFILES, 0x004A, 0x0049):
            user32.ChangeWindowMessageFilterEx(hwnd, m, 1, None)
    except (AttributeError, OSError):
        pass

    poll()
    return True


def _work_area(root) -> tuple[int, int, int, int]:
    """(left, top, right, bottom) of the screen minus the taskbar."""
    if platform.system() == "Windows":
        import ctypes
        from ctypes import wintypes
        rect = wintypes.RECT()
        if ctypes.windll.user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(rect), 0):
            return rect.left, rect.top, rect.right, rect.bottom
    return 0, 0, root.winfo_screenwidth(), root.winfo_screenheight()


def _open_folder(path: Path) -> None:
    system = platform.system()
    if system == "Windows":
        if path.is_file():
            subprocess.Popen(["explorer", "/select,", str(path)])
        else:
            os.startfile(str(path))
    elif system == "Darwin":
        subprocess.Popen(["open", "-R", str(path)] if path.is_file() else ["open", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path if path.is_dir() else path.parent)])


def run_gui(seven_z: str) -> None:
    import threading
    import tkinter as tk
    from tkinter import filedialog, ttk

    if platform.system() == "Windows":
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError, OSError):
            pass

    root = tk.Tk()
    root.title("Zipper")
    root.attributes("-topmost", True)
    root.minsize(300, 420)

    # Dock to the right edge, full work-area height.
    left, top, right, bottom = _work_area(root)
    width = max(340, int((right - left) * 0.22))
    root.geometry(f"{width}x{bottom - top - 40}+{right - width - 8}+{top}")

    mode = tk.StringVar(value="zip")
    on_top = tk.BooleanVar(value=True)
    status = tk.StringVar(value="Drop files or folders here")
    items: list[Path] = []
    last_output: list[Path] = []

    pad = {"padx": 8, "pady": 4}

    # Mode
    top_bar = ttk.Frame(root)
    top_bar.pack(fill="x", **pad)
    ttk.Radiobutton(top_bar, text="Zip", value="zip", variable=mode,
                    command=lambda: refresh()).pack(side="left")
    ttk.Radiobutton(top_bar, text="Unzip", value="unzip", variable=mode,
                    command=lambda: refresh()).pack(side="left", padx=8)
    ttk.Checkbutton(top_bar, text="On top", variable=on_top,
                    command=lambda: root.attributes("-topmost", on_top.get())
                    ).pack(side="right")

    # Drop zone / list
    ttk.Label(root, textvariable=status, foreground="#555").pack(anchor="w", **pad)
    list_frame = ttk.Frame(root)
    list_frame.pack(fill="both", expand=True, **pad)
    lb = tk.Listbox(list_frame, selectmode="extended", activestyle="none",
                    relief="groove", borderwidth=2)
    sb = ttk.Scrollbar(list_frame, orient="vertical", command=lb.yview)
    lb.configure(yscrollcommand=sb.set)
    lb.pack(side="left", fill="both", expand=True)
    sb.pack(side="right", fill="y")

    def refresh():
        lb.delete(0, "end")
        for p in items:
            lb.insert("end", ("📁 " if p.is_dir() else "📄 ") + p.name)
        noun = "archive(s) to extract" if mode.get() == "unzip" else "item(s) to zip"
        status.set(f"{len(items)} {noun}" if items else
                   "Drop files or folders here")
        go.configure(text="Extract" if mode.get() == "unzip" else "Zip")

    def add(paths):
        for raw in paths:
            p = Path(raw).expanduser().resolve()
            if p.exists() and p not in items:
                items.append(p)
        refresh()

    def remove_selected(_=None):
        for i in reversed(lb.curselection()):
            del items[i]
        refresh()

    lb.bind("<Delete>", remove_selected)

    btns = ttk.Frame(root)
    btns.pack(fill="x", **pad)
    ttk.Button(btns, text="Add files…",
               command=lambda: add(filedialog.askopenfilenames(parent=root))
               ).pack(side="left")
    ttk.Button(btns, text="Add folder…",
               command=lambda: add([d] if (d := filedialog.askdirectory(parent=root)) else [])
               ).pack(side="left", padx=4)
    ttk.Button(btns, text="Remove", command=remove_selected).pack(side="left")
    ttk.Button(btns, text="Clear",
               command=lambda: (items.clear(), refresh())).pack(side="right")

    # Password
    pw_frame = ttk.Frame(root)
    pw_frame.pack(fill="x", **pad)
    ttk.Label(pw_frame, text="Password (blank = default):").pack(anchor="w")
    pw = ttk.Entry(pw_frame, show="•")
    pw.pack(fill="x")

    # Action + log
    act = ttk.Frame(root)
    act.pack(fill="x", **pad)
    go = ttk.Button(act, text="Zip")
    go.pack(side="left", fill="x", expand=True)
    open_btn = ttk.Button(act, text="Open output", state="disabled",
                          command=lambda: last_output and _open_folder(last_output[-1]))
    open_btn.pack(side="left", padx=(4, 0))

    log = tk.Text(root, height=8, wrap="word", state="disabled",
                  relief="flat", background=root.cget("background"))
    log.pack(fill="x", **pad)

    def say(msg: str):
        def _do():
            log.configure(state="normal")
            log.insert("end", msg + "\n")
            log.see("end")
            log.configure(state="disabled")
        root.after(0, _do)

    def run_7z(cmd: list[str]) -> int:
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        r = subprocess.run(cmd, capture_output=True, text=True,
                           errors="replace", creationflags=flags)
        if r.returncode != 0:
            err = (r.stderr or r.stdout).strip().splitlines()
            say("    " + (err[-1] if err else f"7z exit code {r.returncode}"))
        return r.returncode

    def work(job_mode: str, job_items: list[Path], password: str):
        done: list[Path] = []
        try:
            if job_mode == "zip":
                out = new_output_path()
                say(f"[*] Zipping {len(job_items)} item(s) …")
                if run_7z(zip_cmd(seven_z, password, out, job_items)) == 0:
                    strip_7z_ext(out)
                    say(f"[✓] {out}")
                    done.append(out)
                else:
                    say("[!] Compression failed")
            else:
                for arc in job_items:
                    out_dir = arc.parent / f"{arc.stem}-extracted"
                    say(f"[*] Extracting {arc.name} …")
                    out_dir.mkdir(parents=True, exist_ok=True)
                    if run_7z(unzip_cmd(seven_z, password, arc, out_dir)) == 0:
                        say(f"[✓] {out_dir}")
                        done.append(out_dir)
                    else:
                        say("[!] Failed — wrong password? Fix it and press Extract again.")
        finally:
            def _finish():
                go.configure(state="normal")
                if done:
                    last_output[:] = done
                    open_btn.configure(state="normal")
                    for p in job_items:
                        if job_mode == "zip" or p.parent / f"{p.stem}-extracted" in done:
                            if p in items:
                                items.remove(p)
                    refresh()
            root.after(0, _finish)

    def start():
        if not items:
            say("[!] Nothing to do — drop files first.")
            return
        job_items = list(items)
        if mode.get() == "unzip":
            bad = [p for p in job_items if not p.is_file()]
            if bad:
                say(f"[!] Not an archive: {bad[0].name}")
                return
        password = pw.get() or DEFAULT_PASSWORD
        go.configure(state="disabled")
        threading.Thread(target=work, args=(mode.get(), job_items, password),
                         daemon=True).start()

    go.configure(command=start)
    root.bind("<Return>", lambda _: start())

    if not _enable_windows_drop(lb, add):
        say("[-] Drag and drop needs Windows; use Add files / Add folder.")
    refresh()
    root.mainloop()


# ──────────────────────────────────────────────
# 6.  MODE SELECTION
# ──────────────────────────────────────────────

def prompt_mode() -> str:
    """Ask the user whether to zip or unzip."""
    print("What would you like to do?")
    print("  1) Zip   (compress files/folders into a password-protected archive)")
    print("  2) Unzip (extract a password-protected archive)")
    while True:
        try:
            choice = input("Choice [1/2]: ").strip().lower()
        except EOFError:
            choice = ""
        if choice in ("1", "z", "zip"):
            return "zip"
        if choice in ("2", "u", "unzip", "x", "extract"):
            return "unzip"
        print("  [!] Please enter 1 or 2.")


# ──────────────────────────────────────────────
# 7.  ENTRY POINT
# ──────────────────────────────────────────────

def main():
    args = sys.argv[1:]
    mode: str | None = None
    cli_password: str | None = None

    # --- Extract --password / -p from anywhere in args ---
    cleaned: list[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--password", "-p"):
            if i + 1 >= len(args):
                print("[!] --password requires a value.")
                sys.exit(1)
            cli_password = args[i + 1]
            i += 2
            continue
        if a.startswith("--password="):
            cli_password = a.split("=", 1)[1]
            i += 1
            continue
        cleaned.append(a)
        i += 1
    args = cleaned

    use_cli = False
    if "--cli" in args:
        use_cli = True
        args = [a for a in args if a != "--cli"]

    # --- Parse mode flag if present ---
    if args and args[0] in ("--zip", "-z"):
        mode = "zip"
        args = args[1:]
    elif args and args[0] in ("--unzip", "-u", "--extract", "-x"):
        mode = "unzip"
        args = args[1:]
    elif args and args[0] in ("--help", "-h"):
        print(__doc__)
        sys.exit(0)

    # --- If no mode flag and args were given, default to zip (legacy behaviour) ---
    if mode is None and args:
        mode = "zip"

    # --- No args: open the GUI unless --cli or tkinter is missing ---
    if mode is None and not use_cli:
        try:
            import tkinter  # noqa: F401
        except ImportError:
            use_cli = True
        else:
            try:
                seven_z = ensure_7z()
            except RuntimeError as e:
                print(f"\n[!] Could not obtain 7-Zip: {e}")
                sys.exit(1)
            run_gui(seven_z)
            return

    # --- If still no mode, ask interactively ---
    if mode is None:
        mode = prompt_mode()
        print()

    # --- Ensure 7-Zip is available ---
    try:
        seven_z = ensure_7z()
    except RuntimeError as e:
        print(f"\n[!] Could not obtain 7-Zip: {e}")
        sys.exit(1)

    # --- Dispatch ---
    if mode == "zip":
        if args:
            targets = collect_targets(args)
        else:
            targets = prompt_targets()

        password = cli_password if cli_password is not None else \
            prompt_password("encrypt", confirm=True)

        try:
            out = make_archive(targets, seven_z, password=password)
            print(f"\n[✓] Done -> {out}")
        except RuntimeError as e:
            print(f"\n[!] Compression failed: {e}")
            sys.exit(1)

    elif mode == "unzip":
        if args:
            archive = resolve_archive(args[0])
            if len(args) >= 2:
                out_dir = Path(args[1]).expanduser().resolve()
            else:
                out_dir = archive.parent / f"{archive.stem}-extracted"
        else:
            archive, out_dir = prompt_extract_inputs()

        password = cli_password if cli_password is not None else \
            prompt_password("extract")

        try:
            out = extract_archive(archive, out_dir, seven_z, password=password)
            print(f"\n[✓] Done -> {out}")
        except RuntimeError as e:
            print(f"\n[!] Extraction failed: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()
