// ==UserScript==
// @name         ETC Hours Extractor
// @namespace    https://github.com/therepos/proxmox
// @version      2.0.0
// @description  Extract the resourcing table from the ETC SAP Fiori app as CSV, JSON or Excel paste.
// @author       therepos
// @match        *://*/*
// @run-at       document-idle
// @noframes
// @grant        none
// @updateURL    https://raw.githubusercontent.com/therepos/proxmox/main/apps/ext/eyetc.user.js
// @downloadURL  https://raw.githubusercontent.com/therepos/proxmox/main/apps/ext/eyetc.user.js
// ==/UserScript==

/* Install
 *   1. Install Tampermonkey or Violentmonkey (iPad: Userscripts app).
 *   2. Open the @downloadURL above, click Install.
 *
 * Use
 *   1. Open the ETC page with the My Team resourcing table visible.
 *   2. Click ETC (bottom-right) > Extract.
 *   3. CSV, JSON download the file. Excel copies tab-separated text, paste into A1.
 *
 * Notes
 *   @match is every site, the button only shows when a SAP UI5 table is on the page.
 *   Narrow @match to the ETC host once known.
 *   Hidden placeholders and the actions column are dropped. Footer totals are kept as the last row.
 *   Source: ext-eyETC.zip (content.js + popup.js), popup replaced by an in-page panel.
 */

