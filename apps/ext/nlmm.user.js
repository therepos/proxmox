// ==UserScript==
// @name         NotebookLM Tools
// @namespace    https://github.com/therepos/proxmox
// @version      2.0.1
// @description  Bulk delete notebooks on the NotebookLM list page. Scan, preview, type DELETE, run.
// @author       therepos
// @match        https://notebooklm.google.com/*
// @match        https://notebook.google.com/*
// @run-at       document-idle
// @noframes
// @grant        none
// @updateURL    https://raw.githubusercontent.com/therepos/proxmox/main/apps/ext/nlmm.user.js
// @downloadURL  https://raw.githubusercontent.com/therepos/proxmox/main/apps/ext/nlmm.user.js
// ==/UserScript==

/* Install
 *   1. Install Tampermonkey or Violentmonkey (iPad: Userscripts app).
 *   2. Open the @downloadURL above, click Install.
 *
 * Use
 *   1. Open https://notebooklm.google.com/ and stay on the notebook list.
 *   2. Click NLM (bottom-right) > Scan notebooks.
 *   3. Type DELETE > Delete all. Stop ends after the current one.
 *   4. Keep the tab open and in the foreground.
 *
 * Notes
 *   Deletion is permanent. Each notebook is retried 3 times, then skipped and listed.
 *   Update: bump @version, push to main. Managers pull from @updateURL.
 *   Source: ext-nlmm.zip (page/core.js + page/actions/delete.js), popup replaced by an in-page panel.
 */

