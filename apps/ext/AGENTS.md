# apps/ext conventions

Browser tools for web apps with no API. Preferred form is a userscript, one file per tool.
Zips are legacy unpacked Chrome extensions. Do not add new zips unless a userscript cannot do the job.

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

`node --check <tool>.user.js`, then a Playwright run against a mock HTML page that mimics the
target markup (rows, menu, dialog). Live site cannot be tested here, it needs the user's login.

## Reference

`nlmm.user.js` is the template. Copy its skeleton for a new tool.
