// ==UserScript==
// @name         ETC Hours Extractor
// @namespace    https://github.com/therepos/proxmox
// @version      2.1.0
// @description  Extract the table on screen in the ETC app (My Team resourcing, engagement lists) as CSV, JSON or Excel paste.
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
 *   1. Open the ETC page with the table you want on screen (My Team resourcing, engagement list, ...).
 *   2. Click ETC (bottom-right) > Extract. If the page has several tables, pick one in the dropdown.
 *   3. CSV, JSON download the file. Excel copies tab-separated text, paste into A1.
 *
 * Notes
 *   @match is every site, the button only shows when a visible data table is on the page.
 *   Narrow @match to the ETC host once known.
 *   Reads SAP Fiori tables (sap.m.Table with popins, sap.ui.table), ARIA grids (Kendo, AG Grid, ...)
 *   and plain HTML tables. Hidden tables and tabs are skipped. Selection, highlight and button-only
 *   columns (Actions) are dropped, sort markers are stripped from headers, footer totals are kept as
 *   the last row. Virtualised grids only render the rows on screen: page through them before extracting.
 *   Source: ext-eyETC.zip (content.js + popup.js), popup replaced by an in-page panel.
 */

(() => {
  'use strict';
  if (window.ETC) return;

  /* ================= page helpers ================= */

  const PANEL = '#etc-panel';
  const SAPM = 'table.sapMListTbl';
  const ROOT_SEL = SAPM + ', .sapUiTable, [role="grid"], [role="treegrid"], [role="table"], table';
  const JUNK_SEL = 'script, style, template, svg, [hidden], [aria-hidden="true"], .sapUiHiddenPlaceholder, .sapUiInvisibleText, '
    + '.sapUiIcon, .k-icon, .k-svg-icon, .ag-icon, .mat-icon, .material-icons, .material-symbols-outlined, .pi, .fa, .fas, .far, .glyphicon';
  const SORT_SEL = '.k-sort-order, .k-sort-icon, .ag-sort-indicator-container, .ag-sort-order, .p-sortable-column-icon, '
    + '.p-sortable-column-badge, .mat-sort-header-arrow, .sapMColumnHeaderSortIndicator, [class*="sort-order"], '
    + '[class*="sort-indicator"], [class*="sortorder"]';
  const TITLE_SEL = '.sapMLabel:not(.sapMLabelNoText) .sapMLabelTextWrapper bdi, .sapUiTableColText, .k-column-title, '
    + '.ag-header-cell-text, .mat-sort-header-content, .p-column-title';
  const BTN_SEL = 'button, [role="button"], [role="menuitem"]';
  const CELL_SEL = '[role="gridcell"], [role="cell"], [role="rowheader"], td, th';
  const ARROWS = '[\\u2191\\u2193\\u25B2\\u25BC\\u21C5\\u21F5\\u2B06\\u2B07]';
  const SORT_RE = new RegExp('^(?:' + ARROWS + '\\s*\\d*\\s*)+|(?:\\s*' + ARROWS + '\\s*\\d*)+$', 'g');
  const GLYPH_RE = /^[\s.·•…⋯⋮-]*$/;   // empty, dots or icon-font glyphs
  const ACTION_RE = /^(?:actions?)?$/i;                                     // blank header or "Actions"
  const ROW_KEYS = ['aria-rowindex', 'data-sap-ui-rowindex', 'row-index', 'data-rowindex', 'data-row-index', 'data-uid'];

  const visible = (el) => !!el && el.getClientRects().length > 0;
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const num = (v, d) => { const n = parseInt(v, 10); return Number.isFinite(n) ? n : d; };
  const span = (c) => Math.max(num(c.getAttribute('colspan'), 1), num(c.getAttribute('aria-colspan'), 1));
  const kids = (el, sel) => [...el.children].filter((c) => c.matches(sel) && visible(c));

  // Visible text of a node. Form controls contribute their value, icons and hidden helpers nothing.
  function text(node, opts = {}) {
    if (!node) return '';
    const clone = node.cloneNode(true);
    const live = node.querySelectorAll('input, select, textarea');
    clone.querySelectorAll('input, select, textarea').forEach((el, i) => {
      const src = live[i] || el;
      const t = (src.type || '').toLowerCase();
      let v = '';
      if (src.tagName === 'SELECT') v = src.selectedIndex >= 0 ? src.options[src.selectedIndex].textContent : '';
      else if (!/^(checkbox|radio|button|submit|reset|hidden)$/.test(t)) v = src.value || '';
      el.replaceWith(' ' + v + ' ');
    });
    clone.querySelectorAll('br').forEach((el) => el.replaceWith(' '));
    const drop = JUNK_SEL + (opts.header ? ', ' + SORT_SEL : '') + (opts.noButtons ? ', ' + BTN_SEL : '');
    clone.querySelectorAll(drop).forEach((el) => el.remove());
    return norm(clone.textContent);
  }

  // Header label without sort arrows. Empty string when the column has no title.
  function headerText(cell) {
    const titles = [...new Set([...cell.querySelectorAll(TITLE_SEL)].map((el) => text(el, { header: true })).filter(Boolean))];
    const raw = titles.length ? titles.join(' - ') : text(cell, { header: true });
    return norm(raw.replace(SORT_RE, ''));
  }

  // [text without buttons, text with buttons] so button-only columns can be told apart later.
  function cellValue(cell) {
    if (!cell) return ['', ''];
    const v = text(cell, { noButtons: true });
    return [v, v || !cell.querySelector(BTN_SEL) ? v : text(cell)];
  }

  // Align headers, rows and footer, then drop columns that are blank or button-only
  // (selection, highlight, Actions). Button text is kept only in columns that are not action-like.
  function finish(root, headers, rowCells, footCells) {
    const width = Math.max(headers.length, footCells ? footCells.length : 0, ...rowCells.map((r) => r.length));
    const hdr = Array.from({ length: width }, (_, i) => headers[i] || '');
    const act = hdr.map((h) => ACTION_RE.test(h));
    const val = (c, i) => (c ? (act[i] ? c[0] : c[1]) : '');
    const rows = rowCells.map((r) => hdr.map((_, i) => val(r[i], i)));
    const foot = footCells ? hdr.map((_, i) => val(footCells[i], i)) : null;
    const keep = hdr.map((h, i) => !(act[i] && rows.every((r) => GLYPH_RE.test(r[i])) && (!foot || GLYPH_RE.test(foot[i]))));
    const pick = (r) => r.filter((_, i) => keep[i]);
    const out = {
      root,
      headers: pick(hdr).map((h, i) => h || 'Column ' + (i + 1)),
      rows: rows.map(pick).filter((r) => r.some((v) => v !== '')),
      footer: null,
    };
    if (foot) { const f = pick(foot); if (f.some((v) => v !== '')) out.footer = f; }
    return out;
  }

  // sap.m.Table: header cells carry labels, demoted columns move into popin sub-rows.
  function readSapM(table) {
    const ths = [...table.querySelectorAll('thead tr.sapMListTblHeader th.sapMListTblHeaderCell')].filter(visible);
    const headers = ths.map(headerText);
    const pad = (cells) => { while (cells.length < ths.length) cells.push(['', '']); return cells; };
    const popin = [];
    const rows = [];
    for (const tr of table.querySelectorAll('tbody tr.sapMListTblRow')) {
      if (!visible(tr) || tr.matches('.sapMGHLI')) continue;
      const cells = pad(kids(tr, 'td.sapMListTblCell').map(cellValue));
      const extra = new Map();
      const sub = tr.nextElementSibling;
      if (sub && sub.matches('tr.sapMListTblSubRow')) {
        sub.querySelectorAll('.sapMListTblSubCntRow').forEach((r, i) => {
          const label = text(r.querySelector('.sapMListTblSubCntHdr'), { header: true }) || 'Popin ' + (i + 1);
          if (!popin.includes(label)) popin.push(label);
          extra.set(label, cellValue(r.querySelector('.sapMListTblSubCntVal') || r));
        });
      }
      rows.push({ cells, extra });
    }
    const all = rows.map((r) => r.cells.concat(popin.map((l) => r.extra.get(l) || ['', ''])));
    const ft = table.querySelector('tfoot tr.sapMListTblFooter');
    const foot = visible(ft) ? pad(kids(ft, 'td.sapMListTblFooterCell').map(cellValue)) : null;
    return finish(table, headers.concat(popin), all, foot);
  }

  // Anything else: ARIA grids (sap.ui.table, Kendo, AG Grid, ...) and plain HTML tables.
  // Grids that split a row across fixed and scrolling tables are merged on their row index.
  function readGeneric(root) {
    const rowOf = (c) => c.closest('tr, [role="row"]') || root;
    let groups = [];
    const hc = [...root.querySelectorAll('[role="columnheader"]')].filter(visible);
    if (hc.length) {
      const m = new Map();
      hc.forEach((c) => { const k = rowOf(c); if (!m.has(k)) m.set(k, []); m.get(k).push(c); });
      groups = [...m.values()];
    } else {
      let trs = [...root.querySelectorAll('thead tr')].filter(visible);
      if (!trs.length) trs = [...root.querySelectorAll('tr')].filter((tr) => visible(tr) && kids(tr, 'th').length && !kids(tr, 'td').length);
      groups = trs.map((tr) => kids(tr, 'th, td'));
    }
    groups = groups.map((g) => g.filter((c) => span(c) === 1)).filter((g) => g.length);

    let body = [...root.querySelectorAll('[role="row"]')]
      .filter((tr) => visible(tr) && !tr.closest('thead, tfoot') && !kids(tr, '[role="columnheader"]').length)
      .map((tr) => ({ tr, cells: kids(tr, CELL_SEL) }))
      .filter((r) => r.cells.some((c) => !c.matches('th')));
    if (!body.length) {
      body = [...root.querySelectorAll('tr')]
        .filter((tr) => visible(tr) && !tr.closest('thead, tfoot') && kids(tr, 'td').length)
        .map((tr) => ({ tr, cells: kids(tr, 'td, th') }));
    }

    const keyOf = (tr) => { for (const k of ROW_KEYS) { const v = tr.getAttribute(k); if (v) return k + '=' + v; } return ''; };
    const merged = [];
    const seen = new Map();
    for (const r of body) {
      const k = keyOf(r.tr);
      if (k && seen.has(k)) { seen.get(k).push(...r.cells); continue; }
      const cells = [...r.cells];
      if (k) seen.set(k, cells);
      merged.push(cells);
    }

    const count = new Map();
    merged.forEach((c) => count.set(c.length, (count.get(c.length) || 0) + 1));
    const mode = ([...count.entries()].sort((a, b) => b[1] - a[1] || b[0] - a[0])[0] || [0])[0];
    let dataRows = merged.filter((cells) => !(cells.length < mode && cells.some((c) => span(c) > 1)));
    const hcells = groups.find((g) => g.length === mode) || groups.flat();
    // Row selectors (role=rowheader) have no column header: drop them when the header row is shorter.
    if (hcells.length && hcells.length < mode) dataRows = dataRows.map((cells) => cells.filter((c) => !c.matches('[role="rowheader"]')));
    const ft = root.querySelector('tfoot tr');
    const foot = visible(ft) ? kids(ft, 'td, th').map(cellValue) : null;
    return finish(root, hcells.map(headerText), dataRows.map((cells) => cells.map(cellValue)), foot);
  }

  // Visible, outermost table-like elements on the page, in document order. sap.m.Table wins over any wrapper.
  function roots() {
    const ok = (el) => visible(el) && !el.closest(PANEL) && el.querySelector('tr, [role="row"]');
    const sap = [...document.querySelectorAll(SAPM)].filter(ok);
    const rest = [...document.querySelectorAll(ROOT_SEL)]
      .filter((el) => ok(el) && !el.matches(SAPM) && !sap.some((s) => s.contains(el) || el.contains(s)));
    const outer = rest.filter((el) => !rest.some((o) => o !== el && o.contains(el)));
    return [...sap, ...outer].sort((a, b) => (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
  }

  /* ================= actions ================= */

  function scan() {
    const at = new Date().toISOString();
    return roots()
      .map((root) => (root.matches(SAPM) ? readSapM(root) : readGeneric(root)))
      .filter((d) => d.headers.length >= 2 && d.rows.length)
      .sort((a, b) => b.rows.length - a.rows.length || b.headers.length - a.headers.length)
      .map((d) => Object.assign(d, {
        at,
        label: d.rows.length + ' rows x ' + d.headers.length + ' cols: ' + d.headers.slice(0, 3).join(', ') + (d.headers.length > 3 ? ', ...' : ''),
      }));
  }

  const NONE = 'No data table found on this page. Open the ETC page with the table on screen.';

  function extract(i = 0) {
    const all = scan();
    if (!all.length) return { ok: false, error: NONE };
    return Object.assign({ ok: true, all }, all[Math.min(i, all.length - 1)]);
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

  window.ETC = { scan, extract, roots, toCSV, toTSV, toJSON, findTable: () => roots()[0] || null };

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
#etc-panel select { font: inherit; font-size: 12px; width: 100%; box-sizing: border-box; margin: 2px 0 6px; padding: 5px 6px;
  border: 1px solid #dadce0; border-radius: 6px; background: #fff; color: #1f1f1f; }
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
    const pick = el('select', { id: 'etc-pick', hidden: '' });
    const log = el('div', { class: 'log' }, 'Click Extract to read the table on this page.');
    const wrap = el('div', { class: 'wrap', hidden: '' });
    const row = el('div', { class: 'row' });
    row.append(extractBtn, csvBtn, jsonBtn, excelBtn);
    panel.append(el('h1', {}, 'ETC Hours Extractor'), el('div', { class: 'sub' }, 'Table extractor · userscript v2.1.0'), row, pick, log, wrap);
    document.documentElement.append(style, fab, panel);

    let all = [];
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

    function show(d) {
      data = d;
      [csvBtn, jsonBtn, excelBtn].forEach((b) => { b.disabled = !d; });
      if (!d) { wrap.hidden = true; return; }
      say('Extracted ' + d.rows.length + ' rows x ' + d.headers.length + ' cols' + (d.footer ? ' + totals' : '') + '.');
      preview(d);
    }

    extractBtn.onclick = () => {
      all = scan();
      pick.replaceChildren(...all.map((d, i) => el('option', { value: String(i) }, d.label)));
      pick.hidden = all.length < 2;
      show(all[0] || null);
      if (!all.length) say(NONE);
    };
    pick.onchange = () => show(all[Number(pick.value)] || null);
    csvBtn.onclick = () => { download(toCSV(data), 'etc-table-' + stamp() + '.csv', 'text/csv;charset=utf-8;'); say('CSV downloaded.'); };
    jsonBtn.onclick = () => { download(toJSON(data), 'etc-table-' + stamp() + '.json', 'application/json;charset=utf-8;'); say('JSON downloaded.'); };
    excelBtn.onclick = async () => {
      try { await navigator.clipboard.writeText(toTSV(data)); say('Copied. In Excel select A1, Ctrl+V.'); }
      catch { say('Clipboard access denied.'); }
    };

    const gate = () => { fab.hidden = panel.hidden && !roots().length; };
    gate();
    setInterval(gate, 2000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', buildPanel);
  else buildPanel();
})();
