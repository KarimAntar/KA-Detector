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
  requirements.txt   # frozen Python deps from the source VPS
  README.md          # API notes
deploy.sh            # run on the TARGET VPS to pull + apply this bundle
```

What is intentionally **not** in here: the Python `.venv`, the whisper.cpp
build + models (multi-GB), `voicemail_api/work/` call recordings, and the large
`voicemail_backup_*.tar.gz` archives.

## Service map (from Caddyfile)

| Host                | Backend                  |
|---------------------|--------------------------|
| `vm.karims.dev`     | static `/usr/share/caddy` + `/auth /admin /book-demo` → :8808 |
| `ss.karims.dev`     | voicemail API → 127.0.0.1:8808 |
| `agent.karims.dev`  | → 127.0.0.1:18789 |
| `9router.karims.dev`| → 127.0.0.1:20128 |
| `n8n.karims.dev`    | → 127.0.0.1:5678 |

The API listens on `:8808`; whisper.cpp inference server on `127.0.0.1:9305`.

## Deploy on the other VPS

```bash
curl -fsSL https://raw.githubusercontent.com/KarimAntar/SS-whisper.cpp/master/deploy.sh -o deploy.sh
chmod +x deploy.sh
./deploy.sh
```

`deploy.sh` will:

1. Clone (or hard-reset) this repo into `$WORKSPACE/ss-deploy-repo`.
2. Replace the API **code** in `voicemail_api/` — preserving the existing
   `.venv`, `work/`, and `backups/`.
3. Create a `.venv` + `pip install -r requirements.txt` **only if** none exists.
4. Sync `caddy/public/` → `/usr/share/caddy` and the `Caddyfile` → `/etc/caddy`
   (validating the Caddyfile before any reload).
5. Install the systemd units and `daemon-reload`.
6. Reload Caddy and restart `whisper-server` + `voicemail-api`.

**Everything it overwrites is backed up first** to
`~/ss-deploy-backups/<timestamp>/`, so the run is reversible.

### Paths differ on the target?

Override via env vars, e.g.:

```bash
WORKSPACE=/opt/ss CADDY_ROOT=/var/www/ss ./deploy.sh
```

### whisper.cpp

This bundle does **not** ship the whisper.cpp binary or models. The target VPS
must have whisper.cpp built at `$WORKSPACE/whisper.cpp/build/bin/whisper-server`
with a model under `whisper.cpp/models/`. `deploy.sh` warns if it is missing.

## Security note

The old credentials previously committed here have been removed from history.
Rotate any secret that was ever public (API key, basic-auth password, Resend
API key) if you have not already.
