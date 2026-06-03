# KA Detector API — whisper.cpp / faster-whisper + Caddy

Self-hosted, real-time **voicemail / DNC detection** API. It transcribes live call
audio (e.g. from a ReadyMode browser tab over WebSocket) and flags voicemail
greetings, do-not-call phrases, and dead air — fronted by **Caddy** (auto-HTTPS)
with a small static site and an interactive **`ka`** control panel.

> ⚠️ **Private repo.** `systemd/voicemail-api.service` contains real service
> secrets (API key, basic-auth, Resend key). Keep this repository private.

---

## Layout

```
caddy/
  Caddyfile                  # live /etc/caddy/Caddyfile (reverse proxy + static)
  public/                    # served at /usr/share/caddy (ka.html, login, assets)
systemd/
  voicemail-api.service      # FastAPI/uvicorn unit (the API)
  whisper-server.service     # whisper.cpp HTTP inference server unit
voicemail_api/
  server.py                  # the API (transcription + detection + WS + admin + auth)
  run.sh                     # launcher (activates .venv, runs uvicorn :8808)
  requirements.txt           # slim pinned runtime deps
config/ka-whisper/
  phrases.txt                # voicemail phrases  (seeded to /etc/ka-whisper)
  dnc.txt                    # do-not-call phrases
setup.sh                     # ONE-SHOT fresh-VPS install (everything, incl. ka shortcut)
deploy.sh                    # update an existing install (code/config/units/restart)
ka-ctl.sh                    # the 'ka' control panel (menu)
ka-migrate.sh                # migrate an OLD install to the new ka-* paths
```

Not committed (built/fetched on the box): the Python `.venv`, the whisper.cpp
build + models, `voicemail_api/work/`, and backups.

## Paths & names

| Thing            | Location                              |
|------------------|---------------------------------------|
| Workspace        | `~/.ka/workspace` (whisper.cpp + venv + API code) |
| Config + state   | `/etc/ka-whisper/` (phrases, dnc, engine, model, workers) |
| Repo checkout    | `~/KA-whisper.cpp`                     |
| Control panel    | `ka` (symlink → `ka-ctl.sh`)          |
| API              | `:8808` · whisper-server `127.0.0.1:9305` |

---

## Fresh VPS — one command does everything

```bash
git clone https://<TOKEN>@github.com/KarimAntar/KA-Detector.git ~/KA-whisper.cpp
cd ~/KA-whisper.cpp
WORKSPACE=$HOME/.ka/workspace ./setup.sh        # on a 1GB box add: JOBS=1
```

`setup.sh` installs apt packages + Caddy, builds **whisper.cpp**, downloads the
model, creates the venv + installs requirements, seeds `/etc/ka-whisper`, installs
the systemd units, **installs the `ka` shortcut**, then starts + health-checks
everything. No manual steps after it finishes — just run `ka`.

Useful overrides: `WHISPER_MODEL` (default `tiny`), `SERVICE_USER`, `INSTALL_CADDY=0`,
`JOBS`, `WHISPER_COMMIT`.

---

## The `ka` control panel

Run `ka` from anywhere:

```
╔══════════════════════════════════════════════╗
║        KA Detector  ·  control panel          ║
╚══════════════════════════════════════════════╝
   1) Status + health check
   2) Switch model            (engine-aware: ggml or faster-whisper list)
   3) Switch transcription engine   (whisper.cpp / faster-whisper)
   4) Set uvicorn workers     (recommends from cores/RAM/engine)
   5) Restart services
   6) Check repo for updates  (pull + redeploy)
   7) Redeploy from repo
   8) Update / reload Caddy
   9) View logs
  10) Edit phrases.txt / dnc.txt
  11) Reinstall services
  12) Uninstall services
   0) Quit
```

- `ka` — open the menu
- `ka -update` — `git pull` the latest repo + relaunch
- `ka -h` — help

Choices for model / engine / workers persist in `/etc/ka-whisper/` so they
survive restarts and redeploys.

---

## Transcription engines

Selectable behind the unchanged `/ws/transcribe` WebSocket (the ReadyMode client
never changes). Switch via `ka` → option 3.