(() => {
  'use strict';
  if (window.ETC) return;

  /* ================= page helpers ================= */

  const HIDDEN_SEL = '.sapUiHiddenPlaceholder, [aria-hidden="true"], .sapUiInvisibleText';
  const ACTION_COL = '__column9';

  function cellText(cell) {
    if (!cell) return '';
    const input = cell.querySelector('input.sapMInputBaseInner');
    if (input) return input.value || '';
    const clone = cell.cloneNode(true);
    clone.querySelectorAll(HIDDEN_SEL).forEach((el) => el.remove());
    return (clone.textContent || '').trim().replace(/\s+/g, ' ');
  }

  const isAction = (cell) => (cell.getAttribute('data-sap-ui-column') || '').includes(ACTION_COL);

  const findTable = () =>
    document.querySelector('[id*="resourcingTbl"] table.sapMListTbl') ||
    document.querySelector('table.sapMListTbl');

  function headers(table) {
    const row = table.querySelector('thead tr.sapMListTblHeader');
    if (!row) return [];
    return [...row.querySelectorAll('th.sapMListTblHeaderCell')].filter((c) => !isAction(c)).map((cell, i) => {
      const labels = [...cell.querySelectorAll('.sapMLabel:not(.sapMLabelNoText) .sapMLabelTextWrapper bdi')]
        .map((l) => (l.textContent || '').trim()).filter(Boolean);
      return labels.join(' - ') || cellText(cell) || 'Column ' + (i + 1);
    });
  }

  const cells = (tr, sel) => [...tr.querySelectorAll(sel)].filter((c) => !isAction(c)).map(cellText);

  function rows(table) {
    const body = table.querySelector('tbody.sapMTableTBody');
    if (!body) return [];
    return [...body.querySelectorAll('tr.sapMListTblRow')]
      .map((tr) => cells(tr, 'td.sapMListTblCell'))
      .filter((r) => r.length && r.some((v) => v !== ''));
  }

  function footer(table) {
    const tr = table.querySelector('tfoot tr.sapMListTblFooter');
    if (!tr) return null;
    const f = cells(tr, 'td.sapMListTblFooterCell');
    return f.some((v) => v !== '') ? f : null;
  }

  function extract() {
    const table = findTable();
    if (!table) return { ok: false, error: 'No resourcing table found. Open the ETC page with the My Team table visible.' };
    return {
      ok: true,
      headers: headers(table),
      rows: rows(table),
      footer: footer(table),
      at: new Date().toISOString(),
    };
  }

  /* ================= formats ================= */

  const csvEsc = (v) => { const s = String(v || ''); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
  const lines = (d) => [d.headers, ...d.rows, ...(d.footer ? [d.footer] : [])];
  const toCSV = (d) => lines(d).map((r) => r.map(csvEsc).join(',')).join('\n') + '\n';
  const toTSV = (d) => lines(d).map((r) => r.join('\t')).join('\n') + '\n';
  const toJSON = (d) => JSON.stringify({
    extractedAt: d.at,
    rowCount: d.rows.length,
    data: d.rows.map((r) => Object.fromEntries(d.headers.map((h, i) => [h, r[i] || '']))),
    totals: d.footer ? Object.fromEntries(d.headers.map((h, i) => [h, d.footer[i] || '']).filter((e) => e[1])) : null,
  }, null, 2);

  function download(text, name, type) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type }));
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  window.ETC = { extract, toCSV, toTSV, toJSON, findTable };

  /* ================= in-page panel ================= */

  const CSS = `
#etc-fab { position: fixed; right: 16px; bottom: 16px; z-index: 2147483646; font: 600 12px system-ui, sans-serif;
  padding: 8px 12px; border-radius: 20px; border: 1px solid #dadce0; background: #fff; color: #1a73e8;
  cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,.2); }
#etc-panel { position: fixed; right: 16px; bottom: 56px; z-index: 2147483647; width: 380px; box-sizing: border-box;
  padding: 14px; border: 1px solid #dadce0; border-radius: 10px; background: #fff; color: #1f1f1f;
  box-shadow: 0 4px 16px rgba(0,0,0,.25); font: 13px/1.45 system-ui, sans-serif; text-align: left; }
#etc-panel h1 { font-size: 14px; margin: 0 0 2px; }
#etc-panel .sub { color: #5f6368; font-size: 11px; margin-bottom: 10px; }
#etc-panel button { font: inherit; padding: 7px 12px; border-radius: 6px; border: 1px solid #dadce0;
  background: #fff; color: #1f1f1f; cursor: pointer; }
#etc-panel button:hover:not(:disabled) { background: #f1f3f4; }
#etc-panel button:disabled { opacity: .45; cursor: default; }
#etc-panel button.primary { border-color: #1a73e8; color: #1a73e8; font-weight: 600; }
#etc-panel .row { display: flex; gap: 6px; margin: 8px 0; }
#etc-panel .log { margin-top: 10px; font-size: 12px; color: #5f6368; white-space: pre-wrap; }
#etc-panel .wrap { max-height: 220px; overflow: auto; border: 1px solid #e8eaed; border-radius: 6px; margin-top: 10px; }
#etc-panel table { border-collapse: collapse; font-size: 11px; white-space: nowrap; }
#etc-panel th, #etc-panel td { padding: 4px 8px; border-bottom: 1px solid #f1f3f4; text-align: left; }
#etc-panel th { position: sticky; top: 0; background: #f8f9fa; color: #5f6368; font-weight: 500; }
#etc-panel tr.total td { font-weight: 600; border-top: 2px solid #e8eaed; }
#etc-panel [hidden] { display: none !important; }
`;

  const el = (tag, attrs = {}, text) => {
    const n = document.createElement(tag);
    Object.entries(attrs).forEach(([k, v]) => (k === 'class' ? (n.className = v) : n.setAttribute(k, v)));
    if (text != null) n.textContent = text;
    return n;
  };

  function buildPanel() {
    const style = el('style'); style.textContent = CSS;
    const fab = el('button', { id: 'etc-fab', type: 'button', hidden: '' }, 'ETC');
    const panel = el('div', { id: 'etc-panel', hidden: '' });

    const extractBtn = el('button', { type: 'button', class: 'primary' }, 'Extract');
    const csvBtn = el('button', { type: 'button', disabled: '' }, 'CSV');
    const jsonBtn = el('button', { type: 'button', disabled: '' }, 'JSON');
    const excelBtn = el('button', { type: 'button', disabled: '' }, 'Excel');
    const log = el('div', { class: 'log' }, 'Click Extract to read the table on this page.');
    const wrap = el('div', { class: 'wrap', hidden: '' });
    const row = el('div', { class: 'row' });
    row.append(extractBtn, csvBtn, jsonBtn, excelBtn);
    panel.append(el('h1', {}, 'ETC Hours Extractor'), el('div', { class: 'sub' }, 'SAP Fiori resourcing table · userscript v2.0.0'), row, log, wrap);
    document.documentElement.append(style, fab, panel);

    let data = null;
    const say = (m) => { log.textContent = m; };
    const stamp = () => new Date().toISOString().slice(0, 10);
    fab.onclick = () => { panel.hidden = !panel.hidden; };

    function preview(d) {
      const table = el('table');
      const thead = el('thead'), tbody = el('tbody');
      const tr = el('tr'); d.headers.forEach((h) => tr.append(el('th', {}, h))); thead.append(tr);
      d.rows.forEach((r) => { const x = el('tr'); r.forEach((c) => x.append(el('td', {}, c))); tbody.append(x); });
      if (d.footer) { const x = el('tr', { class: 'total' }); d.footer.forEach((c) => x.append(el('td', {}, c))); tbody.append(x); }
      table.append(thead, tbody);
      wrap.replaceChildren(table);
      wrap.hidden = false;
    }

    extractBtn.onclick = () => {
      const d = extract();
      [csvBtn, jsonBtn, excelBtn].forEach((b) => { b.disabled = !d.ok; });
      if (!d.ok) { data = null; wrap.hidden = true; say(d.error); return; }
      data = d;
      say('Extracted ' + d.rows.length + ' rows' + (d.footer ? ' + totals' : '') + '.');
      preview(d);
    };
    csvBtn.onclick = () => { download(toCSV(data), 'etc-hours-' + stamp() + '.csv', 'text/csv;charset=utf-8;'); say('CSV downloaded.'); };
    jsonBtn.onclick = () => { download(toJSON(data), 'etc-hours-' + stamp() + '.json', 'application/json;charset=utf-8;'); say('JSON downloaded.'); };
    excelBtn.onclick = async () => {
      try { await navigator.clipboard.writeText(toTSV(data)); say('Copied. In Excel select A1, Ctrl+V.'); }
      catch { say('Clipboard access denied.'); }
    };

    const gate = () => { fab.hidden = !findTable() && panel.hidden; };
    gate();
    setInterval(gate, 2000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', buildPanel);
  else buildPanel();
})();
