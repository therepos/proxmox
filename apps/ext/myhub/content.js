// MyHub Auto-Complete, content script v2.6
// Runs on MyHub pages and talks to the popup through chrome.storage.
// Guarded so the popup can inject it again into a tab that was open before the extension loaded.
// Answers and the intake questions it may answer Yes to are in CONFIG below.

(function () {
  if (window.__myhubAutoComplete) return;
  window.__myhubAutoComplete = true;

  const CONFIG = {
    // One list per dropdown, in order of preference: the first option present is picked, by exact text
    // first, then by an option that starts with the text. MyHub renamed ASEAN to Asia East in 2026.
    dropdowns: [['Asia-Pacific'], ['ASEAN', 'Asia East', 'All Regions'], ['Singapore', 'All Locations'], ['Consulting'], ['Risk Consulting']],
    purpose: 'Work Collaboration',
    contentTypes: ['EY Business Data/Information', 'Client Data/Information', 'Client Owned Records'],
    classification: 'EY Confidential C3',
    // Intake questions the script may answer Yes to. Any other question is logged and the task skipped.
    intake: ['Do you still need this team', 'Are you responsible for this team'],
    todos: '/v2/todos',
  };

  /* ================= storage (survives an extension reload without throwing) ================= */

  const alive = () => { try { return !!(chrome.runtime && chrome.runtime.id); } catch (e) { return false; } };
  const get = (keys) => new Promise((res) => { try { chrome.storage.local.get(keys, (d) => res(d || {})); } catch (e) { res({}); } });
  const set = (obj) => new Promise((res) => { try { chrome.storage.local.set(obj, () => res()); } catch (e) { res(); } });

  // Log writes are serialised so quick successive lines are not lost. Every write bumps the heartbeat.
  let queue = Promise.resolve();
  function log(msg, cls) {
    console.log('[MyHub Auto] ' + msg);
    queue = queue.then(async () => {
      const logs = ((await get(['logs'])).logs || []).concat({ msg, cls: cls || '', ts: Date.now() }).slice(-150);
      await set({ logs, heartbeat: Date.now() });
    });
    return queue;
  }
  let lastPhase = '';
  // One line per wizard page: repeated Continue clicks on the same page update the count in place.
  function logStep(label, n) {
    const prefix = '  ' + label + ' -> Continue';
    const msg = prefix + (n > 1 ? ' (x' + n + ')' : '');
    console.log('[MyHub Auto] ' + msg);
    queue = queue.then(async () => {
      const logs = ((await get(['logs'])).logs || []).slice(-150);
      const last = logs[logs.length - 1];
      if (n > 1 && last && last.msg.startsWith(prefix)) logs[logs.length - 1] = { msg, cls: 'ok', ts: Date.now() };
      else logs.push({ msg, cls: 'ok', ts: Date.now() });
      await set({ logs, heartbeat: Date.now() });
    });
    return queue;
  }
  const phase = (text) => { lastPhase = text; return set({ phase: text, heartbeat: Date.now() }); };
  const getConfig = async () => { const d = await get(['running', 'dryRun']); return { running: alive() && !!d.running, dryRun: !!d.dryRun }; };
  const isRunning = async () => (await getConfig()).running;

  /* ================= page helpers ================= */

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const cleanText = (t) => (t || '')
    .replace(/[▶▷◀◁➕➖⭐⚠✔✖⏱⏰]|\uD83D[\uDC00-\uDFFF]|️|​| /g, '')
    .replace(/[^\x20-\x7E\xA0-\xFF]/g, '').replace(/\s+/g, ' ').trim();
  const visible = (el) => !!el && el.offsetParent !== null;
  const buttons = () => [...document.querySelectorAll('button')].filter(visible);
  const findButton = (text) => { const all = buttons(); return all.find((b) => cleanText(b.innerText) === text) || all.find((b) => b.innerText.includes(text)) || null; };
  const isDisabled = (b) => !b || b.disabled || b.getAttribute('aria-disabled') === 'true' || b.classList.contains('is-disabled');
  const TASK_MS = 8 * 60000, DISABLED_MS = 90000, SAME_MS = 90000;
  const pageHas = (text) => document.body.innerText.includes(text);
  // The wizard's left column names every step on every page, so page checks ignore that step list:
  // pageText() returns the body text and the text of the smallest element that lists all six steps.
  const STEPS = ['Workspace Owners', 'Membership', 'SharePoint permissions', 'Site admin', 'Sharing Links', 'Business Context'];
  const listsSteps = (el) => {   // the renewal wizard's six steps, or the two-step confirm wizard
    const t = el.innerText || '';
    return STEPS.every((s) => t.includes(s)) || (t.includes('Workspace Owners') && t.includes('Business Context') && t.includes('Confirm whether'));
  };
  function pageText() {
    const body = document.body.innerText || '';
    let nav = listsSteps(document.body) ? document.body : null;
    while (nav) { const next = [...nav.children].find((c) => c.getClientRects().length && listsSteps(c)); if (!next) break; nav = next; }
    const t = nav && nav !== document.body ? nav.innerText || '' : '';
    return { body, nav: t && body.includes(t) ? t : '' };
  }
  const mainText = () => { const p = pageText(); return p.nav ? p.body.replace(p.nav, '') : p.body; };
  const mainHas = (text) => mainText().includes(text);
  const snapshot = () => mainText();
  const startButtons = () => buttons().filter((b) => b.innerText.includes('Start task'));

  function clickButton(text) {
    const b = findButton(text);
    if (!b) return false;
    b.scrollIntoView({ block: 'center' });
    b.click();
    return true;
  }

  // What is on screen, for the log when a step does not look as expected.
  const buttonTexts = () => [...new Set(buttons().map((b) => cleanText(b.innerText)).filter(Boolean))].slice(0, 10).join(' | ') || 'none';
  // Title of the current wizard page: the first line after the step list, else the first heading on the page.
  function headline() {
    const p = pageText();
    const after = p.nav ? p.body.slice(p.body.indexOf(p.nav) + p.nav.length).split('\n').map(cleanText) : [];
    const first = after.find((l) => l && !/guidance$/i.test(l));
    if (first) return first.slice(0, 80);
    const h = [...document.querySelectorAll('h1, h2, h3, [role="heading"]')].find(visible);
    return cleanText(h ? h.innerText : p.body.slice(0, 100)).slice(0, 80);
  }
  function alerts() {
    const els = [...document.querySelectorAll('[role="alert"], .ms-MessageBar, [class*="error" i]')].filter((e) => visible(e));
    return cleanText(els.map((e) => e.innerText).join(' | ')).slice(0, 160);
  }
  const where = () => { const a = alerts(); return 'Page "' + headline() + '", buttons: ' + buttonTexts() + (a ? ', message: ' + a : ''); };

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

  async function gotoTodos() {
    if (!location.hash.includes('todos')) { location.hash = CONFIG.todos; await sleep(3000); }
  }

  // Poll pred() once a second until it returns something, reporting the wait as the current phase.
  // Returns pred()'s value, null on timeout, 'stopped' when the user pressed Stop.
  async function waitFor(pred, ms, label) {
    const t0 = Date.now();
    for (;;) {
      if (!(await isRunning())) return 'stopped';
      const r = pred();
      if (r) return r;
      if (Date.now() - t0 >= ms) return null;
      await phase(label + ' (' + Math.round((Date.now() - t0) / 1000) + 's)');
      await sleep(1000);
    }
  }

  /* ================= Business Context form ================= */

  // Pick the first acceptable option of a dropdown: exact text first, then an option starting with the text.
  const matchOption = (texts, wanted) => {
    for (const w of wanted) { const i = texts.indexOf(w); if (i >= 0) return i; }
    for (const w of wanted) { const i = texts.findIndex((t) => t.startsWith(w)); if (i >= 0) return i; }
    return -1;
  };

  // { ok, picked, options }: options lists what the dropdown offered when nothing matched.
  async function fillCombo(index, wanted) {
    const inputs = document.querySelectorAll('input[role="combobox"]');
    if (index >= inputs.length) return { ok: false, options: [] };
    const inp = inputs[index];
    if (inp.value && matchOption([cleanText(inp.value)], wanted) >= 0) return { ok: true, picked: cleanText(inp.value) + ' (already set)' };
    const arrow = (inp.closest('.ms-ComboBox') || inp.parentElement)?.querySelector('button');
    if (!arrow) return { ok: false, options: [] };
    let options = [];
    for (let attempt = 0; attempt < 3; attempt++) {
      arrow.click();
      await sleep(1500);
      const opts = [...document.querySelectorAll('[role="option"]')];
      options = opts.map((o) => cleanText(o.innerText));
      const i = matchOption(options, wanted);
      if (i >= 0) { opts[i].click(); await sleep(2000); return { ok: true, picked: options[i] }; }
      document.body.click();
      await sleep(1000);
    }
    return { ok: false, options };
  }

  function pick(sel, match) {
    for (const input of document.querySelectorAll(sel)) {
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

  // Returns the fields it could not set. Nothing is submitted while that list is not empty.
  async function fillBusinessContext() {
    const problems = [];
    for (let i = 0; i < CONFIG.dropdowns.length; i++) {
      const wanted = CONFIG.dropdowns[i];
      await phase('Business Context: dropdown ' + (i + 1) + ' of ' + CONFIG.dropdowns.length);
      let found = false;
      for (let w = 0; w < 10; w++) {
        if (document.querySelectorAll('input[role="combobox"]').length > i) { found = true; break; }
        await sleep(1500);
      }
      if (!found) { log('    Dropdown ' + (i + 1) + ': did not appear.', 'fail'); problems.push('dropdown ' + (i + 1) + ' missing'); break; }
      const r = await fillCombo(i, wanted);
      if (r.ok) log('    Dropdown ' + (i + 1) + ': ' + r.picked, 'ok');
      else { log('    Dropdown ' + (i + 1) + ': none of ' + wanted.join(' | ') + ' found. Options: ' + (r.options.join(' | ') || 'none'), 'fail'); problems.push('dropdown ' + (i + 1)); }
      await sleep(2500);
    }
    await sleep(1000);
    const p = clickRadio(CONFIG.purpose); log('    Purpose: ' + CONFIG.purpose + (p ? '' : ' (not found)'), p ? 'ok' : 'fail'); if (!p) problems.push('purpose'); await sleep(500);
    for (const ct of CONFIG.contentTypes) { const c = clickCheckbox(ct); log('    Content: ' + ct + (c ? '' : ' (not found)'), c ? 'ok' : 'fail'); if (!c) problems.push('content'); await sleep(300); }
    const k = clickRadio(CONFIG.classification); log('    Classification: ' + CONFIG.classification + (k ? '' : ' (not found)'), k ? 'ok' : 'fail'); if (!k) problems.push('classification');
    await sleep(2000);
    return problems;
  }

  /* ================= one task ================= */

  // Most specific phrases first; all checks are on the content column, not the step list.
  function stepLabel(step) {
    if (mainHas('Membership renewal')) return 'Membership';
    if (mainHas('users with direct access')) return 'SharePoint (users)';
    if (mainHas('SharePoint permissions (groups)')) return 'SharePoint (groups)';
    if (mainHas('Workspace Owners renewal') || mainHas('Change Workspace Owners') || mainHas('Confirm or change')) return 'Workspace Owners';
    if (mainHas('Site admin')) return 'Site admin';
    if (mainHas('Sharing Links')) return 'Sharing Links';
    if (mainHas('Business Context')) return 'Business Context';
    if (mainHas('SharePoint permissions')) return 'SharePoint';
    if (mainHas('Workspace Owners')) return 'Workspace Owners';
    if (mainHas('Membership')) return 'Membership';
    return headline() || 'Step ' + (step + 1);
  }

  const intakeMarker = () => pageHas('Required intake question') || CONFIG.intake.some((q) => pageHas(q));
  const knownIntake = () => CONFIG.intake.find((q) => pageHas(q)) || '';
  // The question shown under the "Required intake question" badge, for the log.
  function intakeText() {
    const lines = mainText().split('\n').map(cleanText).filter(Boolean);
    const i = lines.findIndex((l) => /Required intake question/i.test(l));
    return (i >= 0 ? lines.slice(i + 1, i + 3) : lines.filter((l) => /\?$/.test(l)).slice(0, 2)).join(' ').slice(0, 160);
  }
  const wizardButton = () => (findButton('Submit') ? 'submit' : findButton('Continue') ? 'continue' : null);

  // true = completed, false = skipped, null = stopped
  async function processTask(name, dryRun) {
    log('Processing: ' + name, 'info');

    let yes = 0;
    for (let i = 0; i < 3; i++) {
      const got = await waitFor(() => (intakeMarker() && findButton('Yes') ? 'intake' : wizardButton()), i ? 5000 : 12000, 'Waiting for the task to open');
      if (got === 'stopped') return null;
      if (got !== 'intake') break;
      const q = knownIntake();
      if (!q) {
        log('  Unknown intake question, not answering: "' + (intakeText() || '?') + '". Add it to CONFIG.intake if Yes is the right answer.', 'warn');
        clickButton('Cancel');
        return false;
      }
      clickButton('Yes'); yes++;
      log('  Clicked Yes: ' + q, 'ok');
      await sleep(1500);
    }
    if (!yes) { log('  No intake question found, skipping. ' + where(), 'warn'); return false; }

    // Steps are bounded by time, not by count: a page may need several Continue clicks while it loads.
    const t0 = Date.now();
    let label = '', clicks = 0, sameSince = 0, steps = 0;
    for (;;) {
      if (Date.now() - t0 > TASK_MS) { log('  Task is taking more than ' + Math.round(TASK_MS / 60000) + ' minutes, giving up. ' + where(), 'fail'); clickButton('Cancel'); return false; }
      const got = await waitFor(wizardButton, 15000, 'Waiting for wizard step ' + (steps + 1));
      if (got === 'stopped') return null;
      if (!got) { log('  Step ' + (steps + 1) + ': no Submit or Continue after 15s. ' + where(), 'fail'); return false; }

      if (got === 'submit') {
        if (pageHas('Business Context')) {
          log('  Filling Business Context...', 'info');
          const problems = await fillBusinessContext();
          if (problems.length) {
            log('  Business Context incomplete (' + problems.join(', ') + '), not submitting. Fix CONFIG and run again.', 'fail');
            clickButton('Cancel');
            return false;
          }
          log('  Business Context filled.', 'ok');
          await sleep(1000);
        }
        if (dryRun) { log('  [DRY RUN] Would click Submit. Clicking Cancel.', 'warn'); clickButton('Cancel'); return true; }
        const before = snapshot();
        await phase('Submitting');
        clickButton('Submit');
        const moved = await waitFor(() => (snapshot() !== before ? 'changed' : null), 10000, 'Waiting for the submit to go through');
        if (moved === 'stopped') return null;
        if (!moved) { log('  Submit did not go through. ' + where(), 'fail'); clickButton('Cancel'); return false; }
        log('  Submitted.', 'ok');
        return true;
      }

      if (stepLabel(steps) === 'Workspace Owners' && !secondaryOwnerOk()) {
        log('  Secondary owner missing, skipping task.', 'warn');
        clickButton('Cancel');
        return false;
      }

      const cur = stepLabel(steps);
      if (isDisabled(findButton('Continue'))) {
        const en = await waitFor(() => (findButton('Submit') ? 'submit' : !isDisabled(findButton('Continue')) ? 'enabled' : null),
          DISABLED_MS, cur + ': Continue is disabled, waiting for the page to finish');
        if (en === 'stopped') return null;
        if (!en) { log('  ' + cur + ': Continue stayed disabled for ' + Math.round(DISABLED_MS / 1000) + 's. ' + where(), 'fail'); clickButton('Cancel'); return false; }
        if (en === 'submit') continue;
      }
      if (cur !== label) { label = cur; clicks = 0; sameSince = Date.now(); steps++; }
      clicks++;
      if (clicks > 1 && Date.now() - sameSince > SAME_MS) { log('  Still on ' + label + ' after ' + clicks + ' clicks. ' + where(), 'fail'); clickButton('Cancel'); return false; }
      if (steps > 40) { log('  More than 40 wizard steps, giving up. ' + where(), 'fail'); clickButton('Cancel'); return false; }

      const before = snapshot();
      clickButton('Continue');
      logStep(label, clicks);
      const moved = await waitFor(() => (snapshot() !== before ? 'changed' : null), 8000, 'Waiting for the next step');
      if (moved === 'stopped') return null;
      await sleep(moved ? 500 : 1500);
    }
  }

  /* ================= main loop ================= */

  let loopActive = false;

  async function runAutomation() {
    if (loopActive || !(await isRunning())) return;
    loopActive = true;
    const hb = setInterval(() => set({ heartbeat: Date.now() }), 3000);
    const { dryRun } = await getConfig();
    let completed = 0, skipped = 0, total = 0, failed = '';
    const skippedNames = [];
    const attempted = new Set();

    try {
      log('=== MyHub Auto-Complete ===' + (dryRun ? ' (DRY RUN)' : ''), 'info');
      await phase('Opening the task list');
      await gotoTodos();
      const first = await waitFor(() => (startButtons().length ? 'ok' : null), 30000, 'Loading the task list');
      if (first === 'stopped') { log('Stopped by user.', 'warn'); return; }
      if (!first) { log('No "Start task" button after 30s. ' + where(), 'warn'); return; }

      total = startButtons().length;
      const names = startButtons().slice(0, 3).map((b) => taskInfo(b).name).join(', ');
      log('Found ' + total + ' task(s): ' + names + (total > 3 ? ', ...' : ''), 'info');
      await set({ completed: 0, skipped: 0, skippedNames: [], total });

      let n = 0;
      while (await isRunning()) {
        await gotoTodos();
        const ready = await waitFor(() => (startButtons().length ? 'ok' : null), 15000, 'Loading the task list');
        if (ready === 'stopped') break;
        if (!ready) { log('All tasks processed.', 'ok'); break; }

        let target = null, info = null;
        for (const b of startButtons()) {
          const t = taskInfo(b);
          const key = t.name + '|' + t.type;
          if (!attempted.has(key)) { attempted.add(key); target = b; info = t; break; }
        }
        if (!target) { log('All visible tasks have been attempted.', 'info'); break; }

        n++;
        log('--- Task ' + n + ' of ' + total + ': ' + info.name + ' (' + info.type + ') ---', 'info');
        await phase('Opening task ' + n + ': ' + info.name);
        target.scrollIntoView({ block: 'center' });
        target.click();
        await sleep(2000);

        let result;
        try { result = await processTask(info.name, dryRun); }
        catch (e) { log('  Error: ' + e.message, 'fail'); result = false; }
        if (result === null) { log('Stopped by user.', 'warn'); break; }
        if (result) { completed++; log('  Task ' + n + ': COMPLETED', 'ok'); }
        else { skipped++; skippedNames.push(info.name); log('  Task ' + n + ': SKIPPED', 'warn'); }
        await set({ completed, skipped, skippedNames });

        await phase('Returning to the task list');
        await sleep(1500);
        location.hash = CONFIG.todos;
        await sleep(2500);
      }

      log('=== SUMMARY === Completed ' + completed + ' of ' + total + (skipped ? ', skipped ' + skipped : ''), completed ? 'ok' : 'warn');
      skippedNames.forEach((s) => log('  - ' + s, 'warn'));
    } catch (e) {
      failed = String((e && e.message) || e);
      log('Stopped with an error: ' + failed, 'fail');
    } finally {
      clearInterval(hb);
      await queue;
      await set({ status: failed ? 'error' : 'done', error: failed, running: false, completed, skipped, skippedNames, total, phase: 'Finished', heartbeat: Date.now() });
      loopActive = false;
    }
  }

  /* ================= wiring ================= */

  chrome.runtime.onMessage.addListener((msg, sender, reply) => {
    if (msg && msg.type === 'ping') reply({ alive: true, running: loopActive, phase: lastPhase });
  });

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.running && changes.running.newValue === true) runAutomation();
  });

  getConfig().then((cfg) => { if (cfg.running) setTimeout(runAutomation, 2000); });   // resume after a reload
})();
