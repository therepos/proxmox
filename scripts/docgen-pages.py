#!/usr/bin/env python3
# Purpose: Build the GitHub Pages script page from each script's lines 2-3
# =============================================================================
# Usage:
#   python3 scripts/docgen-pages.py [out_dir]   write index.html (default: _site)
# =============================================================================

import html
import os
import sys

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else '_site'
OUTPUT_HTML = os.path.join(OUT_DIR, 'index.html')

def extract_purpose(filepath):
    try:
        with open(filepath, 'r') as f:
            for _ in range(6):
                line = f.readline()
                if not line:
                    break
                if line.lower().startswith("# purpose:"):
                    text = line.split(":", 1)[1].strip()
                    text = text[0].upper() + text[1:] if text else ""
                    if not text.endswith("."):
                        text += "."
                    return text
    except Exception:
        pass
    return None

def extract_bootstrap(filepath):
    with open(filepath, 'r') as f:
        f.readline()
        line = f.readline().strip()
    if line.startswith('# bash -c "$(wget'):
        return line[2:]
    return None

def nice_name(filename):
    action, subject = filename[:-len('.sh')].split('-', 1)
    name = subject if action == 'setup' else f'{subject} {action}'
    return name[0].upper() + name[1:]

def html_cards(folder, installers):
    cards = []
    for filename in sorted(os.listdir(folder)):
        if not filename.endswith('.sh') or filename.startswith('setup-') != installers:
            continue
        filepath = os.path.join(folder, filename)
        cmd = extract_bootstrap(filepath)
        if not cmd:
            continue  # installed by another script, nothing to copy
        purpose = extract_purpose(filepath) or ''
        cards.append(
            '<div class="card"><b>{}</b><p>{}</p>'
            '<button data-cmd="{}">Copy command</button></div>'.format(
                html.escape(nice_name(filename)), html.escape(purpose),
                html.escape(cmd, quote=True)))
    return '\n'.join(cards)

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Proxmox scripts</title>
<style>
:root{--bg:#f6f6f4;--card:#fff;--text:#1f1f1e;--muted:#6b6a66;--line:#e2e1dc;--ok:#2e7d32}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1b;--card:#262624;--text:#ecebe6;--muted:#a3a29c;--line:#3a3a37;--ok:#7bc47f}}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:960px;margin:0 auto;padding:2rem 1rem}
h1{font-size:22px;font-weight:600;margin:0 0 .25rem}
h2{font-size:16px;font-weight:600;margin:2rem 0 .75rem}
.hint{color:var(--muted);margin:0 0 1rem}
input{width:100%;box-sizing:border-box;padding:10px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text);font-size:15px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;display:flex;flex-direction:column;gap:8px}
.card b{font-size:16px;font-weight:600}
.card p{margin:0;color:var(--muted);font-size:13px;flex:1}
button{padding:9px;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--text);font-size:14px;cursor:pointer}
button:hover{background:var(--bg)}
button.done{color:var(--ok);border-color:var(--ok)}
</style>
</head>
<body>
<main>
<h1>Proxmox scripts</h1>
<p class="hint">Click Copy command, paste it into the Proxmox shell, and press Enter.</p>
<input id="q" type="search" placeholder="Search scripts" aria-label="Search scripts">
<h2>Installers</h2>
<div class="grid">
{installers}
</div>
<h2>Tools</h2>
<div class="grid">
{tools}
</div>
</main>
<script>
function copy(text){
  if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
  var t=document.createElement('textarea'); t.value=text; document.body.appendChild(t); t.select();
  document.execCommand('copy'); document.body.removeChild(t); return Promise.resolve();
}
document.querySelectorAll('button[data-cmd]').forEach(function(b){
  b.addEventListener('click',function(){
    copy(b.dataset.cmd).then(function(){
      b.textContent='Copied'; b.classList.add('done');
      setTimeout(function(){ b.textContent='Copy command'; b.classList.remove('done'); },1800);
    });
  });
});
document.getElementById('q').addEventListener('input',function(e){
  var q=e.target.value.toLowerCase();
  document.querySelectorAll('.card').forEach(function(c){
    c.style.display=c.textContent.toLowerCase().indexOf(q)>-1?'':'none';
  });
});
</script>
</body>
</html>
"""

def generate_html():
    page = (PAGE.replace('{installers}', html_cards('apps', True))
                .replace('{tools}', html_cards('apps', False)))
    with open(OUTPUT_HTML, 'w') as out:
        out.write(page)

if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    generate_html()


