import importlib, subprocess, sys

def ensure(pkg, import_name=None):
    try:
        return importlib.import_module(import_name or pkg)
    except ImportError:
        print(f"installing {pkg}...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", pkg])
        return importlib.import_module(import_name or pkg)

olefile = ensure("olefile")

import zipfile, os, io, struct

SRC = "WSG_PFAB_RFI_HRD.xlsx"      # your file
OUT = "extracted"
os.makedirs(OUT, exist_ok=True)

# --- type sniffers -------------------------------------------------
def zip_kind(b):
    try:
        names = zipfile.ZipFile(io.BytesIO(b)).namelist()
        if any(n.startswith("xl/")   for n in names): return "xlsx"
        if any(n.startswith("word/") for n in names): return "docx"
        if any(n.startswith("ppt/")  for n in names): return "pptx"
    except Exception: pass
    return "zip"

def ole_kind(b):
    try:
        o = olefile.OleFileIO(io.BytesIO(b))
        s = {"/".join(x).lower() for x in o.listdir()}
        o.close()
        if "workbook" in s or "book" in s:          return "xls"
        if "worddocument" in s:                      return "doc"
        if "powerpoint document" in s:               return "ppt"
        if "__properties_version1.0" in s or any(x.startswith("__substg1.0_") for x in s):
            return "msg"                             # Outlook email
    except Exception: pass
    return "ole"

def sniff(b):
    if b[:4] == b"%PDF":          return "pdf"
    if b[:4] == b"PK\x03\x04":    return zip_kind(b)
    if b[:4] == b"\xd0\xcf\x11\xe0": return ole_kind(b)
    return "bin"

# --- trim trailing junk left by some wrappers ----------------------
def trim(b, kind):
    if kind == "pdf":
        i = b.rfind(b"%%EOF");  return b[:i+5] if i != -1 else b
    if kind in ("xlsx","docx","pptx","zip"):
        i = b.rfind(b"PK\x05\x06")
        if i != -1 and i+22 <= len(b):
            clen = struct.unpack_from("<H", b, i+20)[0]
            return b[:i+22+clen]
    return b

# --- Ole10Native (Packager) header: recover name + payload ---------
def from_packager(stream):
    try:
        p = 6                                   # 4-byte size + 2-byte flags
        p = stream.index(b"\x00", p) + 1        # skip label
        e = stream.index(b"\x00", p); orig = stream[p:e]; p = e + 1
        p += 4                                  # reserved
        tlen = struct.unpack_from("<I", stream, p)[0]; p += 4 + tlen   # temp path
        dsize = struct.unpack_from("<I", stream, p)[0]; p += 4
        payload = stream[p:p+dsize]
        if len(payload) == dsize and sniff(payload) != "bin":
            return os.path.basename(orig.decode("latin-1","replace").replace("\\","/")), payload
    except Exception: pass
    # fallback: carve from earliest known magic
    idx = min([i for i in (stream.find(b"%PDF"), stream.find(b"PK\x03\x04"),
                           stream.find(b"\xd0\xcf\x11\xe0")) if i != -1], default=-1)
    return None, (stream[idx:] if idx != -1 else stream)

# --- main ----------------------------------------------------------
def save(name, data):
    path = os.path.join(OUT, name); n = 1
    while os.path.exists(path):
        stem, ext = os.path.splitext(name)
        path = os.path.join(OUT, f"{stem}_{n}{ext}"); n += 1
    open(path, "wb").write(data); print("  ->", os.path.basename(path), f"({len(data)} bytes)")

with zipfile.ZipFile(SRC) as z:
    embeds = [n for n in z.namelist() if "embeddings/" in n and not n.endswith("/")]

for i, n in enumerate(embeds, 1):
    raw = zipfile.ZipFile(SRC).read(n)
    base = os.path.basename(n)
    print(base)

    if not base.endswith(".bin"):        # already a real file (e.g. embedded .xlsx)
        save(base, raw); continue

    ole = olefile.OleFileIO(io.BytesIO(raw))
    streams = {"/".join(s) for s in ole.listdir()}
    low = {s.lower() for s in streams}

    # 1) native compound doc: the .bin IS the document -> rename whole thing
    native = ("xls" if ("workbook" in low or "book" in low) else
              "doc" if "worddocument" in low else
              "ppt" if "powerpoint document" in low else
              "msg" if "__properties_version1.0" in low or any(s.startswith("__substg1.0_") for s in streams) else None)
    if native:
        ole.close(); save(f"embedded_{i}.{native}", raw); continue

    # 2) wrapped payload streams
    stream_name = next((s for s in ("CONTENTS","Package","\x01Ole10Native","Ole10Native") if s in streams), None)
    if not stream_name:
        ole.close(); save(f"embedded_{i}.bin", raw); continue   # unknown, keep raw
    payload = ole.openstream(stream_name).read(); ole.close()

    name = None
    if "Ole10Native" in stream_name:
        name, payload = from_packager(payload)

    kind = sniff(payload)
    payload = trim(payload, kind)
    save(name or f"embedded_{i}.{kind}", payload)

print("done ->", OUT)