| Engine | What it is | When |
|---|---|---|
| **whisper.cpp** (default) | lightweight C++; model lives in `whisper-server` | low overhead, simple |
| **faster-whisper** | CTranslate2 int8, in-process resident model + Silero VAD (WhisperLive's engine) | **lower latency** for live calls |

faster-whisper loads **one model copy per uvicorn worker**, so size workers to RAM
(option 4 recommends a value). It auto-falls back to whisper.cpp on any error.
Check the active engine: `curl -s 127.0.0.1:8808/health`.

**Models** — whisper.cpp (ggml): `tiny`, `tiny.en`, `base.en`, `small.en`, …
faster-whisper: `tiny.en`, `base.en`, `small.en`, `distil-small.en`, `distil-large-v3`.

---

## Update an existing install

```bash
ka -update          # pull repo + relaunch the panel
ka                  # then option 7 (Redeploy) to apply API/Caddy/unit changes
```

or directly:

```bash
cd ~/KA-whisper.cpp
git pull origin master
WORKSPACE=$HOME/.ka/workspace ./deploy.sh
```

`deploy.sh` backs up everything it overwrites to `~/ka-deploy-backups/<ts>/`,
rewrites the units for this host (workspace path, `User=`, model, engine, workers),
validates the Caddyfile before reload, and health-checks the API + WebSocket. A
clean run ends with `✅`.

> A shell script can't upgrade itself mid-run — if you changed `deploy.sh`/`ka-ctl.sh`
> itself, run the update **twice** (first run swaps the file, second run uses it).

---

## Migrating an OLD install (ss-* → ka-*)

For a box still on the old layout (`/etc/ss-whisper`, `~/.openclaw/workspace`,
`~/SS-whisper.cpp`):

```bash
cd ~/SS-whisper.cpp
git pull origin master
./ka-migrate.sh
```

It stops the services, moves the config + workspace (keeping the whisper.cpp build
and models — no rebuild), **recreates the venv** at the new path (venvs can't be
moved), redeploys to the new paths, reinstalls faster-whisper if it was active, and
re-points the `ka` shortcut. Idempotent and backed up.

---

## Service map (Caddyfile)

| Host                 | Backend |
|----------------------|---------|
| `vm.karims.dev`      | static `/usr/share/caddy` + `/auth /admin /book-demo` → :8808 |
| `ss.karims.dev`      | API → 127.0.0.1:8808 (incl. `/ws/transcribe`) |
| `agent.karims.dev`   | → 127.0.0.1:18789 |
| `9router.karims.dev` | → 127.0.0.1:20128 |
| `n8n.karims.dev`     | → 127.0.0.1:5678 |

HTML pages are served with `no-cache` headers so a deploy is never masked by a
stale browser cache.

---

## Troubleshooting

```bash
systemctl is-active caddy whisper-server.service voicemail-api.service
curl -s 127.0.0.1:8808/health                       # engine + fw_loaded
curl -s -o /dev/null -w '%{http_code}\n' 127.0.0.1:8808/admin/phrases   # 200/401 healthy
sudo journalctl -u voicemail-api.service -n 40 --no-pager
```

- **`status=217/USER`** — unit `User=` doesn't exist here. `deploy.sh` rewrites it;
  re-run deploy, or `sudo sed -i 's/^User=.*/User='"$USER"'/' /etc/systemd/system/*.service`.
- **API shows HTTP 000 right after restart** — uvicorn binds a second after systemd
  reports `active`; the panel's health check polls ~10s. Re-check.
- **`/admin/*` returns 502 behind Caddy** — the API on :8808 is down; check its journal.
- **WebSocket won't connect** — ensure `uvicorn[standard]` (provides `websockets`) is
  installed; `deploy.sh` re-syncs requirements every run.
- **Page/data looks stale** — hard-reload once; HTML now ships `no-cache`.
- **faster-whisper not active** — first start downloads the model (slow once); confirm
  with `/health` `fw_loaded:true`; missing dep → it falls back to whisper.cpp.

## Security

Secrets live in `systemd/voicemail-api.service` (kept private). The API accepts an
`X-API-Key`/Bearer key or basic-auth; the static admin uses a signed session cookie
(`ka_token`). Rotate the API key + Resend key if they ever leak.
