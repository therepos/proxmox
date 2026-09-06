// ==UserScript==
// @name         MyHub Auto-Complete
// @namespace    https://github.com/therepos/proxmox
// @version      3.0.0
// @description  Walk every MyHub renewal and confirmation task: answer Yes, Continue through the wizard, fill Business Context, Submit.
// @author       therepos
// @match        https://myhub.avepointonlineservices.com/*
// @run-at       document-idle
// @noframes
// @grant        none
// @updateURL    https://raw.githubusercontent.com/therepos/proxmox/main/apps/ext/myhub.user.js
// @downloadURL  https://raw.githubusercontent.com/therepos/proxmox/main/apps/ext/myhub.user.js
// ==/UserScript==

/* Install
 *   1. Install Tampermonkey or Violentmonkey (iPad: Userscripts app).
 *   2. Open the @downloadURL above, click Install.
 *
 * Use
 *   1. Open MyHub. Click MH (bottom-right).
 *   2. Tick Dry run to click through without submitting. Untick to submit for real.
 *   3. Start. Stop ends after the current task. Keep the tab open and in the foreground.
 *
 * Notes
 *   Business Context answers are in CONFIG below. Edit there.
 *   Run state is kept in localStorage so a page reload resumes the run.
 *   A task is skipped when it has no intake question, no Continue or Submit, or no secondary owner.
 *   Source: ext-myhub.zip (content.js + popup.js), popup replaced by an in-page panel.
 */

