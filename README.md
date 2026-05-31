# SS-whisper.cpp — Voicemail API + Caddy deployment

Backup and deployment bundle for the **voicemail detection API** (FastAPI +
whisper.cpp) and the **Caddy** reverse proxy / static site that front it.

> ⚠️ **Private repo.** It contains real service secrets in
> `systemd/voicemail-api.service`. Keep this repository private.

## Layout

```
caddy/
  Caddyfile          # live /etc/caddy/Caddyfile
  public/            # live /usr/share/caddy web assets (HTML, logos, icons)
systemd/
  voicemail-api.service    # FastAPI service unit (whisper.cpp backend)
  whisper-server.service   # whisper.cpp HTTP inference server unit
voicemail_api/
  server.py          # the API
  client.py          # example client
  run.sh             # launcher (activates .venv, runs uvicorn on :8808)
  requirements.txt   # slim, pinned runtime deps (fastapi/uvicorn/httpx/...)
  README.md          # API notes
config/ss-whisper/
  phrases.txt        # voicemail-detection phrases (seeded to /etc/ss-whisper)
  dnc.txt            # do-not-call phrases
setup.sh             # FULL provision of a fresh VPS (packages, whisper.cpp, model, venv) then deploy
deploy.sh            # update/sync an EXISTING install (code, config, units, restart)
```

What is intentionally **not** in here (built/fetched by `setup.sh` instead): the
Python `.venv`, the whisper.cpp build + model (multi-GB), `voicemail_api/work/`
call recordings, and the large `voicemail_backup_*.tar.gz` archives.

## Fresh VPS — one-shot install (`setup.sh`)

`setup.sh` provisions a brand-new box to match the source server, then calls
`deploy.sh`. It installs apt packages + Caddy, clones & builds **whisper.cpp**
(CPU/Release), downloads the **`tiny`** model, creates the venv, installs
requirements, seeds `/etc/ss-whisper`, installs the systemd units, and starts
everything with a health check.

```bash
# clone the (private) repo, then:
cd ~/ss-deploy-repo
WORKSPACE=/home/$USER/.openclaw/workspace ./setup.sh
```

Useful overrides:

| Var              | Default                         | Purpose                                  |
|------------------|---------------------------------|------------------------------------------|
| `WORKSPACE`      | `/home/ubuntu/.openclaw/workspace` | parent of `voicemail_api/` + `whisper.cpp/` |
| `WHISPER_MODEL`  | `tiny`                          | model to fetch + run (`tiny.en`, `base`, …) |
| `WHISPER_COMMIT` | *(latest)*                      | pin whisper.cpp to an exact commit       |
| `SERVICE_USER`   | the user running it             | Unix user the services run as            |
| `INSTALL_CADDY`  | `1`                             | set `0` to skip installing Caddy         |
| `JOBS`           | `nproc`                         | parallel build jobs                      |

Everything is idempotent — re-running skips already-completed steps (won't
rebuild whisper.cpp, re-download the model, or recreate an existing venv).

## Service map (from Caddyfile)

| Host                | Backend                  |
|---------------------|--------------------------|
| `vm.karims.dev`     | static `/usr/share/caddy` + `/auth /admin /book-demo` → :8808 |
| `ss.karims.dev`     | voicemail API → 127.0.0.1:8808 |
| `agent.karims.dev`  | → 127.0.0.1:18789 |
| `9router.karims.dev`| → 127.0.0.1:20128 |
| `n8n.karims.dev`    | → 127.0.0.1:5678 |

The API listens on `:8808`; whisper.cpp inference server on `127.0.0.1:9305`.

## Update an existing install (`deploy.sh`)

Use this once the box is already provisioned (by `setup.sh` or by hand) and you
just want to pull the latest code/config and restart.

```bash
cd ~/ss-deploy-repo
WORKSPACE=/home/$USER/.openclaw/workspace ./deploy.sh
```

`deploy.sh` will:

1. Hard-reset this repo to the latest `master` (skip with `PULL=0`).
2. Replace the API **code** in `voicemail_api/` — preserving the existing
   `.venv`, `work/`, and `backups/`.
3. Create a `.venv` + `pip install -r requirements.txt` **only if** none exists.
4. Seed `/etc/ss-whisper/{phrases,dnc}.txt` if missing (existing files kept).
5. Sync `caddy/public/` → `/usr/share/caddy` and the `Caddyfile` → `/etc/caddy`
   (validating the Caddyfile before any reload; falls back to `cp` if no rsync).
6. Install the systemd units (rewriting workspace path, `User=`, and the model
   filename for this host) and `daemon-reload`.
7. Reload Caddy, restart `whisper-server` + `voicemail-api`, then health-check
   `:8808/admin/phrases` (expects 200/401).

**Everything it overwrites is backed up first** to
`~/ss-deploy-backups/<timestamp>/`, so the run is reversible.

### Host portability

The committed units carry the source server's paths/user/model; `deploy.sh`
rewrites them on install. Override as needed:

```bash
WORKSPACE=/opt/ss CADDY_ROOT=/var/www/ss SERVICE_USER=app WHISPER_MODEL=tiny.en ./deploy.sh
```

`SKIP_SYSTEMD=1` leaves existing units untouched.

### whisper.cpp

`deploy.sh` alone does **not** build whisper.cpp — it expects the binary at
`$WORKSPACE/whisper.cpp/build/bin/whisper-server` with the model under
`whisper.cpp/models/` (run `setup.sh` to build/fetch them) and warns if missing.

## Security note

The old credentials previously committed here have been removed from history.
Rotate any secret that was ever public (API key, basic-auth password, Resend
API key) if you have not already.
