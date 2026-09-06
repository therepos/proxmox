# Browser extensions

| File | What | Install |
|---|---|---|
| `nlmm.user.js` | NotebookLM bulk delete, userscript | Open the [raw link](https://raw.githubusercontent.com/therepos/proxmox/main/apps/ext/nlmm.user.js) in a browser with Tampermonkey or Violentmonkey, click Install. iPad: Userscripts app. |
| `ext-nlmm.zip` | Same tool as an unpacked Chrome extension | Unzip, `chrome://extensions`, Developer mode, Load unpacked. |
| `ext-eyETC.zip` | Chrome extension | Unzip, Load unpacked. |
| `ext-myhub.zip` | Chrome extension | Unzip, Load unpacked. |

## NotebookLM bulk delete (userscript)

1. Go to https://notebooklm.google.com/ and stay on the notebook **list**.
2. Click the **NLM** button bottom-right, then **Scan notebooks**.
3. Type `DELETE`, click **Delete all**. **Stop** ends after the current one.
4. Keep the tab open and in the foreground.

Deletion is permanent. Failed notebooks are retried 3 times, then skipped and listed.
Updates: bump `@version` in the file and push to `main`; managers pull it from the raw URL.
