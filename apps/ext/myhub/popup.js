// MyHub Auto-Complete, popup v2.6
// Finds the MyHub tab, makes sure the content script is loaded there, then flips the running flag.
// Shows the content script's log, its current phase and warns when it stops reporting.

const $ = (id) => document.getElementById(id);
const ui = {
  start: $('startBtn'), stop: $('stopBtn'), box: $('statusBox'), progress: $('progress'), logs: $('logs'),
  summary: $('summary'), dry: $('dryRun'), options: $('optionsPanel'), note: $('runningNote'), conn: $('conn'), reset: $('resetLink'),
  version: $('version'), update: $('update'), updateText: $('updateText'), release: $('releaseLink'), reload: $('reloadLink'), reload2: $('reloadLink2'),
};
const VERSION = chrome.runtime.getManifest().version;
const REPO = 'therepos/proxmox';
const TAG = 'myhub-v';
const CHECK_MS = 6 * 3600 * 1000;
const MYHUB = 'https://myhub.avepointonlineservices.com/';
const STALL_MS = 45000;
const KEYS = ['running', 'dryRun', 'status', 'logs', 'completed', 'skipped', 'skippedNames', 'total', 'phase', 'heartbeat', 'error'];
let state = {};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isMyHub = (url) => typeof url === 'string' && url.startsWith(MYHUB);
const setConn = (text, cls) => { ui.conn.textContent = text; ui.conn.className = 'conn ' + (cls || ''); };

// ── MyHub tab and content script ─────────────────────────────────────
async function myHubTab() {
  try {
    const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (active && isMyHub(active.url)) return active;
    const tabs = await chrome.tabs.query({ url: MYHUB + '*' });
    return tabs[0] || null;
  } catch (e) { return null; }
}

async function ping(tabId) {
  try { const r = await chrome.tabs.sendMessage(tabId, { type: 'ping' }); return r && r.alive ? r : null; }
  catch (e) { return null; }
}

// 'connected' | 'injected' | 'failed: reason'
async function ensureScript(tabId) {
  if (await ping(tabId)) return 'connected';
  try { await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] }); }
  catch (e) { return 'failed: ' + e.message; }
  await sleep(500);
  return (await ping(tabId)) ? 'injected' : 'failed: no answer after loading the script';
}

// ── Render ────────────────────────────────────────────────────────────
function render() {
  const s = state;
  const on = !!s.running;
  const status = s.status || 'idle';
  const logs = s.logs || [];
  const ago = s.heartbeat ? Math.max(0, Math.round((Date.now() - s.heartbeat) / 1000)) : null;
  const stale = on && ago !== null && ago * 1000 > STALL_MS;

  ui.start.style.display = on ? 'none' : 'block';
  ui.stop.style.display = on ? 'block' : 'none';
  ui.options.style.display = on ? 'none' : 'block';
  ui.note.style.display = on ? 'block' : 'none';

  ui.box.className = 'status-box ' + (stale || status === 'error' ? 'error' : on ? 'running' : status === 'done' ? 'done' : '');
  ui.box.style.display = on || logs.length || status === 'error' ? 'block' : 'none';

  let p = '';
  if (on && stale) p = 'No activity for ' + ago + 's. Is the MyHub tab still open and in the foreground? If it stays stuck: Stop, reload the MyHub tab, Start again.';
  else if (on) p = 'Working: ' + (s.phase || 'starting') + (ago !== null ? ' (' + ago + 's ago)' : '');
  else if (status === 'error') p = 'Stopped with an error: ' + (s.error || 'see log');
  else if (status === 'done') p = 'Finished.';
  ui.progress.textContent = p;
  ui.progress.className = 'progress' + (stale || status === 'error' ? ' stale' : '');

  const sig = logs.length + ':' + (logs.length ? logs[logs.length - 1].msg : '');
  if (sig !== render.sig) {
    render.sig = sig;
    ui.logs.replaceChildren(...logs.map((l) => { const d = document.createElement('div'); d.className = 'log-line ' + (l.cls || ''); d.textContent = l.msg; return d; }));
    ui.box.scrollTop = ui.box.scrollHeight;
  }

  const done = (s.completed || 0) + (s.skipped || 0);
  const total = s.total || 0;
  if (!on && (status === 'done' || status === 'error') && total) {
    ui.summary.style.display = 'block';
    ui.summary.textContent = 'Completed ' + (s.completed || 0) + '/' + total
      + (s.skipped ? ', skipped ' + s.skipped + ': ' + (s.skippedNames || []).join(', ') : '');
  } else if (on && total) {
    ui.summary.style.display = 'block';
    ui.summary.textContent = 'Progress ' + done + '/' + total + ' (' + (s.completed || 0) + ' done, ' + (s.skipped || 0) + ' skipped)';
  } else {
    ui.summary.style.display = 'none';
  }
}

