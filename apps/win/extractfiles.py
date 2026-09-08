# Purpose: offline text extractor. Reads the extraction shortlist, pulls text and tables out of each file on the share into one SQLite database with full-text search. No AI, no internet.
# Run with the Python that passed checkenv.py, from the folder holding extraction_shortlist.xlsx.
#
#   python extractfiles.py                                # everything pending in .\extraction_shortlist.xlsx -> .\kb.db, resumable
#   python extractfiles.py --limit 30                     # test run: first 30 pending files
#   python extractfiles.py --workers 4                    # parallel workers, each with its own Word instance (default 3)
#   python extractfiles.py --only RCM,"Audit programme"   # only these DocType values
#   python extractfiles.py --minconf 2                    # skip confidence-1 rows (drafts, weak keyword types)
#   python extractfiles.py --retry-errors                 # re-attempt rows that errored last time
#   python extractfiles.py --stats                        # progress by type and status, then exit
#   python extractfiles.py --search "revenue cut-off"     # try the full-text index
#
# Ctrl+C at any time: everything finished so far is committed. Re-run the same command to continue.
# Output: kb.db  tables docs (one row per file, status), parts (text pieces: body/table/sheet/slide/page/email), parts_fts (FTS5).
# Old .doc/.rtf/.ppt are converted through Word/PowerPoint in a helper process with a timeout, so a hung file cannot stall the run.
# The helper switches off Word's Trust Center "File Block" for legacy formats (HKCU only, this user) so Word 95/97 files convert.

import sys, os, io, re, json, time, shutil, sqlite3, argparse, subprocess, threading, queue, datetime, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
IS_WIN = os.name == 'nt'
OFFICE_TIMEOUT = 120          # seconds per Word/PowerPoint conversion (file is already local, so longer means a broken file)
MAX_PART = 2_000_000          # chars per text piece
MAX_ROWS = 20_000             # rows per sheet
MAX_CELL = 4_000              # chars per cell
TEXT_EXT = {'.docx', '.doc', '.rtf', '.xlsx', '.xlsm', '.xls', '.pptx', '.ppt', '.pdf', '.msg', '.txt'}

# ---------------------------------------------------------------- helper process: Word / PowerPoint conversions
def unblock_legacy_word():
    # Trust Center > File Block Settings: 0 = do not block. Only HKCU, so no admin needed; a domain policy may still override.
    try:
        import winreg
        for ver in ('16.0', '15.0', '14.0'):
            try:
                k = winreg.CreateKey(winreg.HKEY_CURRENT_USER, rf'Software\Microsoft\Office\{ver}\Word\Security\FileBlock')
                for v in ('Word2Files', 'Word60Files', 'Word95Files', 'Word2003Files', 'Word2007Files', 'RtfFiles', 'OpenInProtectedView'):
                    winreg.SetValueEx(k, v, 0, winreg.REG_DWORD, 0)
                winreg.CloseKey(k)
            except OSError: pass
    except Exception: pass

def office_worker():
    import win32com.client, pythoncom
    pythoncom.CoInitialize()
    unblock_legacy_word()
    word = ppt = None; pid = None
    def pid_of(hwnd):
        import ctypes
        out = ctypes.c_ulong(); ctypes.windll.user32.GetWindowThreadProcessId(int(hwnd), ctypes.byref(out)); return out.value
    for line in sys.stdin:
        req = json.loads(line)
        try:
            if req['app'] == 'word':
                if word is None:
                    word = win32com.client.DispatchEx('Word.Application')
                    word.Visible = False; word.DisplayAlerts = 0; word.AutomationSecurity = 3
                d = word.Documents.Open(req['src'], ReadOnly=True, AddToRecentFiles=False, ConfirmConversions=False,
                                        PasswordDocument='__no_password__', Visible=False)
                if pid is None:
                    try: pid = pid_of(d.ActiveWindow.Hwnd)
                    except Exception: pass
                d.SaveAs2(req['dst'], FileFormat=12)      # wdFormatXMLDocument
                d.Close(0)
            else:
                if ppt is None:
                    ppt = win32com.client.DispatchEx('PowerPoint.Application')
                p = ppt.Presentations.Open(req['src'], ReadOnly=True, Untitled=False, WithWindow=False)
                p.SaveAs(req['dst'], 24)                  # ppSaveAsOpenXMLPresentation
                p.Close()
            print(json.dumps({'ok': True, 'pid': pid}), flush=True)
        except Exception as e:
            print(json.dumps({'ok': False, 'error': str(e)[:300], 'pid': pid}), flush=True)
    for app in (word, ppt):
        try: app.Quit()
        except Exception: pass