(() => {
  'use strict';
  if (window.NLM) return;

  /* ================= page helpers (core) ================= */

  const MENU_SEL = 'button[aria-label="Project actions menu"]';
  const ROW_SEL = 'tr, project-button, mat-card, [role="row"], [role="listitem"]';
  const TITLE_SEL = '.project-button-title, [class*="title"], td';

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const norm = (el) => (el && el.textContent || '').trim().replace(/\s+/g, ' ').toLowerCase();
  const visible = (el) => !!el && el.isConnected && el.getClientRects().length > 0;

  async function waitFor(fn, ms = 6000, step = 100) {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const v = fn();
      if (v) return v;
      await sleep(step);
    }
    return null;
  }

  const menuButtons = () => [...document.querySelectorAll(MENU_SEL)].filter(visible);

  function rowOf(btn) {
    const el = btn.closest(ROW_SEL) || btn.parentElement;
    const t = el && el.querySelector(TITLE_SEL);
    const name = ((t && t.textContent) || (el && el.textContent) || '')
      .trim().replace(/\s+/g, ' ').slice(0, 90) || '(untitled)';
    return { btn, el, name };
  }

  const rows = () => menuButtons().map(rowOf);
  const names = () => rows().map((r) => r.name);

  /* Scroll every scrollable container until the row count stops growing. */
  async function loadAll(maxRounds = 30) {
    let last = -1;
    for (let i = 0; i < maxRounds; i++) {
      const n = menuButtons().length;
      if (n === last) break;
      last = n;
      window.scrollTo(0, document.documentElement.scrollHeight);
      document.querySelectorAll('*').forEach((el) => {
        if (el.closest('#nlm-panel')) return;
        const cs = getComputedStyle(el);
        if (/(auto|scroll)/.test(cs.overflowY) && el.scrollHeight > el.clientHeight + 20) {
          el.scrollTop = el.scrollHeight;
        }
      });
      await sleep(400);
    }
    return menuButtons().length;
  }

  function closeOverlays() {
    const targets = new Set([document.activeElement, document.body].filter(Boolean));
    for (const t of targets) {
      for (const type of ['keydown', 'keyup']) {
        t.dispatchEvent(new KeyboardEvent(type, { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true }));
      }
    }
    document.querySelectorAll('.cdk-overlay-backdrop').forEach((b) => b.click());
  }

  async function openMenu(btn, ms = 4000) {
    btn.click();
    return waitFor(() => {
      const id = btn.getAttribute('aria-controls');
      const own = id && document.getElementById(id);
      if (visible(own)) return own;
      const panels = [...document.querySelectorAll('.mat-mdc-menu-panel, [role="menu"]')].filter(visible);
      return panels[panels.length - 1] || null;
    }, ms);
  }

  function menuItem(panel, test) {
    return [...panel.querySelectorAll('[role="menuitem"], button')].find((e) => test(norm(e))) || null;
  }

  async function dialogButton(test, ms = 4000) {
    return waitFor(() => {
      const dlgs = [...document.querySelectorAll('[role="dialog"], [role="alertdialog"], mat-dialog-container')].filter(visible);
      const dlg = dlgs[dlgs.length - 1];
      if (!dlg) return null;
      return [...dlg.querySelectorAll('button')].find((b) => test(norm(b))) || null;
    }, ms);
  }

  function errorToast() {
    const t = [...document.querySelectorAll('mat-snack-bar-container, [role="alert"], [role="status"]')]
      .filter((e) => visible(e) && !e.closest('#nlm-panel'));
    const bad = t.find((e) => /(wrong|error|fail|try again|too many)/.test(norm(e)));
    return bad ? norm(bad) : null;
  }

  /* ================= job runner ================= */

  const actions = {};
  let job = null;

  const fresh = (id) => ({
    id, started: true, done: false, stopRequested: false, total: 0, current: '',
    deleted: [], failed: [],
  });

  function register(id, fn) { actions[id] = fn; }

  function start(id, opts = {}) {
    if (!actions[id]) return 'unknown action: ' + id;
    if (job && !job.done) return 'busy';
    job = fresh(id);
    (async () => {
      try { await actions[id](job, opts, N); }
      catch (e) { job.failed.push('fatal: ' + (e && e.message || e)); }
      finally { job.current = ''; job.done = true; }
    })();
    return 'started';
  }

  function status() {
    if (!job) return { started: false, done: true, total: 0, current: '', deleted: [], failed: [] };
    const { id, started, done, total, current, deleted, failed } = job;
    return { id, started, done, total, current, deleted, failed };
  }

  function stop() { if (job) job.stopRequested = true; return true; }
  async function scan() { await loadAll(); return names(); }

  const N = {
    MENU_SEL, sleep, norm, visible, waitFor,
    menuButtons, rowOf, rows, names, loadAll,
    closeOverlays, openMenu, menuItem, dialogButton, errorToast,
  };
  window.NLM = { ...N, register, start, status, stop, scan };

  /* ================= action: delete ================= */

  register('delete', async (job, opts, N) => {
    const MAX_TRIES = 3;
    const BASE_DELAY = opts.delay || 1000;
    const LIMIT = opts.limit || 5000;

    const isDelete = (t) => /\bdelete\b/.test(t) && !/collection|source/.test(t);
    const isConfirm = (t) => /^(delete|delete notebook|yes, delete|confirm|ok)$/.test(t);

    const tries = new Map();
    const skip = (name) => (tries.get(name) || 0) >= MAX_TRIES;
    let delay = BASE_DELAY;

    async function deleteOne(row) {
      const { btn, name } = row;
      const before = N.menuButtons().length;
      const oldToast = N.errorToast();
      if (!N.visible(btn)) return 'row vanished before click';

      N.closeOverlays();
      const panel = await N.openMenu(btn);
      if (!panel) return 'menu did not open';

      const item = N.menuItem(panel, isDelete);
      if (!item) { N.closeOverlays(); return 'no Delete item in menu'; }
      item.click();

      const confirm = await N.dialogButton(isConfirm, 4000);
      if (confirm) confirm.click();

      const newToast = () => { const t = N.errorToast(); return t && t !== oldToast ? t : null; };
      const removed = () => N.menuButtons().length < before || !N.names().includes(name);

      const gone = await N.waitFor(() => newToast() || removed(), 12000);
      if (!gone) return 'notebook still listed after 12s';
      if (typeof gone === 'string') return 'page said: ' + gone;

      await N.sleep(500);
      if (!removed()) return 'notebook reappeared after delete';
      return null;
    }

    job.total = await N.loadAll();

    for (let i = 0; i < LIMIT && !job.stopRequested; i++) {
      let rows = N.rows().filter((r) => !skip(r.name));
      if (!rows.length) {
        await N.loadAll();
        rows = N.rows().filter((r) => !skip(r.name));
        if (!rows.length) break;
        job.total = job.deleted.length + rows.length;
      }

      const row = rows[0];
      job.current = row.name;
      const err = await deleteOne(row);

      if (!err) {
        job.deleted.push(row.name);
        delay = BASE_DELAY;
      } else {
        const n = (tries.get(row.name) || 0) + 1;
        tries.set(row.name, n);
        if (n >= MAX_TRIES) job.failed.push(row.name + ' — ' + err);
        delay = Math.min(delay * 2, 8000);
        N.closeOverlays();
      }
      await N.sleep(delay);
    }
    job.current = '';
  });

  /* ================= in-page panel (replaces the popup) ================= */

  const CSS = `
#nlm-fab { position: fixed; right: 16px; bottom: 16px; z-index: 2147483646; font: 600 12px system-ui, sans-serif;
  padding: 8px 12px; border-radius: 20px; border: 1px solid #dadce0; background: #fff; color: #1a73e8;
  cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,.2); }
#nlm-panel { position: fixed; right: 16px; bottom: 56px; z-index: 2147483647; width: 340px; box-sizing: border-box;
  padding: 14px; border: 1px solid #dadce0; border-radius: 10px; background: #fff; color: #1f1f1f;
  box-shadow: 0 4px 16px rgba(0,0,0,.25); font: 13px/1.45 system-ui, sans-serif; text-align: left; }
#nlm-panel h1 { font-size: 14px; margin: 0 0 2px; }
#nlm-panel .sub { color: #5f6368; font-size: 11px; margin-bottom: 10px; }
#nlm-panel button { font: inherit; padding: 7px 12px; border-radius: 6px; border: 1px solid #dadce0;
  background: #fff; color: #1f1f1f; cursor: pointer; }
#nlm-panel button:hover:not(:disabled) { background: #f1f3f4; }
#nlm-panel button:disabled { opacity: .45; cursor: default; }
#nlm-panel button.danger { border-color: #d93025; color: #d93025; font-weight: 600; }
#nlm-panel .list { max-height: 190px; overflow: auto; border: 1px solid #e8eaed; border-radius: 6px;
  padding: 6px 8px; margin: 10px 0; }
#nlm-panel .list div { padding: 2px 0; border-bottom: 1px solid #f1f3f4; }
#nlm-panel .list div:last-child { border-bottom: 0; }
#nlm-panel input { font: inherit; width: 100%; box-sizing: border-box; padding: 6px 8px;
  border: 1px solid #dadce0; border-radius: 6px; background: #fff; color: #1f1f1f; }
#nlm-panel .warn { background: #fce8e6; color: #a50e0e; padding: 8px; border-radius: 6px; font-size: 11px; }
#nlm-panel .row { display: flex; gap: 6px; margin: 8px 0; }
#nlm-panel .log { margin-top: 10px; font-size: 12px; color: #5f6368; white-space: pre-wrap; max-height: 160px; overflow: auto; }
#nlm-panel [hidden] { display: none !important; }
`;

  const el = (tag, attrs = {}, text) => {
    const n = document.createElement(tag);
    Object.entries(attrs).forEach(([k, v]) => (k === 'class' ? (n.className = v) : n.setAttribute(k, v)));
    if (text != null) n.textContent = text;
    return n;
  };

  function buildPanel() {
    const style = el('style'); style.textContent = CSS;
    const fab = el('button', { id: 'nlm-fab', type: 'button' }, 'NLM');
    const panel = el('div', { id: 'nlm-panel', hidden: '' });

    const scanBtn = el('button', { type: 'button' }, 'Scan notebooks');
    const runBtn = el('button', { type: 'button', class: 'danger', disabled: '' }, 'Delete all');
    const stopBtn = el('button', { type: 'button', disabled: '' }, 'Stop');
    const list = el('div', { class: 'list', hidden: '' });
    const confirm = el('div', { hidden: '' });
    const phrase = el('input', { placeholder: 'DELETE', autocomplete: 'off' });
    const log = el('div', { class: 'log' });
    const row = el('div', { class: 'row' });

    confirm.append(
      el('div', { class: 'warn' }, 'This permanently deletes these notebooks. It cannot be undone.'),
      el('p', { style: 'margin:8px 0 4px' }, 'Type DELETE to enable the button:'),
      phrase,
    );
    row.append(scanBtn, runBtn, stopBtn);
    panel.append(
      el('h1', {}, 'NotebookLM Tools'),
      el('div', { class: 'sub' }, 'Bulk delete · userscript v2.0.1'),
      row, list, confirm, log,
    );
    document.documentElement.append(style, fab, panel);

    const say = (m) => { log.textContent = m; };
    fab.onclick = () => { panel.hidden = !panel.hidden; };

    const report = (s) => {
      let m = 'Deleted ' + s.deleted.length + ' / ' + s.total;
      if (s.current) m += '\nWorking on: ' + s.current;
      if (s.failed.length) m += '\nSkipped (' + s.failed.length + '):\n' + s.failed.join('\n');
      m += s.done ? '\nFinished.' : '\n…keep the tab open.';
      say(m);
    };

    function poll() {
      const id = setInterval(() => {
        const s = status();
        report(s);
        if (s.done) { clearInterval(id); scanBtn.disabled = false; stopBtn.disabled = true; }
      }, 1000);
    }

    scanBtn.onclick = async () => {
      try {
        say('Scanning… (scrolling the page to load every notebook)');
        const found = await scan();
        list.hidden = false;
        list.replaceChildren();
        found.forEach((n, i) => list.appendChild(el('div', {}, (i + 1) + '. ' + n)));
        if (!found.length) {
          list.textContent = 'No notebooks found. Make sure you are on the notebook list, not inside a notebook.';
          confirm.hidden = true;
          runBtn.disabled = true;
          return;
        }
        say('Found ' + found.length + ' notebook(s).');
        confirm.hidden = false;
        phrase.value = '';
        runBtn.disabled = true;
      } catch (e) { say(e.message); }
    };

    phrase.oninput = () => { runBtn.disabled = phrase.value.trim() !== 'DELETE'; };

    runBtn.onclick = () => {
      runBtn.disabled = true;
      scanBtn.disabled = true;
      stopBtn.disabled = false;
      const r = start('delete');
      if (r !== 'started') { say('Could not start: ' + r); scanBtn.disabled = false; stopBtn.disabled = true; return; }
      say('Working… keep this tab open.');
      poll();
    };

    stopBtn.onclick = () => { stop(); say('Stopping after the current notebook…'); };
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', buildPanel);
  else buildPanel();
})();
