// ETC Hours Extractor test. Loads eyetc.user.js on eyetc-mock.html (SAP, Kendo-style, split-grid and plain tables,
// one hidden) and checks what the panel extracts. Usage: node apps/ext/tests/eyetc.test.js   CHROMIUM=/path overrides the browser.
'use strict';
const path = require('path');
const assert = require('assert');
const { chromium } = (() => { try { return require('playwright'); } catch (e) { return require('/opt/node-tools/node_modules/playwright'); } })();
const SCRIPT = path.join(__dirname, '..', 'eyetc.user.js');
const MOCK = path.join(__dirname, 'eyetc-mock.html');
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  page.on('pageerror', (e) => { console.error('PAGE ERROR', e.message); process.exitCode = 1; });
  await page.goto('file://' + MOCK);
  await page.addScriptTag({ path: SCRIPT });

  const all = await page.evaluate(() => window.ETC.scan().map((d) => ({ id: d.root.id, headers: d.headers, rows: d.rows, footer: d.footer, label: d.label })));
  console.log(JSON.stringify(all, null, 1));

  const by = Object.fromEntries(all.map((d) => [d.id, d]));
  assert.deepStrictEqual(Object.keys(by).sort(), ['eng', 'grid3', 'plain', 'resourcingTbl-listUl'], 'hidden table must be skipped, others found');

  // 1. Kendo-style engagement grid
  assert.deepStrictEqual(by.eng.headers, ['Client ID', 'Engagement ID', 'Client Name', 'Engagement Name', 'Items Missing', 'Days Since Engagement is Actionable']);
  assert.deepStrictEqual(by.eng.rows, [
    ['', '70240119', 'ACME HOLDINGS PTE. LTD.', 'Acme FY26 Secondment', 'SOW Posted, MSA/GFA not linked', ''],
    ['C-2', '70240120', 'ACME, PTE. LTD.', 'ACME FY26 Audit', 'GFA not linked', '12'],
  ]);
  assert.strictEqual(by.eng.footer, null);

  // 2. sap.m.Table resourcing
  const r = by['resourcingTbl-listUl'];
  assert.deepStrictEqual(r.headers, ['Name', 'Planned - Hours', 'Role']);
  assert.deepStrictEqual(r.rows, [['Alice Tan', '40', 'Senior'], ['Bob Lim', '12.5', 'Manager']]);
  assert.deepStrictEqual(r.footer, ['Total', '52.5', '']);

  // 3. split grid merged on row index
  assert.deepStrictEqual(by.grid3.headers, ['ID', 'Client', 'Status']);
  assert.deepStrictEqual(by.grid3.rows, [['1', 'Client A', 'Open'], ['2', 'Client B', 'Closed']]);

  // 4. plain table
  assert.deepStrictEqual(by.plain.headers, ['Engagement ID', 'Client', 'Hours']);
  assert.deepStrictEqual(by.plain.rows, [['1001', 'Zeta "Z" Ltd', '8'], ['1002', 'Omega Ltd', '4']]);
  assert.deepStrictEqual(by.plain.footer, ['Total', '', '12']);

  // default pick = most rows (eng, resourcing, grid3, plain all have 2 rows -> most columns wins)
  assert.strictEqual(all[0].id, 'eng');

  // CSV escaping
  const csv = await page.evaluate(() => window.ETC.toCSV(window.ETC.extract(0).all.find((d) => d.root.id === 'plain')));
  assert.strictEqual(csv, 'Engagement ID,Client,Hours\n1001,"Zeta ""Z"" Ltd",8\n1002,Omega Ltd,4\nTotal,,12\n');

  // panel flow
  await page.waitForSelector('#etc-fab:not([hidden])', { timeout: 3000 });
  await page.click('#etc-fab');
  await page.click('#etc-panel button.primary');
  const log = await page.textContent('#etc-panel .log');
  assert.match(log, /Extracted 2 rows x 6 cols\./);
  const opts = await page.$$eval('#etc-pick option', (o) => o.map((x) => x.textContent));
  assert.strictEqual(opts.length, 4);
  assert.strictEqual(await page.$eval('#etc-pick', (s) => s.hidden), false);
  await page.selectOption('#etc-pick', '1');
  const log2 = await page.textContent('#etc-panel .log');
  assert.match(log2, /Extracted 2 rows x 3 cols \+ totals\./);
  const previewHdr = await page.$$eval('#etc-panel .wrap th', (t) => t.map((x) => x.textContent));
  assert.deepStrictEqual(previewHdr, ['Name', 'Planned - Hours', 'Role']);
  assert.strictEqual(await page.$eval('#etc-panel button:nth-child(2)', (b) => b.disabled), false);

  // panel's own preview table must never be scanned
  const n = await page.evaluate(() => window.ETC.scan().length);
  assert.strictEqual(n, 4);

  // no table page: FAB hidden, Extract reports it
  await page.goto('data:text/html,<p>nothing</p>');
  await page.addScriptTag({ path: SCRIPT });
  await page.waitForTimeout(100);
  assert.strictEqual(await page.$eval('#etc-fab', (b) => b.hidden), true);
  await page.evaluate(() => { document.querySelector('#etc-panel').hidden = false; document.querySelector('#etc-panel button.primary').click(); });
  assert.match(await page.textContent('#etc-panel .log'), /No data table found/);

  await browser.close();
  console.log('ALL TESTS PASSED');
})().catch((e) => { console.error(e); process.exit(1); });
