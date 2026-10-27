// MyHub Auto-Complete test. Drives myhub.user.js and the unpacked ext-myhub.zip against myhub-mock.html,
// a page that mimics the task list and the seven-page renewal wizard as seen on the live site.
// Usage: node apps/ext/tests/myhub.test.js [userscript|extension|inject|all]   (default all, run in parallel)
// Needs Playwright with Chromium. CHROMIUM=/path/to/chrome overrides the browser.
'use strict';
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const assert = require('assert');
const { execFileSync } = require('child_process');
const { chromium } = (() => { try { return require('playwright'); } catch (e) { return require('/opt/node-tools/node_modules/playwright'); } })();

const DIR = __dirname;
const MOCK = fs.readFileSync(path.join(DIR, 'myhub-mock.html'), 'utf8');
const USERSCRIPT = path.join(DIR, '..', 'myhub.user.js');
const ZIP = path.join(DIR, '..', 'ext-myhub.zip');
const MYHUB = 'https://myhub.avepointonlineservices.com/';
const EXE = process.env.CHROMIUM;
const tmp = (p) => fs.mkdtempSync(path.join(os.tmpdir(), p));

/* What a full run over the four mock tasks must produce. */
const FULL = {
  total: 5, completed: 1, skipped: 4,
  skippedNames: ['Team Beta: Interim Testing', 'Team Gamma 2024', 'Mystery Team', 'Team Delta'],
  pages: ['owners', 'members', 'spusers', 'spgroups', 'siteadmin', 'sharing', 'bc'],
  lines: ['  Workspace Owners -> Continue', '  Membership -> Continue', '  SharePoint (users) -> Continue',
    '  SharePoint (groups) -> Continue (x3)', '  Site admin -> Continue', '  Sharing Links -> Continue', '  Filling Business Context...'],
  submission: { task: 'Team Alpha 2024', dropdowns: ['Asia-Pacific', 'Asia East', 'Singapore', 'Consulting', 'Risk Consulting'],
    purpose: 'Work Collaboration', contentTypes: ['EY Business Data/Information', 'Client Data/Information', 'Client Owned Records'],
    classification: 'EY Confidential C3' },
};

