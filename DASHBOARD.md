# ModelMatrix web dashboard

The web dashboard is the full-screen view of ModelMatrix. The controller bundled in `ModelMatrix.app` serves it at:

```text
http://localhost:7700
```

Nothing is downloaded at runtime: the page, fonts and charts are bundled, and every request stays on your Mac.

## Opening it

- Menu bar: the compass button in the panel header, or **Usage → Open Web Dashboard**.
- Browser: type `localhost:7700`. Bookmark it or install it as a web app from your browser's menu.
- Terminal: `open http://localhost:7700`

If the page says the controller is unreachable, start ModelMatrix from Applications. The controller is a login item registered by the app.

## Pages

| Page | Contents |
|---|---|
| **Overview** | KPI strip; live feed (in-flight requests highlighted, then the latest completed ones with model, host, client, t/s, tokens, TTFT and duration); fleet cards for this Mac and each remote host (health, GPU and memory bars, temperature and power when available, loaded models, last-hour requests, t/s and TTFT); eight KPI tiles and four wide tiles; server, tier and time filters; requests and token volume chart; local vs cloud chart by tier or server; Export PDF |
| **Models & Servers** | Profile table with Activate, Start, Stop, Restart and Benchmark; Stop everything and Reopen last; New profile from a template, Edit (form or raw file), Duplicate, Delete; capture mode per profile; Remote hosts (pair link, add direct or SSH host, edit, pause or resume, refresh, install agent, update agent, remove); benchmark suites and results |
| **Clients** | Every app seen by the relay with rename, requests, tokens, average speed, favourite model, first and last seen; top clients chart |
| **Model Insights** | Model split, per-model requests, tokens, speed and TTFT; Ollama version, loaded models (with VRAM) and installed models; runtime catalog |
| **Requests & Latency** | TTFT and throughput over time with p50 / p95; searchable, filterable request log; CSV export for the current filter or everything |
| **Settings** | Theme and accent; relay URLs, retention, clear history; capture mode; controller details and doctor report; integrations; open the profiles or logs folder; open Settings, Usage, Profiles or Optimize in the menu bar app; refresh the app |
| **Optimize** (header button, or the This Mac card) | Memory breakdown, Maximum and Recommended presets, checklist of what to free, before and after results, other apps using memory with checkboxes and Select all. See [Optimize](#optimize) |

**Standard / Advanced** (top right) toggles latency percentiles, CPU meters, raw identifiers (endpoint, client process), the 1h range and the full key list in the profile editor. The chosen mode and appearance are remembered in the browser.

## Usage relay

The controller runs a metering relay on port **7701**.

| Client type | Base URL |
|---|---|
| OpenAI-compatible | `http://127.0.0.1:7701/v1` |
| Ollama-compatible | `http://127.0.0.1:7701` |

For each request the relay picks the running model named in the request's `model` field (an exact ID, a profile name, or an Ollama tag), falls back to the best ready model with the active profile winning ties, and streams the response back byte for byte. It records time, client, model, host, profile, runtime, local or cloud tier, HTTP status, prompt and completion tokens, time to first token, duration and tokens per second. **It never stores prompts or responses.**

Clients are recognised by an `X-Client-Name` or `X-Title` header when present, otherwise by User-Agent and the connecting process. Rename them in either interface.

Models with a `cloud` tag in their name (for example Ollama's `gpt-oss:120b-cloud`) are counted as cloud; everything else is local.

### Capture mode

Capture mode measures apps that call a model's own port. With it on, the controller starts the model on a private port (its usual port plus 10000) and listens on the usual port itself, relaying and metering every call. Restart the model after switching. It is off by default and is stored in the profile as `CAPTURE_MODE=1`.

### Storage and retention

Usage history is a SQLite database at `~/Library/Application Support/ModelMatrix/Controller/usage/usage.sqlite3`. Rows older than the retention period (30 days by default, 1 to 3650) are pruned automatically. **Clear history** deletes everything.

## Menu bar parity

Every dashboard feature is also in the menu bar app:

| Dashboard | Menu bar |
|---|---|
| KPIs, live feed, model split, local vs cloud, clients and rename, CSV export, retention, clear history, capture mode, Ollama | **Usage** panel (chart icon in the footer) |
| Profile create, edit, raw edit, duplicate, delete | **Profiles** panel (stack icon) |
| Activate, Start, Stop, Restart, Stop everything, Reopen last | Main panel rows and hero card |
| Benchmarks | **Benchmarks** panel |
| Remote hosts: pair, add, edit, pause, install and update agent, remove | **Remote Hosts** panel and **Settings → Remote Gateways** |
| Fleet metrics | Host sparklines and remote host sections |
| Theme, accent, doctor, integrations, folders | **Settings** |
| Optimize: presets, checklist, file cache, results, select and close other apps | **Optimize** panel (sparkles icon in the header) |

Remote hosts live in the app (their SSH tunnels and Keychain tokens belong to it). The app reports them to the controller every few seconds, which lets the dashboard show and proxy them, and the dashboard queues host actions for the app to carry out. If the app is not running, the dashboard shows remote hosts as unavailable and everything on this Mac keeps working.

The controller answers each of those reports with a status revision that moves whenever a request may have changed profile or host state: start, stop, restart, switch, profile edits, remote host actions and so on, from the dashboard, `modelmatrixctl` or any other client. When it moves, the app refreshes immediately, so the menu bar icon and counts follow changes made elsewhere within about three seconds, including the starting state while a model loads.

## Optimize

Optimize frees memory held by models and caches. Each scan reads memory the way Activity Monitor does (App, Wired, Compressed, Cached files and Free come from the kernel's VM statistics; swap and pressure from `sysctl`) and the physical footprint of every process.

| Item | Size shown | Action |
|---|---|---|
| Each loaded Ollama model | Ollama's reported size (including VRAM) | Unload (`keep_alive: 0`); Ollama reloads it on the next request |
| Each running model server started by a profile | Footprint of its whole process tree | Stop, through the same code path as **Stop**; Optimize then checks the process really exited |
| File cache | Cached files | `/usr/sbin/purge` through the standard macOS administrator password dialog; Cancel skips it |

An item is **In use** when the relay is streaming a request to it, or handled one in the last 60 seconds. In-use items are never part of a preset. **Recommended** selects unused Ollama models and model servers with no request (and no start) in the last 15 minutes. **Maximum** selects every item that is not in use, plus the file cache.

"Freed" is the larger of the drop in Memory Used and the rise in free memory, measured a second after the last action. Unloading a model frees part of its memory at once; the rest moves into the file cache, which is why Maximum ends by clearing it.

Optimize never quits apps on its own. It lists up to 12 of the biggest other apps (grouped by app bundle, with tools such as `node` shown by name). Regular apps get a checkbox, and **Select all apps that can quit** ticks every one of them; the presets never tick apps. Selected apps count toward the estimate, and **Optimize now** first asks you to confirm the list of names. The run then frees the selected models and servers, closes the apps, clears the file cache if it is ticked, and measures memory again once the apps have exited.

Closing apps is carried out by the menu bar app (`app.quit_apps` bridge command), which asks every selected app to close the way ⌘Q does and waits up to 10 seconds. Each app is reported as closed, **Still open** (usually waiting on a save dialog you can still answer), or not allowed. The menu bar app reports which running apps it can quit in its heartbeat, so the list only offers apps that will really quit. Dock apps and menu bar utilities can be selected. Rows that cannot be selected show why: *part of macOS* (Finder, the Dock), *background app* (background-only agents with no window or menu), or *command-line tool*; ModelMatrix itself is never listed. Apple's own apps in `/System/Applications` (Mail, Notes, Music...) can be selected. Without the menu bar app the rows are shown but cannot be selected. If the browser showing the dashboard is selected, it is closed last, a few seconds after the results are shown, so the run is not cut short.

## Security

- The controller listens on `127.0.0.1` only.
- Requests must carry a loopback `Host` header, which blocks DNS rebinding.
- Browser requests must be same-origin and carry an `HttpOnly`, `SameSite=Strict` session cookie issued when the page loads, which blocks cross-site requests from other tabs.
- If you set a controller token, the dashboard asks for it once and stores only the session cookie.
- Responses include a strict Content-Security-Policy (no third-party scripts, fonts or images), `X-Frame-Options: DENY` and `no-referrer`.
- Remote host tokens are kept in memory by the controller and are never returned to the browser.

## API

The dashboard uses the controller API documented in [SETUP.md](SETUP.md#controller-api-contract) plus these routes:

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/dashboard/info` | Version, controller URL, folders, whether a token is required |
| GET / POST / DELETE | `/api/dashboard/session` | Session status, sign in with token, sign out |
| GET | `/api/host/metrics` | CPU, GPU, memory, storage for this Mac |
| GET | `/api/usage/overview` | Summary, totals, recent, in-flight, models, clients, host stats, relay status |
| GET | `/api/usage/summary`, `/timeseries`, `/models`, `/clients`, `/requests`, `/live` | Individual usage queries (`range`, `tier` and `host` filters) |
| GET | `/api/usage/export.csv` | CSV export |
| GET / POST | `/api/usage/settings` | Relay status, capture state; set retention |
| POST | `/api/usage/clients/rename` | `{client_id, name}` |
| POST | `/api/usage/reset` | `{confirm: true}` |
| GET | `/api/ollama/status` | Version, installed and loaded models |
| GET | `/api/profiles/runtimes` | Runtime catalog and templates |
| GET | `/api/profiles/document?profile=` | Profile values and raw text |
| POST | `/api/profiles/save` | `{profile, values or text, original_profile?, create?}` |
| POST | `/api/profiles/duplicate`, `/api/profiles/delete`, `/api/profiles/capture` | Profile management |
| GET | `/api/optimize/plan` | Memory snapshot, items with sizes and in-use state, presets and estimates, other apps |
| POST | `/api/optimize/run` | `{items: [ids]}` or `{preset: "maximum" or "recommended"}`; unloads and stops, returns results with memory before and after |
| POST | `/api/optimize/purge` | Clears the file cache after the macOS password dialog; returns memory before and after |
| GET | `/api/hf/check?name=` | Read-only Hugging Face model check: format, versions, memory fit, recommendation, engines. Optional `context` (tokens, `16k` accepted), `format=text`, `refresh=1` to look for engines again |
| GET | `/api/hf/search?q=` | Ready-to-run (GGUF, and MLX on Apple Silicon) models matching the words, most downloaded first |
| GET | `/api/bridge/state` | Menu bar app status and remote hosts |
| POST | `/api/bridge/commands` | Queue an app action; poll `GET /api/bridge/commands/{id}` |
| GET / POST | `/api/remote/{host-id}/...` | Proxy to a remote host's agent, limited to status, metrics, doctor, usage, Ollama, start, stop, restart, switch, stop-all and benchmark routes |

## Developing the dashboard

The source is a Vite + React + TypeScript app in `Dashboard/`.

```bash
cd Dashboard
pnpm install
pnpm dev      # http://localhost:5173, API proxied to http://127.0.0.1:7700
pnpm build    # writes Dashboard/dist
```

`Scripts/embed-controller.sh` (run by `build-app.sh` and `install.sh`) builds the dashboard when Node.js is available and copies `Dashboard/dist` to `ModelMatrix.app/Contents/Resources/Dashboard`. To serve a local build from a development controller, set `MODELMATRIX_DASHBOARD_DIR=/path/to/Dashboard/dist`.