async function refresh() { state = await chrome.storage.local.get(KEYS); render(); }

// ── Newer release on GitHub? Checked at most every 6 hours. api.github.com allows cross-origin reads. ──
const cmpVer = (a, b) => {
  const x = String(a).split('.').map(Number), y = String(b).split('.').map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) { const d = (x[i] || 0) - (y[i] || 0); if (d) return d; }
  return 0;
};
async function latestRelease() {
  const { updateCheck } = await chrome.storage.local.get(['updateCheck']);
  if (updateCheck && Date.now() - updateCheck.at < CHECK_MS) return updateCheck;
  try {
    const r = await fetch('https://api.github.com/repos/' + REPO + '/releases?per_page=30', { headers: { Accept: 'application/vnd.github+json' } });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const rels = (await r.json()).filter((x) => x && typeof x.tag_name === 'string' && x.tag_name.startsWith(TAG));
    rels.sort((a, b) => cmpVer(b.tag_name.slice(TAG.length), a.tag_name.slice(TAG.length)));
    const info = { at: Date.now(), version: rels.length ? rels[0].tag_name.slice(TAG.length) : '', url: rels.length ? rels[0].html_url : '' };
    await chrome.storage.local.set({ updateCheck: info });
    return info;
  } catch (e) { return { at: 0, version: '', url: '' }; }
}
async function showUpdate() {
  const info = await latestRelease();
  if (!info.version || cmpVer(info.version, VERSION) <= 0) return;
  ui.updateText.textContent = 'v' + info.version + ' is available (installed v' + VERSION + '). Run myhub-setup.cmd, choose U, then click Reload extension.';
  ui.release.onclick = (e) => { e.preventDefault(); chrome.tabs.create({ url: info.url }); };
  ui.update.style.display = 'block';
}
chrome.storage.onChanged.addListener((changes, area) => { if (area === 'local') refresh(); });
setInterval(render, 1000);

// ── Open: show state and whether the MyHub tab answers ────────────────
(async () => {
  ui.version.textContent = 'v' + VERSION;
  showUpdate();
  await refresh();
  ui.dry.checked = !!state.dryRun;
  const tab = await myHubTab();
  if (!tab) { setConn('No MyHub tab open. Open ' + MYHUB + '#/v2/todos first.', 'fail'); return; }
  const r = await ping(tab.id);
  if (r) setConn('Page script connected' + (r.running ? ', run in progress' : '') + (tab.active ? '.' : '. Switch to the MyHub tab and keep it in front.'), 'ok');
  else if (state.running) setConn('Run flag is set but the MyHub tab does not answer (tab or extension reloaded?). Press Stop, then Start again.', 'fail');
  else setConn('Page script not loaded in the MyHub tab yet. Start will load it.', '');
})();

// ── Buttons ───────────────────────────────────────────────────────────
ui.start.addEventListener('click', async () => {
  ui.start.disabled = true;
  setConn('Connecting to the MyHub tab...', '');
  const tab = await myHubTab();
  if (!tab) { setConn('No MyHub tab found. Open ' + MYHUB + '#/v2/todos and press Start again.', 'fail'); ui.start.disabled = false; return; }
  const r = await ensureScript(tab.id);
  if (r.startsWith('failed')) {
    setConn('Could not load the page script in the MyHub tab (' + r + '). Reload that tab and press Start again.', 'fail');
    ui.start.disabled = false;
    return;
  }
  setConn('Page script ' + r + (tab.active ? '.' : '. Switch to the MyHub tab and keep it in front.'), 'ok');
  await chrome.storage.local.set({
    running: true, dryRun: ui.dry.checked, status: 'running', logs: [], completed: 0, skipped: 0, skippedNames: [], total: 0,
    phase: 'Starting', heartbeat: Date.now(), error: '',
  });
  ui.start.disabled = false;
});

ui.stop.addEventListener('click', () => {
  chrome.storage.local.set({ running: false, phase: 'Stopping after the current step' });
});

const reloadExt = (e) => { e.preventDefault(); chrome.runtime.reload(); };
ui.reload.addEventListener('click', reloadExt);
ui.reload2.addEventListener('click', reloadExt);

ui.reset.addEventListener('click', (e) => {
  e.preventDefault();
  chrome.storage.local.set({ running: false, status: 'idle', logs: [], completed: 0, skipped: 0, skippedNames: [], total: 0, phase: '', error: '', heartbeat: 0 });
  setConn('Reset done.', '');
});