function checkFull(st, logs, m) {
  try {
    assert.strictEqual(st.total, FULL.total); assert.strictEqual(st.completed, FULL.completed); assert.strictEqual(st.skipped, FULL.skipped);
    assert.deepStrictEqual(st.skippedNames, FULL.skippedNames);
    assert.deepStrictEqual(m.submissions, [FULL.submission], 'Business Context submitted with the configured answers');
    // two tasks reach the SharePoint page that ignores two clicks each; nothing else may happen
    assert.deepStrictEqual(m.events, ['sp-ignored', 'sp-ignored', 'sp-ignored', 'sp-ignored'], 'no Continue without a secondary owner, no rejected submit, no Yes to an unknown question');
    assert.deepStrictEqual(m.visited.slice(0, 7), FULL.pages, 'all seven wizard pages in order');
    const i0 = logs.indexOf(FULL.lines[0]);
    assert.deepStrictEqual(logs.slice(i0, i0 + FULL.lines.length), FULL.lines, 'one log line per wizard page, in order');
    assert.ok(logs.includes('  Clicked Yes: Do you still need this team'), 'known intake question answered');
    assert.ok(logs.some((l) => /Secondary owner missing/.test(l)));
    assert.ok(logs.some((l) => /No intake question found, skipping\. Page "Team Gamma 2024", buttons: Close/.test(l)), 'diagnostics name the page');
    assert.ok(logs.some((l) => /Unknown intake question, not answering: "Does this team store client data\?/.test(l)), 'unknown question logged');
    assert.ok(logs.some((l) => /Submitted\./.test(l)) && logs.some((l) => /=== SUMMARY ===/.test(l)));
    assert.ok(logs.includes('    Dropdown 2: none of ASEAN | Asia East | All Regions found. Options: Europe West | Nordics'), 'dropdown miss lists the options');
    assert.ok(logs.some((l) => /Business Context incomplete \(dropdown 2, dropdown 3( missing)?\), not submitting/.test(l)), 'incomplete form never submitted');
  } catch (e) { e.message += '\n--- log ---\n' + logs.join('\n'); throw e; }
}

async function userscript() {
  const browser = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox'] });
  try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  const mockFile = path.join(tmp('mh-us-'), 'mock.html');
  fs.writeFileSync(mockFile, MOCK);
  await page.goto('file://' + mockFile + '#/v2/todos');
  await page.addScriptTag({ path: USERSCRIPT });
  await page.waitForSelector('button:has-text("Start task")');
  await page.click('#mh-fab');
  await page.click('#mh-panel button.primary');
  await page.waitForFunction(() => /^Working: /.test(document.querySelector('#mh-panel .phase').textContent), null, { timeout: 15000 });
  await page.waitForFunction(() => window.MH.state().status === 'done', null, { timeout: 420000 });
  const st = await page.evaluate(() => window.MH.state());
  const m = await page.evaluate(() => window.__mock);
  checkFull(st, st.logs.map((l) => l.msg), m);
  assert.strictEqual(await page.textContent('#mh-panel .phase'), 'Finished.');
  assert.match(await page.textContent('#mh-panel .sum'), /Done 5\/5 \(1 done, 4 skipped\)/);
  assert.deepStrictEqual(errors, [], 'no page errors');
  } finally { await browser.close(); }
}

function unpack(stripContentScripts) {
  const dir = fs.realpathSync(tmp('mh-ext-'));
  execFileSync('unzip', ['-q', '-o', ZIP, '-d', dir]);
  if (stripContentScripts) {   // simulate a tab opened before the extension was loaded: the popup must inject
    const mf = path.join(dir, 'manifest.json');
    const m = JSON.parse(fs.readFileSync(mf, 'utf8'));
    delete m.content_scripts;
    fs.writeFileSync(mf, JSON.stringify(m, null, 2));
  }
  return dir;
}
const extId = (dir) => [...crypto.createHash('sha256').update(dir).digest('hex').slice(0, 32)].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');

async function extension(inject) {
  const ext = unpack(inject);
  const ctx = await chromium.launchPersistentContext(tmp('mh-udd-'), Object.assign(
    { headless: true, args: ['--no-sandbox', '--disable-extensions-except=' + ext, '--load-extension=' + ext] },
    EXE ? { executablePath: EXE } : { channel: 'chromium' }));
  try {
  await ctx.route(MYHUB + '**', (r) => r.fulfill({ status: 200, contentType: 'text/html', body: MOCK }));
  const site = await ctx.newPage();
  await site.goto(MYHUB + (inject ? '?fast=1' : '') + '#/v2/todos');
  await site.waitForSelector('button:has-text("Start task")');

  const popup = await ctx.newPage();
  await popup.goto('chrome-extension://' + extId(ext) + '/popup.html');
  await popup.waitForFunction(() => document.getElementById('conn').textContent.trim() !== '');
  await popup.click('#startBtn');
  await popup.waitForFunction(() => /connected|injected|Could not|No MyHub/.test(document.getElementById('conn').textContent), null, { timeout: 15000 });
  assert.match(await popup.textContent('#conn'), inject ? /Page script injected/ : /Page script connected/);
  await site.bringToFront();
  await popup.waitForFunction(() => /^Working: /.test(document.getElementById('progress').textContent), null, { timeout: 20000 });
  assert.strictEqual(await popup.$eval('#stopBtn', (b) => b.style.display), 'block');
  await popup.waitForFunction(() => /done|error/.test(document.getElementById('statusBox').className), null, { timeout: 420000 });

  const st = await popup.evaluate(() => chrome.storage.local.get(null));
  const logs = (st.logs || []).map((l) => l.msg);
  const m = await site.evaluate(() => window.__mock);
  assert.strictEqual(st.status, 'done');
  assert.strictEqual(st.running, false);
  if (inject) {
    assert.strictEqual(st.total, 1); assert.strictEqual(st.skipped, 1);
    assert.ok(logs.some((l) => /No intake question found/.test(l)));
  } else {
    checkFull(st, logs, m);
    assert.match(await popup.textContent('#summary'), /Completed 1\/5, skipped 4: Team Beta/);
  }
  assert.strictEqual(await popup.$eval('#startBtn', (b) => b.style.display), 'block');

  // stall warning and reset, with the page closed so nothing restarts
  await site.close();
  await popup.evaluate(() => chrome.storage.local.set({ running: true, heartbeat: Date.now() - 60000, phase: 'x' }));
  await popup.waitForFunction(() => /No activity for \d+s/.test(document.getElementById('progress').textContent), null, { timeout: 5000 });
  await popup.click('#resetLink');
  await popup.waitForFunction(() => document.getElementById('startBtn').style.display === 'block', null, { timeout: 5000 });
  } finally { await ctx.close(); }
}

const jobs = { userscript, extension: () => extension(false), inject: () => extension(true) };
const mode = process.argv[2] || 'all';
const names = mode === 'all' ? Object.keys(jobs) : [mode];
if (names.some((n) => !jobs[n])) { console.error('usage: node myhub.test.js [userscript|extension|inject|all]'); process.exit(2); }
Promise.all(names.map((n) => jobs[n]().then(
  () => console.log('PASS ' + n),
  (e) => { console.error('FAIL ' + n + ': ' + (e.stack || e)); process.exitCode = 1; },
))).then(() => { console.log(process.exitCode ? 'MYHUB TESTS FAILED' : 'MYHUB TESTS PASSED'); process.exit(process.exitCode || 0); });
