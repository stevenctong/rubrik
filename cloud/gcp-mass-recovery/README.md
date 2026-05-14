# RSC GCP Mass Recovery

A single-page tool that wraps the RSC web UI's GCP recovery flow to support **mass / multi-VM recovery** — something the official RSC UI doesn't currently allow.

---

## Features

- Drop-in SA JSON authentication (no separate URL prompt)
- Inventory page with column filters, sort, resize, and reorder
- Multi-select VMs from inventory
- Snapshot point: Latest / Before / After \<date+time\> per VM (filtered to Primary-only snapshots)
- All times in Central Time (CT) with DST handling
- Searchable single-select dropdowns for project, region, zone, network, subnet, machine type
- Per-VM customization: target instance name (auto-suffixed with snapshot timestamp), machine type (compatibility-filtered per VM)
- Three-step review flow with snapshot point summary
- Live polling of recovery events (status, timeline, error messages, metadata)
- Recovery Events viewer with session/history modes and aggregate status tiles

---

## RSC Service Account JSON Format

```json
{
  "client_id": "client|...",
  "client_secret": "...",
  "name": "...",
  "access_token_uri": "https://YOUR-ACCOUNT.my.rubrik.com/api/client_token"
}
```

- The `access_token_uri` is the canonical source for the RSC URL — the app derives the GraphQL endpoint by stripping `/api/client_token`
- Authentication uses `grant_type: client_credentials` per the RSC API documentation

---

There are **two ways to run it**, and both work from the same `rsc_gcp_mass_recovery.html` file:

1. **Quick — browser + Python web server** (no install, ~30 seconds to get going)
2. **Polished — native Electron app** (one-time `npm install`, looks/feels like a desktop app)

Pick whichever fits.

---

## Option 1: Run in a browser (Python web server)

### Why a web server at all?

Browsers block direct API calls from a local `file://` HTML page for security reasons. Hosting the file behind a local HTTP server (anything serving `http://localhost`) sidesteps that block.

Python 3 ships with a built-in server you can launch in one command — no `pip install`, nothing to download.

### Steps

```bash
cd path/to/rsc-gcp-recovery
python3 -m http.server 8080
```

Then open in your browser:

```
http://localhost:8080/rsc_gcp_mass_recovery.html
```

### Heads up: CORS

The browser will block calls to `*.rubrik.com` because of CORS. Two ways around it:

**A. Launch a sandboxed Chrome with CORS disabled** (recommended for testing — keeps your normal browser untouched):

```bash
# macOS
open -na "Google Chrome" --args --user-data-dir=/tmp/rsc-chrome --disable-web-security

# Windows
"C:\Program Files\Google\Chrome\Application\chrome.exe" --user-data-dir=C:\temp\rsc-chrome --disable-web-security

# Linux
google-chrome --user-data-dir=/tmp/rsc-chrome --disable-web-security
```

Then visit `http://localhost:8080/rsc_gcp_mass_recovery.html` in that Chrome window.

**B. Use a CORS-disabling browser extension** (one-click install, but applies to your main browser — be careful).

### What `python3 -m http.server` uses

That command uses **only Python 3's standard library** (`http.server` is a built-in module). No third-party packages, no `pip install`, no requirements file. Python 3 itself comes with macOS, most Linux distros, and is a one-click install on Windows from [python.org](https://python.org).

If you don't have Python, equivalents include `npx http-server` or `npx serve` (downloads a small Node package on first run).

---

## Option 2: Run as a native Electron app

### Why Electron?

Electron wraps the same HTML in a native desktop shell. HTTP requests come from Node.js (not the browser), so there are **no CORS restrictions** — it just works out of the box. You also get a native window, dock icon, and can package it as a `.dmg` / `.exe` / `.AppImage` to ship to colleagues.

### First-time setup

You'll need Node.js installed ([nodejs.org](https://nodejs.org), use the LTS installer).

```bash
cd path/to/rsc-gcp-recovery
npm install
```

The `npm install` step pulls down Electron (~150MB) and a build tool. Only runs once.

### Run the app

```bash
npm start
```

Native window opens with the recovery UI. Drop your RSC Service Account `.json` to begin.

While running, **Cmd+R / Ctrl+R reloads `rsc_gcp_mass_recovery.html`** from disk — handy for iterating on changes without restarting.

### Dev mode (auto-opens DevTools)

```bash
npm run dev
```

### Build distributable installers

To share with colleagues who don't have Node.js installed:

```bash
npm run build:mac     # macOS .dmg + .zip
npm run build:win     # Windows .exe (installer + portable)
npm run build:linux   # Linux AppImage + .deb
```

Output goes to `dist/`. Recipients just double-click — no setup on their end.

---

## Project Structure

```
rsc-gcp-recovery/
├── rsc_gcp_mass_recovery.html   # Entire UI (single-file)
├── main.js                       # Electron main process — window + HTTP proxy via IPC
├── preload.js                    # Bridges IPC to renderer via contextBridge
├── package.json                  # Electron + electron-builder config
└── README.md
```

### How the dual-mode HTML works

The HTML's `rscFetch()` helper checks at runtime:

- **In Electron** → routes HTTP calls through the Node-side IPC bridge (no CORS)
- **In a browser** → falls back to standard `fetch()` (relies on CORS being disabled)

So the same file works in both modes with no code changes.

When running in a browser, you'll see a banner with CORS workaround instructions if requests get blocked.

---

## Editing / Iteration

No build step for development. Edit any file directly and reload:

- **UI / app logic** → edit `rsc_gcp_mass_recovery.html`
  - Electron: `Cmd+R` / `Ctrl+R` to reload in the running window
  - Browser: refresh the tab
- **HTTP proxy / native features** → edit `main.js` (Electron only) and restart with `npm start`
- **IPC API surface** → edit `preload.js` (Electron only) + add matching `ipcMain.handle()` in `main.js`

Claude Code (or any editor) can modify all these files freely.

---

## License

MIT
