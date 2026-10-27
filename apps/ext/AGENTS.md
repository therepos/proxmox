# apps/ext conventions

Browser tools for web apps with no API. Preferred form is a userscript, one file per tool.
`myhub/` is an unpacked Edge/Chrome extension (manifest, content.js, popup) for users without a userscript
manager; `ext-eyETC.zip` is a legacy zip. Do not add new extensions unless a userscript cannot do the job.

## Extension releases (myhub)

- Source of truth is `apps/ext/myhub/`. Bump `version` in `manifest.json` on every change.
- `.github/workflows/ci-myhub.yml` runs on push to main and publishes a release tagged `myhub-v<version>`
  with `ext-myhub.zip` (the extension) and `myhub-setup.zip` (the setup cmd). An already-released version
  is skipped, so a change without a bump never ships.
- `myhub-setup.cmd` (same pattern as the excelUI setup cmd) finds the latest `myhub-v*` release, downloads
  the zip into `%LOCALAPPDATA%\\myhub-ext` and overwrites it. Edge loads the extension unpacked from that
  folder once; after an update the popup's "Reload extension" link re-reads it. The popup also checks the
  releases API (at most every 6 hours) and announces a newer version.

## Userscript rules

- File: `<tool>.user.js`. Standalone. No README, no shared modules. Install and use steps live in the file.
- Header order: `@name`, `@namespace https://github.com/therepos/proxmox`, `@version`, `@description`,
  `@author therepos`, `@match` per host, `@run-at document-idle`, `@noframes`, `@grant none`,
  `@updateURL` and `@downloadURL` pointing at `raw.githubusercontent.com/therepos/proxmox/main/apps/ext/<tool>.user.js`.
- After the header, one comment block with three sections: Install, Use, Notes. Numbered steps, concise.
- Bump `@version` on every change. Managers only update when the version rises.
- Structure inside the IIFE, in this order: page helpers, job runner, actions, in-page panel.
- UI is drawn into the page. A fixed floating button bottom-right (`#<prefix>-fab`) toggles a panel
  (`#<prefix>-panel`). No manager menu commands, they do not exist on iPad.
- Destructive actions: scan and list first, require typing DELETE, provide Stop, report skipped items.
- Never use `innerHTML`. Google pages enforce Trusted Types. Use `replaceChildren()`, `textContent`, `append()`.
- Never keep element references across a re-render. Re-query each iteration.
- Retry with back-off, then skip. One failure must not abort the run.
- Exclude the panel from page scans (`el.closest('#<prefix>-panel')`).
- Prefix ids and classes with the tool's short name to avoid clashing with page CSS.
- Expose the helper API on `window.<PREFIX>` for console debugging.

## Test before commit

`node --check <tool>.user.js`, then `node apps/ext/tests/<tool>.test.js`. Each test drives the script with
Playwright against `apps/ext/tests/<tool>-mock.html`, a page that mimics the target markup. When the site
changes (new wizard page, renamed step, new question, new table), update the mock first so the test
reproduces the live behaviour, then fix the script until it is green. Keep the mock faithful: the wizard
mock carries the left step column because that is what broke page detection on the live site.
`myhub.test.js` also loads `apps/ext/myhub/` as an extension and runs the popup and content script against
the mock, including a tab opened before the extension loaded; the GitHub releases API is stubbed. Live site cannot be tested here, it needs the
user's login; after a MyHub UI change run once with Dry run and read the log.

Keep `myhub/content.js` logic in step with `myhub.user.js`; both carry the same CONFIG (answers and the
intake questions allowed a Yes).

## Reference

`nlmm.user.js` is the template. Copy its skeleton for a new tool.
