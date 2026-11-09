#!/usr/bin/env python3
# Purpose: Build the GitHub Pages script page from each script's lines 2-3
# =============================================================================
# Usage:
#   python3 scripts/docgen-pages.py [out_dir]   write index.html (default: _site)
#   python3 scripts/docgen-pages.py --check     list scripts with no display name in NAMES
# =============================================================================

import html
import os
import sys

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else '_site'
OUTPUT_HTML = os.path.join(OUT_DIR, 'index.html')
REPO_URL = 'https://github.com/therepos/proxmox'

# Display name per subject or action: Title Case words, acronyms and product names as spelled
# (lint fails on a missing entry); a tool reads '<Subject> <Action>', e.g. create-vm -> VM Create
NAMES = {
    'backup': 'Backup',
    'claudeubuntu': 'Claude Ubuntu',
    'cloudflared': 'Cloudflared',
    'create': 'Create',
    'disk': 'Disk',
    'docker': 'Docker',
    'drivemount': 'Drive Mount',
    'filebrowser': 'File Browser',
    'gitlab': 'GitLab',
    'gpu': 'GPU',
    'hermes': 'Hermes',
    'hermessb': 'Hermes Sandbox',
    'kasm': 'Kasm',
    'llama': 'Llama',
    'llmfit': 'LLMfit',
    'lmsensors': 'LM Sensors',
    'portainer': 'Portainer',
    'pve': 'PVE',
    'pvenosub': 'PVE No-Sub',
    'report': 'Report',
    'smb': 'SMB',
    'tailscale': 'Tailscale',
    'virtiofs': 'VirtIO-FS',
    'vm': 'VM',
    'webmin': 'Webmin',
}

def word(w):
    return NAMES.get(w, w[0].upper() + w[1:])

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
    return word(subject) if action == 'setup' else f'{word(subject)} {word(action)}'

def html_rows(folder, installers):
    rows = []
    for filename in sorted(os.listdir(folder)):
        if not filename.endswith('.sh') or filename.startswith('setup-') != installers:
            continue
        filepath = os.path.join(folder, filename)
        cmd = extract_bootstrap(filepath)
        if not cmd:
            continue  # installed by another script, nothing to copy
        purpose = extract_purpose(filepath) or ''
        rows.append(
            '<div class="row"><b>{}</b><p>{}</p>'
            '<button data-cmd="{}">Copy command</button></div>'.format(
                html.escape(nice_name(filename)), html.escape(purpose),
                html.escape(cmd, quote=True)))
    return '\n'.join(rows)

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
:root{--bg:#f6f6f4;--card:#fff;--text:#1f1f1e;--muted:#6b6a66;--line:#e2e1dc;--ok:#2e7d32}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1b;--card:#262624;--text:#ecebe6;--muted:#a3a29c;--line:#3a3a37;--ok:#7bc47f}}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
main{max-width:960px;margin:0 auto;padding:2rem 1rem}
h1{font-size:22px;font-weight:600;margin:0 0 .25rem}
h2{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);margin:2rem 0 .5rem}
.hint{color:var(--muted);margin:0 0 1rem}
input{width:100%;box-sizing:border-box;padding:10px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text);font-size:15px}
.list{background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.row{display:grid;grid-template-columns:180px 1fr 170px;gap:4px 16px;align-items:center;padding:10px 14px;border-top:1px solid var(--line)}
.row:first-child{border-top:0}
.row b{font-weight:600}
.row p{margin:0;color:var(--muted);font-size:14px}
button{box-sizing:border-box;width:100%;padding:7px;text-align:center;text-decoration:none;display:block;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--text);font-size:14px;cursor:pointer}
button:hover{background:var(--bg)}
button.done{color:var(--ok);border-color:var(--ok)}
footer{margin-top:2.5rem;padding-top:1rem;border-top:1px solid var(--line);color:var(--muted);font-size:14px}
footer a{color:inherit}
@media (max-width:640px){.row{grid-template-columns:1fr 170px}.row p{grid-column:1/-1;grid-row:2}}
</style>
</head>
<body>
<main>
<h1>{title}</h1>
<p class="hint">{hint}</p>
<input id="q" type="search" placeholder="Search scripts" aria-label="Search scripts">
{sections}
<footer><a href="{repo}">{repo_label}</a></footer>
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
  document.querySelectorAll('section').forEach(function(s){
    var shown=0;
    s.querySelectorAll('.row').forEach(function(r){
      var hit=r.textContent.toLowerCase().indexOf(q)>-1;
      r.style.display=hit?'':'none'; if(hit) shown++;
    });
    s.style.display=shown?'':'none';
  });
});
</script>
</body>
</html>
"""

def section(title, rows):
    return '<section><h2>{}</h2><div class="list">\n{}\n</div></section>'.format(title, rows) if rows else ''

def generate_html():
    page = (PAGE.replace('{title}', 'Proxmox Scripts')
                .replace('{hint}', 'Click Copy command, paste it into the Proxmox shell, and press Enter.')
                .replace('{sections}', section('Installers', html_rows('apps', True)) + '\n'
                                       + section('Tools', html_rows('apps', False)))
                .replace('{repo_label}', REPO_URL.split('//', 1)[1])
                .replace('{repo}', REPO_URL))
    with open(OUTPUT_HTML, 'w') as out:
        out.write(page)

def check():
    missing = []
    for filename in sorted(os.listdir('apps')):
        if filename.endswith('.sh'):
            missing += ['apps/{}: no display name for \'{}\' in NAMES (scripts/docgen-pages.py)'.format(filename, w)
                        for w in filename[:-len('.sh')].split('-', 1) if w != 'setup' and w not in NAMES]
    for m in missing:
        print(m)
    return 1 if missing else 0

if __name__ == "__main__":
    if OUT_DIR == '--check':
        sys.exit(check())
    os.makedirs(OUT_DIR, exist_ok=True)
    generate_html()