(() => {
  'use strict';
  if (window.MH) return;

  const CONFIG = {
    dropdowns: ['Asia-Pacific', 'ASEAN', 'Singapore', 'Consulting', 'Risk Consulting'],
    purpose: 'Work Collaboration',
    contentTypes: ['EY Business Data/Information', 'Client Data/Information', 'Client Owned Records'],
    classification: 'EY Confidential C3',
    todos: '/v2/todos',
  };

  /* ================= state (survives reload) ================= */

  const KEY = 'mh.state';
  const load = () => { try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; } };
  const save = (patch) => { const s = { ...load(), ...patch }; try { localStorage.setItem(KEY, JSON.stringify(s)); } catch {} return s; };
  const running = () => !!load().running;

  const listeners = [];
  function log(msg, cls = '') {
    const s = load();
    const logs = (s.logs || []).concat({ msg, cls, ts: Date.now() }).slice(-100);
    save({ logs });
    console.log('[MyHub Auto] ' + msg);
    listeners.forEach((fn) => fn());
  }
  const setStatus = (patch) => { save(patch); listeners.forEach((fn) => fn()); };

  /* ================= page helpers ================= */

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const inPanel = (el) => !!el.closest('#mh-panel');
  const visible = (el) => el.offsetParent !== null;
  const buttons = () => [...document.querySelectorAll('button')].filter((b) => visible(b) && !inPanel(b));
  const findButton = (text) => buttons().find((b) => b.innerText.includes(text)) || null;
  const pageHas = (text) => document.body.innerText.includes(text);   // panel lives outside body

  function clickButton(text) {
    const b = findButton(text);
    if (!b) return false;
    b.scrollIntoView({ block: 'center' });
    b.click();
    return true;
  }

  const cleanText = (t) => t
    .replace(/[\u25B6\u25B7\u25C0\u25C1\u2795\u2796\u2B50\u26A0\u2714\u2716\u23F1\u23F0]|\uD83D[\uDC00-\uDFFF]|\uFE0F|\u200B|\u00A0/g, '')
    .replace(/[^\x20-\x7E\xA0-\xFF]/g, '')
    .replace(/\s+/g, ' ').trim();

  const startButtons = () => buttons().filter((b) => b.innerText.includes('Start task'));

  function taskInfo(btn) {
    let el = btn.parentElement;
    for (let i = 0; i < 10 && el; i++) {
      const lines = (el.innerText || '').split('\n').map(cleanText)
        .filter((l) => l && l !== 'Start task' && !l.startsWith('Due on') && l !== '...');
      if (lines.length) return { name: lines[0], type: lines[1] || '' };
      el = el.parentElement;
    }
    return { name: 'Unknown', type: '' };
  }

  const secondaryOwnerOk = () =>
    !pageHas('Add the Secondary Workspace Owner to proceed') && !pageHas('Add Secondary Workspace Owner');

  async function gotoTodos(ms) {
    if (!location.hash.includes('todos')) { location.hash = CONFIG.todos; await sleep(ms); }
  }

  /* ================= Business Context form ================= */

  async function fillCombo(index, value) {
    const inputs = document.querySelectorAll('input[role="combobox"]');
    if (index >= inputs.length) return false;
    const inp = inputs[index];
    if (inp.value === value) return true;
    const arrow = (inp.closest('.ms-ComboBox') || inp.parentElement)?.querySelector('button');
    if (!arrow) return false;
    for (let attempt = 0; attempt < 3; attempt++) {
      arrow.click();
      await sleep(1500);
      const opt = [...document.querySelectorAll('[role="option"]')].find((o) => o.innerText.trim() === value);
      if (opt) { opt.click(); await sleep(2000); return true; }
      document.body.click();
      await sleep(1000);
    }
    return false;
  }

  function pick(sel, match) {
    for (const input of document.querySelectorAll(sel)) {
      if (inPanel(input)) continue;
      if (match(input)) {
        if (!input.checked) { input.click(); input.dispatchEvent(new Event('change', { bubbles: true })); }
        return true;
      }
    }
    return false;
  }
  const clickRadio = (label) => pick('input[type="radio"]', (r) => (r.parentElement?.innerText?.trim() || '').startsWith(label));
  const clickCheckbox = (label) => pick('input[type="checkbox"]', (c) =>
    (c.name || '').includes(label) || (c.parentElement?.innerText?.trim() || '').startsWith(label));

  async function fillBusinessContext() {
    for (let i = 0; i < CONFIG.dropdowns.length; i++) {
      let found = false;
      for (let w = 0; w < 10; w++) {
        if (document.querySelectorAll('input[role="combobox"]').length > i) { found = true; break; }
        await sleep(1500);
      }
      if (!found) { log('    Dropdown ' + (i + 1) + ': did not appear. Skipping rest.', 'warn'); break; }
      const ok = await fillCombo(i, CONFIG.dropdowns[i]);
      log('    Dropdown ' + (i + 1) + ': ' + CONFIG.dropdowns[i] + (ok ? '' : ' (FAILED)'), ok ? 'ok' : 'warn');
      await sleep(2500);
    }
    await sleep(1000);
    clickRadio(CONFIG.purpose); log('    Purpose: ' + CONFIG.purpose, 'ok'); await sleep(500);
    for (const ct of CONFIG.contentTypes) { clickCheckbox(ct); log('    Content: ' + ct, 'ok'); await sleep(300); }
    clickRadio(CONFIG.classification); log('    Classification: ' + CONFIG.classification, 'ok');
    await sleep(2000);
  }

  /* ================= one task ================= */

  function stepLabel(step) {
    if (pageHas('Workspace Owners') && (pageHas('Confirm or change') || pageHas('governance tasks'))) return 'Workspace Owners';
    if (pageHas('Membership renewal') || (pageHas('Membership') && pageHas('M365'))) return 'Membership';
    if (pageHas('users with direct access')) return 'SharePoint (users)';
    if (pageHas('SharePoint permissions') && pageHas('groups')) return 'SharePoint (groups)';
    if (pageHas('Site admin')) return 'Site admin';
    if (pageHas('Sharing Links')) return 'Sharing Links';
    if (pageHas('Business Context')) return 'Business Context';
    return 'Step ' + (step + 1);
  }

  /* returns true = completed, false = skipped, null = stopped */
  async function processTask(name, dryRun) {
    log('Processing: ' + name, 'info');

    let yes = 0;
    for (let i = 0; i < 3; i++) {
      await sleep(1500);
      if (!running()) { log('Stopped by user.', 'warn'); return null; }
      const intake = pageHas('Do you still need this team') || pageHas('Are you responsible for this team') || pageHas('Required intake question');
      if (intake && findButton('Yes')) { clickButton('Yes'); yes++; log('  Clicked Yes (question ' + yes + ')', 'ok'); await sleep(1500); }
      else break;
    }
    if (!yes) { log('  No intake question found. Skipping.', 'warn'); return false; }

    for (let step = 0; step < 15; step++) {
      await sleep(1200);
      if (!running()) { log('Stopped by user.', 'warn'); return null; }

      if (findButton('Submit')) {
        if (pageHas('Business Context')) {
          log('  Filling Business Context...', 'info');
          await fillBusinessContext();
          log('  Business Context filled.', 'ok');
          await sleep(1000);
        }
        if (dryRun) { log('  [DRY RUN] Would click Submit. Clicking Cancel.', 'warn'); clickButton('Cancel'); return true; }
        clickButton('Submit');
        log('  Submitted.', 'ok');
        return true;
      }

      if (findButton('Continue')) {
        if (pageHas('Workspace Owners') && pageHas('Primary Workspace Owner') && !secondaryOwnerOk()) {
          log('  Secondary owner missing. Skipping task.', 'warn');
          clickButton('Cancel');
          return false;
        }
        const label = stepLabel(step);
        clickButton('Continue');
        log('  ' + label + ' -> Continue', 'ok');
        continue;
      }

      log('  Step ' + (step + 1) + ': no Submit or Continue found.', 'fail');
      return false;
    }
    log('  Exceeded max steps.', 'fail');
    return false;
  }

  /* ================= main loop ================= */

  let loopActive = false;

  async function run() {
    if (loopActive || !running()) return;
    loopActive = true;
    const dryRun = !!load().dryRun;
    let completed = 0, skipped = 0;
    const skippedNames = [];
    const attempted = new Set();

    try {
      log('=== MyHub Auto-Complete ===' + (dryRun ? ' (DRY RUN)' : ''), 'info');
      await gotoTodos(4000);

      log('Loading task list...', 'info');
      let found = false;
      for (let i = 0; i < 15; i++) { await sleep(2000); if (startButtons().length) { found = true; break; } }
      if (!found) { log('No tasks found. Nothing to do.', 'warn'); setStatus({ status: 'done', running: false, total: 0 }); return; }

      const total = startButtons().length;
      log('Found ' + total + ' task(s). Starting...', 'info');
      setStatus({ status: 'running', completed: 0, skipped: 0, skippedNames: [], total });

      let n = 0;
      while (running()) {
        await gotoTodos(4000);
        let btns = [];
        for (let i = 0; i < 10; i++) { await sleep(1500); btns = startButtons(); if (btns.length) break; }
        if (!btns.length) { log('All tasks processed.', 'ok'); break; }

        let target = null, info = null;
        for (const b of btns) {
          const t = taskInfo(b);
          const key = t.name + '|' + t.type;
          if (!attempted.has(key)) { attempted.add(key); target = b; info = t; break; }
        }
        if (!target) { log('All tasks have been attempted.', 'info'); break; }

        n++;
        log('--- Task ' + n + ' of ' + total + ': ' + info.name + ' (' + info.type + ') ---', 'info');
        target.scrollIntoView({ block: 'center' });
        target.click();
        await sleep(2500);

        let result;
        try { result = await processTask(info.name, dryRun); }
        catch (e) { log('  Error: ' + e.message, 'fail'); result = false; }
        if (result === null) break;
        if (result) { completed++; log('  Task ' + n + ': COMPLETED', 'ok'); }
        else { skipped++; skippedNames.push(info.name); log('  Task ' + n + ': SKIPPED', 'warn'); }
        setStatus({ completed, skipped, skippedNames });

        await sleep(2000);
        location.hash = CONFIG.todos;
        await sleep(3000);
      }

      log('=== SUMMARY === Completed ' + completed + ' of ' + total + (skipped ? ', skipped ' + skipped : ''), completed ? 'ok' : 'warn');
      skippedNames.forEach((s) => log('  - ' + s, 'warn'));
    } finally {
      setStatus({ status: 'done', running: false, completed, skipped, skippedNames });
      loopActive = false;
    }
  }

  function start(dryRun) {
    save({ running: true, dryRun, status: 'running', logs: [], completed: 0, skipped: 0, skippedNames: [], total: 0 });
    run();
  }
  const stop = () => { save({ running: false }); };

  window.MH = { CONFIG, start, stop, state: load, run, processTask, fillBusinessContext };

  /* ================= in-page panel ================= */

  const CSS = `
#mh-fab { position: fixed; right: 16px; bottom: 16px; z-index: 2147483646; font: 600 12px system-ui, sans-serif;
  padding: 8px 12px; border-radius: 20px; border: 1px solid #dadce0; background: #fff; color: #1a73e8;
  cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,.2); }
#mh-panel { position: fixed; right: 16px; bottom: 56px; z-index: 2147483647; width: 360px; box-sizing: border-box;
  padding: 14px; border: 1px solid #dadce0; border-radius: 10px; background: #fff; color: #1f1f1f;
  box-shadow: 0 4px 16px rgba(0,0,0,.25); font: 13px/1.45 system-ui, sans-serif; text-align: left; }
#mh-panel h1 { font-size: 14px; margin: 0 0 2px; }
#mh-panel .sub { color: #5f6368; font-size: 11px; margin-bottom: 10px; }
#mh-panel button { font: inherit; padding: 7px 12px; border-radius: 6px; border: 1px solid #dadce0;
  background: #fff; color: #1f1f1f; cursor: pointer; }
#mh-panel button:hover:not(:disabled) { background: #f1f3f4; }
#mh-panel button:disabled { opacity: .45; cursor: default; }
#mh-panel button.primary { border-color: #1a73e8; color: #1a73e8; font-weight: 600; }
#mh-panel .row { display: flex; gap: 6px; margin: 8px 0; align-items: center; }
#mh-panel label { font-size: 12px; display: flex; gap: 6px; align-items: center; cursor: pointer; }
#mh-panel .log { margin-top: 10px; font: 11px/1.5 ui-monospace, monospace; max-height: 220px; overflow: auto;
  border: 1px solid #e8eaed; border-radius: 6px; padding: 6px 8px; white-space: pre-wrap; }
#mh-panel .log .ok { color: #188038; } #mh-panel .log .warn { color: #b06000; } #mh-panel .log .fail { color: #d93025; }
#mh-panel .sum { margin-top: 8px; font-size: 12px; color: #5f6368; }
#mh-panel [hidden] { display: none !important; }
`;

  const el = (tag, attrs = {}, text) => {
    const n = document.createElement(tag);
    Object.entries(attrs).forEach(([k, v]) => (k === 'class' ? (n.className = v) : n.setAttribute(k, v)));
    if (text != null) n.textContent = text;
    return n;
  };

  function buildPanel() {
    const style = el('style'); style.textContent = CSS;
    const fab = el('button', { id: 'mh-fab', type: 'button' }, 'MH');
    const panel = el('div', { id: 'mh-panel', hidden: '' });

    const dry = el('input', { type: 'checkbox', id: 'mh-dry' });
    const dryLabel = el('label', { for: 'mh-dry' }); dryLabel.append(dry, 'Dry run (click through, do not Submit)');
    const startBtn = el('button', { type: 'button', class: 'primary' }, 'Start');
    const stopBtn = el('button', { type: 'button', disabled: '' }, 'Stop');
    const logBox = el('div', { class: 'log' });
    const sum = el('div', { class: 'sum' });
    const dryRow = el('div', { class: 'row' }); dryRow.append(dryLabel);
    const row = el('div', { class: 'row' }); row.append(startBtn, stopBtn);
    panel.append(el('h1', {}, 'MyHub Auto-Complete'), el('div', { class: 'sub' }, 'Renewal and confirmation tasks · userscript v3.0.0'),
      dryRow, row, logBox, sum);
    document.documentElement.append(style, fab, panel);
    fab.onclick = () => { panel.hidden = !panel.hidden; };

    function render() {
      const s = load();
      const on = !!s.running;
      startBtn.disabled = on; stopBtn.disabled = !on; dry.disabled = on;
      logBox.replaceChildren(...(s.logs || []).map((l) => el('div', { class: l.cls || '' }, l.msg)));
      logBox.scrollTop = logBox.scrollHeight;
      const done = (s.completed || 0) + (s.skipped || 0);
      sum.textContent = s.total ? (on ? 'Progress ' : 'Done ') + done + '/' + s.total + ' (' + (s.completed || 0) + ' done, ' + (s.skipped || 0) + ' skipped)' : '';
    }
    listeners.push(render);
    dry.checked = !!load().dryRun;
    render();

    startBtn.onclick = () => start(dry.checked);
    stopBtn.onclick = () => { stop(); log('Stopping after the current task...', 'warn'); render(); };
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', buildPanel);
  else buildPanel();

  if (running()) setTimeout(run, 2000);   // resume after a reload
})();