class Office:
    """Talks to the helper process; restarts it and kills the Office app if a conversion exceeds OFFICE_TIMEOUT."""
    def __init__(self): self.p = None; self.q = None; self.pid = None
    def _start(self):
        self.p = subprocess.Popen([sys.executable, os.path.abspath(__file__), '--office-worker'], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.q = queue.Queue()
        def pump():
            for line in self.p.stdout: self.q.put(line)
            self.q.put(None)
        threading.Thread(target=pump, daemon=True).start()
    def _kill(self):
        try: self.p.kill()
        except Exception: pass
        if self.pid:      # kill only this helper's Word, other workers keep theirs
            subprocess.run(['taskkill', '/F', '/PID', str(self.pid)], capture_output=True)
        else:
            for exe in ('WINWORD.EXE', 'POWERPNT.EXE'): subprocess.run(['taskkill', '/F', '/IM', exe], capture_output=True)
        self.p = None; self.pid = None
    def convert(self, app, src, dst):
        if self.p is None or self.p.poll() is not None: self._start()
        try:
            self.p.stdin.write(json.dumps({'app': app, 'src': src, 'dst': dst}) + '\n'); self.p.stdin.flush()
            line = self.q.get(timeout=OFFICE_TIMEOUT)
        except queue.Empty:
            self._kill(); raise RuntimeError(f'{app} conversion exceeded {OFFICE_TIMEOUT}s, Office killed and restarted')
        except Exception as e:
            self._kill(); raise RuntimeError(f'{app} helper failed: {e}')
        if line is None: self._kill(); raise RuntimeError(f'{app} helper died')
        r = json.loads(line)
        if r.get('pid'): self.pid = r['pid']
        if not r['ok']: raise RuntimeError(r['error'])
    def close(self):
        if self.p:
            try: self.p.stdin.close(); self.p.wait(10)
            except Exception: self._kill()

# ---------------------------------------------------------------- text handlers: each returns [(kind, title, content)]
def clean(s):
    if s is None: return ''
    s = str(s).replace('\x00', '').replace('\r\n', '\n').replace('\r', '\n')
    return re.sub(r'[ \t\xa0]+', ' ', s).strip()

def cellstr(v):
    if v is None: return ''
    if isinstance(v, float) and v.is_integer(): v = int(v)
    if isinstance(v, (datetime.datetime, datetime.date)): return v.isoformat()[:10]
    s = clean(v)
    return s[:MAX_CELL]

def rows_to_text(rows):
    out = []; n = 0
    for r in rows:
        cells = [cellstr(c) for c in r]
        while cells and cells[-1] == '': cells.pop()
        if not any(cells): continue
        out.append(' | '.join(cells)); n += 1
        if n >= MAX_ROWS: out.append(f'[truncated at {MAX_ROWS} rows]'); break
    return '\n'.join(out)

def h_docx(path):
    import docx
    d = docx.Document(path)
    parts = []
    body = '\n'.join(clean(p.text) for p in d.paragraphs if clean(p.text))
    if body: parts.append(('body', '', body))
    for i, t in enumerate(d.tables, 1):
        txt = rows_to_text([[c.text for c in row.cells] for row in t.rows])
        if txt: parts.append(('table', f'table {i}', txt))
    return parts

def h_xlsx(path):
    import openpyxl
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    parts = []
    for ws in wb.worksheets:
        txt = rows_to_text(ws.iter_rows(values_only=True))
        if txt: parts.append(('sheet', ws.title, txt))
    wb.close()
    return parts

def h_xls(path):
    import xlrd
    wb = xlrd.open_workbook(path, on_demand=True, formatting_info=False)
    parts = []
    for name in wb.sheet_names():
        ws = wb.sheet_by_name(name)
        rows = ([xlrd.xldate_as_datetime(c.value, wb.datemode) if c.ctype == xlrd.XL_CELL_DATE and c.value else c.value
                 for c in ws.row(r)] for r in range(ws.nrows))
        txt = rows_to_text(rows)
        if txt: parts.append(('sheet', name, txt))
        wb.unload_sheet(name)
    return parts

def h_pptx(path):
    from pptx import Presentation
    prs = Presentation(path)
    parts = []
    for i, s in enumerate(prs.slides, 1):
        lines = []
        for sh in s.shapes:
            if sh.has_text_frame:
                t = clean(sh.text_frame.text)
                if t: lines.append(t)
            if getattr(sh, 'has_table', False) and sh.has_table:
                lines.append(rows_to_text([[c.text for c in row.cells] for row in sh.table.rows]))
        if s.has_notes_slide:
            t = clean(s.notes_slide.notes_text_frame.text)
            if t: lines.append('[notes] ' + t)
        txt = '\n'.join(l for l in lines if l)
        if txt: parts.append(('slide', f'slide {i}', txt))
    return parts

def h_pdf(path):
    from pypdf import PdfReader
    r = PdfReader(path, strict=False)
    if r.is_encrypted:
        try: r.decrypt('')
        except Exception: raise RuntimeError('pdf is password protected')
    parts = []
    for i, pg in enumerate(r.pages, 1):
        try: t = clean(pg.extract_text() or '')
        except Exception as e: t = f'[page {i}: extract failed {e}]'
        if t: parts.append(('page', f'page {i}', t))
    if not parts and len(r.pages): raise RuntimeError(f'no text layer in {len(r.pages)} pages (scanned image pdf, needs OCR)')
    return parts

def h_txt(path):
    with open(path, 'rb') as fh: b = fh.read()
    for enc in ('utf-8-sig', 'utf-16', 'cp1252'):
        try: t = b.decode(enc); break
        except Exception: t = b.decode('latin-1')
    t = clean(t)
    return [('body', '', t)] if t else []

def h_msg(path, tmpdir, office, depth=0):
    import extract_msg
    m = extract_msg.openMsg(path)
    parts = []
    head = '\n'.join(f'{k}: {clean(v)}' for k, v in (('Subject', m.subject), ('From', m.sender), ('To', m.to), ('Cc', m.cc), ('Date', m.date)) if v)
    parts.append(('email', 'header', head))
    body = clean(m.body or '')
    if body: parts.append(('email', 'body', body))
    for a in m.attachments:
        name = getattr(a, 'longFilename', None) or getattr(a, 'shortFilename', None) or ''
        ext = os.path.splitext(name)[1].lower()
        if depth or ext not in TEXT_EXT or ext == '.msg' or not isinstance(getattr(a, 'data', None), (bytes, bytearray)):
            if name: parts.append(('attachment', name, '[attachment not extracted]'))
            continue
        ap = os.path.join(tmpdir, 'att_' + re.sub(r'[^\w.]+', '_', name)[-80:])
        with open(ap, 'wb') as fh: fh.write(a.data)
        try:
            for kind, title, content in extract(ap, ext, tmpdir, office):
                parts.append(('attachment', f'{name} / {title}' if title else name, content))
        except Exception as e:
            parts.append(('attachment', name, f'[attachment failed: {e}]'))
        finally:
            try: os.remove(ap)
            except Exception: pass
    m.close()
    return parts

def extract(local, ext, tmpdir, office):
    if ext == '.docx': return h_docx(local)
    if ext in ('.doc', '.rtf'):
        dst = local + '.docx'; office.convert('word', local, dst)
        try: return h_docx(dst)
        finally: os.remove(dst)
    if ext in ('.xlsx', '.xlsm'): return h_xlsx(local)
    if ext == '.xls':
        try: return h_xls(local)
        except Exception as e:
            # some ".xls" are really xlsx, html or csv
            try: return h_xlsx(local)
            except Exception: pass
            dst = local + '.docx'
            try: office.convert('word', local, dst); return h_docx(dst)
            except Exception: raise e
            finally:
                if os.path.exists(dst): os.remove(dst)
    if ext == '.pptx': return h_pptx(local)
    if ext == '.ppt':
        dst = local + '.pptx'; office.convert('ppt', local, dst)
        try: return h_pptx(dst)
        finally: os.remove(dst)
    if ext == '.pdf': return h_pdf(local)
    if ext == '.msg': return h_msg(local, tmpdir, office)
    if ext == '.txt': return h_txt(local)
    raise RuntimeError(f'unsupported extension {ext}')

# ---------------------------------------------------------------- database
def open_db(dbpath):
    db = sqlite3.connect(dbpath)
    db.executescript('''
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS docs(id INTEGER PRIMARY KEY, path TEXT UNIQUE, name TEXT, ext TEXT, size INTEGER, modified TEXT,
        doctype TEXT, confidence INTEGER, client TEXT, engagement TEXT, year TEXT, yearsource TEXT, process TEXT, topfolder TEXT, duplicates INTEGER,
        status TEXT DEFAULT 'pending', parts INTEGER, chars INTEGER, error TEXT, seconds REAL, done_at TEXT);
    CREATE INDEX IF NOT EXISTS ix_docs_status ON docs(status);
    CREATE TABLE IF NOT EXISTS parts(id INTEGER PRIMARY KEY, doc_id INTEGER, seq INTEGER, kind TEXT, title TEXT, content TEXT);
    CREATE INDEX IF NOT EXISTS ix_parts_doc ON parts(doc_id);
    CREATE VIRTUAL TABLE IF NOT EXISTS parts_fts USING fts5(title, content, content='parts', content_rowid='id', tokenize='porter unicode61');
    ''')
    return db

def load_list(db, xlsx):
    import openpyxl
    wb = openpyxl.load_workbook(xlsx, read_only=True)
    ws = wb['Shortlist'] if 'Shortlist' in wb.sheetnames else wb.worksheets[0]
    rows = ws.iter_rows(values_only=True); hdr = [str(h) for h in next(rows)]
    ix = {h: i for i, h in enumerate(hdr)}
    def g(r, k): v = r[ix[k]] if k in ix else None; return v
    n = 0
    for r in rows:
        if not r or not g(r, 'FullPath'): continue
        cur = db.execute('''INSERT OR IGNORE INTO docs(path,name,ext,size,modified,doctype,confidence,client,engagement,year,yearsource,process,topfolder,duplicates)
                            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                         (g(r, 'FullPath'), g(r, 'FileName'), (g(r, 'Ext') or '').lower(), g(r, 'SizeBytes'), str(g(r, 'Modified') or ''), g(r, 'DocType'),
                          g(r, 'Confidence'), g(r, 'Client'), g(r, 'Engagement'), str(g(r, 'Year') or ''), g(r, 'YearSource'), g(r, 'ProcessHint'), g(r, 'TopFolder'), g(r, 'Duplicates')))
        n += cur.rowcount
    db.commit(); wb.close()
    return n

def longpath(p):
    if not IS_WIN or p.startswith('\\\\?\\'): return p
    return '\\\\?\\UNC\\' + p[2:] if p.startswith('\\\\') else '\\\\?\\' + p

def stats(db):
    print('\nstatus by document type')
    print(f"{'DocType':20}{'pending':>9}{'done':>9}{'empty':>9}{'error':>9}{'chars M':>10}")
    for row in db.execute('''select doctype, sum(status='pending'), sum(status='done'), sum(status='empty'), sum(status='error'), sum(coalesce(chars,0))/1e6
                             from docs group by doctype order by doctype'''):
        print(f"{row[0]:20}{row[1]:>9,}{row[2]:>9,}{row[3]:>9,}{row[4]:>9,}{row[5]:>10.1f}")
    row = db.execute("select count(*), sum(status='done'), sum(status='error'), sum(status='empty') from docs").fetchone()
    print(f"total {row[0]:,}   done {row[1]:,}   error {row[2]:,}   empty {row[3]:,}")
    print('\ntop errors')
    for e, c in db.execute("select substr(error,1,90), count(*) from docs where status='error' group by 1 order by 2 desc limit 12"): print(f"  {c:>6,}  {e}")

def search(db, q):
    if '"' not in q: q = ' '.join('"' + t.replace('"', '') + '"' for t in q.split())   # plain words: AND of exact tokens, hyphens safe
    for name, doctype, client, title, snip in db.execute('''select d.name, d.doctype, d.client, p.title, snippet(parts_fts, 1, '[', ']', ' ... ', 18)
        from parts_fts join parts p on p.id = parts_fts.rowid join docs d on d.id = p.doc_id where parts_fts match ? order by rank limit 15''', (q,)):
        print(f"{doctype:16} {(client or '')[:22]:22} {name[:45]:45} {title[:14]:14} {snip}")

def hms(s): return str(datetime.timedelta(seconds=int(s))) if s >= 0 else '--:--:--'

# ---------------------------------------------------------------- worker process: copy + extract one file, return parts
W = {}
def w_init(tmpdir):
    W['tmp'] = tmpdir; W['office'] = Office()
    import signal, atexit; signal.signal(signal.SIGINT, signal.SIG_IGN)     # parent handles Ctrl+C
    atexit.register(W['office'].close)

def w_one(item):
    did, path, ext, name, doctype = item
    ts = time.time(); local = os.path.join(W['tmp'], f'{did}_{os.getpid()}{ext}')
    status, err, parts = 'done', None, []
    try:
        shutil.copyfile(longpath(path), local)
        parts = extract(local, ext, W['tmp'], W['office'])
        parts = [(k, t, c[:MAX_PART]) for k, t, c in parts if c]
        if not parts: status, err = 'empty', 'no text found'
    except Exception as e:
        status, err = 'error', (str(e) or e.__class__.__name__)[:400]
    finally:
        if os.path.exists(local):
            try: os.remove(local)
            except Exception: pass
    return did, name, status, err, parts, round(time.time() - ts, 2)

# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', default=os.path.join(HERE, 'extraction_shortlist.xlsx'))
    ap.add_argument('--db', default=os.path.join(HERE, 'kb.db'))
    ap.add_argument('--only', default='', help='comma separated DocType values')
    ap.add_argument('--minconf', type=int, default=1)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--workers', type=int, default=3)
    ap.add_argument('--retry-errors', action='store_true')
    ap.add_argument('--stats', action='store_true')
    ap.add_argument('--search', default='')
    ap.add_argument('--office-worker', action='store_true')
    a = ap.parse_args()
    if a.office_worker: return office_worker()

    db = open_db(a.db)
    if a.search: return search(db, a.search)
    if os.path.exists(a.list):
        n = load_list(db, a.list)
        if n: print(f'loaded {n:,} new rows from {os.path.basename(a.list)}')
    if a.stats: return stats(db)

    if a.retry_errors: db.execute("update docs set status='pending', error=NULL where status='error'"); db.commit()
    sql = "select id, path, ext, name, doctype from docs where status='pending' and confidence >= ?"; args = [a.minconf]
    if a.only:
        kinds = [k.strip() for k in a.only.split(',') if k.strip()]
        sql += f" and doctype in ({','.join('?' * len(kinds))})"; args += kinds
    sql += ' order by id'
    if a.limit: sql += f' limit {int(a.limit)}'
    todo = db.execute(sql, args).fetchall()
    total = db.execute('select count(*) from docs').fetchone()[0]
    done0 = db.execute("select count(*) from docs where status!='pending'").fetchone()[0]
    print(f'db: {a.db}\n{total:,} rows in list, {done0:,} already processed, {len(todo):,} to do now')
    if not todo: return stats(db)

    tmpdir = os.path.join(HERE, 'tmp_extract'); os.makedirs(tmpdir, exist_ok=True)
    import multiprocessing as mp
    pool = mp.Pool(max(1, a.workers), initializer=w_init, initargs=(tmpdir,))
    t0 = time.time(); last = 0; n = 0; nerr = 0; nempty = 0
    try:
        for did, name, status, err, parts, secs in pool.imap_unordered(w_one, todo, chunksize=1):
            n += 1
            if status == 'error': nerr += 1
            if status == 'empty': nempty += 1
            for pid, t, c in db.execute('select id, title, content from parts where doc_id=?', (did,)).fetchall():   # retry: drop old text
                db.execute("insert into parts_fts(parts_fts, rowid, title, content) values('delete', ?, ?, ?)", (pid, t, c))
            db.execute('delete from parts where doc_id=?', (did,))
            for i, (k, t, c) in enumerate(parts, 1):
                cur = db.execute('insert into parts(doc_id,seq,kind,title,content) values(?,?,?,?,?)', (did, i, k, t, c))
                db.execute('insert into parts_fts(rowid,title,content) values(?,?,?)', (cur.lastrowid, t, c))
            db.execute('update docs set status=?, parts=?, chars=?, error=?, seconds=?, done_at=? where id=?',
                       (status, len(parts), sum(len(c) for _, _, c in parts), err, secs, datetime.datetime.now().strftime('%Y-%m-%d %H:%M'), did))
            if n % 25 == 0: db.commit()
            if time.time() - last > 1:
                last = time.time(); el = last - t0; rate = n / el * 60
                print(f'\r{n:,}/{len(todo):,}  err {nerr:,}  empty {nempty:,}  {rate:5.1f} files/min  elapsed {hms(el)}  eta {hms((len(todo) - n) / max(rate, 0.01) * 60)}  {name[:50]:50}', end='', flush=True)
        pool.close(); pool.join()
    except KeyboardInterrupt:
        print('\nstopped. re-run the same command to continue.')
        pool.terminate()
        if IS_WIN:
            for exe in ('WINWORD.EXE', 'POWERPNT.EXE'): subprocess.run(['taskkill', '/F', '/IM', exe], capture_output=True)
    finally:
        db.commit()
    print(f'\nfinished {n:,} files in {hms(time.time() - t0)}')
    stats(db)

if __name__ == '__main__':
    main()
