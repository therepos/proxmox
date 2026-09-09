#!/usr/bin/env python3
"""Extract a zip or 7z archive that may lack an extension. Default password 123.
Usage: extract.py <archive> [--password PW] [--no-copy] [--out DIR]"""
import sys, os, shutil, subprocess, argparse, zipfile

def kind(path):
    with open(path, "rb") as f:
        sig = f.read(8)
    if sig.startswith(b"7z\xbc\xaf\x27\x1c"): return "7z"
    if sig.startswith(b"PK"): return "zip"
    return "unknown"

def ensure_py7zr():
    try:
        import py7zr  # noqa
        return True
    except ImportError:
        r = subprocess.run([sys.executable, "-m", "pip", "install", "-q", "py7zr", "--break-system-packages"],
                           capture_output=True, text=True)
        try:
            import py7zr  # noqa
            return True
        except ImportError:
            print("py7zr install failed:", r.stderr[-400:]); return False

def extract_7z(src, dst, pw):
    if shutil.which("7z") or shutil.which("7zz"):
        exe = shutil.which("7z") or shutil.which("7zz")
        r = subprocess.run([exe, "x", f"-p{pw or ''}", "-y", f"-o{dst}", src], capture_output=True, text=True)
        if r.returncode == 0: return True
    if not ensure_py7zr(): return False
    import py7zr
    try:
        with py7zr.SevenZipFile(src, mode="r", password=pw or None) as z:
            z.extractall(dst)
        return True
    except Exception as e:
        print("7z extract failed:", e); return False

def extract_zip(src, dst, pw):
    try:
        with zipfile.ZipFile(src) as z:
            z.extractall(dst, pwd=pw.encode() if pw else None)
        return True
    except (RuntimeError, NotImplementedError) as e:
        # AES zips need pyzipper
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", "pyzipper", "--break-system-packages"], capture_output=True)
        try:
            import pyzipper
            with pyzipper.AESZipFile(src) as z:
                z.extractall(dst, pwd=pw.encode() if pw else None)
            return True
        except Exception as e2:
            print("zip extract failed:", e, "|", e2); return False
    except Exception as e:
        print("zip extract failed:", e); return False

def extract(src, dst, pw):
    k = kind(src)
    print(f"detected: {k}")
    os.makedirs(dst, exist_ok=True)
    if k == "7z": ok = extract_7z(src, dst, pw)
    elif k == "zip": ok = extract_zip(src, dst, pw)
    else:
        print("unknown signature; trying 7z then zip"); ok = extract_7z(src, dst, pw) or extract_zip(src, dst, pw)
    if not ok and pw:
        print("retrying without password"); ok = extract(src, dst, "")
    return ok

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("archive"); ap.add_argument("--password", default="123")
    ap.add_argument("--no-copy", action="store_true"); ap.add_argument("--out", default=None)
    a = ap.parse_args()
    name = os.path.splitext(os.path.basename(a.archive))[0]
    base = os.environ.get("EXTRACT_DIR") or ("/home/claude/extracted" if os.path.isdir("/home/claude") else "/tmp/extracted")
    dst = a.out or os.path.join(base, name)
    if not extract(a.archive, dst, a.password):
        print("EXTRACTION FAILED"); sys.exit(1)
    # one level of nested archives
    for root, _, files in os.walk(dst):
        for f in files:
            fp = os.path.join(root, f)
            if kind(fp) in ("7z", "zip") and not f.lower().endswith((".xlsx", ".docx", ".pptx")):
                sub = os.path.join(root, os.path.splitext(f)[0] + "_extracted")
                print(f"nested archive: {fp}"); extract(fp, sub, a.password)
    listing = []
    for root, _, files in os.walk(dst):
        for f in sorted(files):
            fp = os.path.join(root, f); listing.append((os.path.relpath(fp, dst), os.path.getsize(fp)))
    print(f"\n{len(listing)} files extracted to {dst}:")
    for rel, sz in listing: print(f"  {sz/1e6:6.2f} MB  {rel}")
    if not a.no_copy and os.path.isdir("/mnt/user-data/outputs"):
        out = f"/mnt/user-data/outputs/{name}"
        if os.path.exists(out): shutil.rmtree(out)
        shutil.copytree(dst, out); print(f"\ncopied to {out}")
        print("PRESENT:", " ".join(os.path.join(out, rel) for rel, _ in listing))
    else:
        print("PRESENT:", " ".join(os.path.join(dst, rel) for rel, _ in listing))

if __name__ == "__main__":
    main()
