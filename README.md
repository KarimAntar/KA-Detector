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

## What `deploy.sh` verifies

The script doesn't just restart things and hope — at the end it:

1. Clears any prior systemd failure counter (`reset-failed`) before restarting,
   so a service that previously crash-looped isn't blocked by `StartLimit`.
2. Restarts **whisper-server first, then voicemail-api** (the API depends on it),
   waiting for each to reach `active` (with one automatic `daemon-reload` + retry).
3. Polls `127.0.0.1:9305` (whisper-server) until it responds.
4. Polls `:8808/admin/phrases` until it returns **200/401** (auth-required = healthy).
5. On any failure it **prints the failing unit's journal tail automatically** and
   exits non-zero with `❌`. A clean run ends with `✅ Deploy complete`.

So if the final line is `✅`, Caddy + whisper-server + the API are all confirmed up.

## Troubleshooting

Quick triage:

```bash
systemctl is-active caddy whisper-server.service voicemail-api.service
ss -ltnp | grep -E '8808|9305' || echo "API/whisper not listening"
sudo journalctl -u voicemail-api.service -n 40 --no-pager
sudo journalctl -u whisper-server.service -n 40 --no-pager
# Does the API answer locally? (200/401 = healthy, 000 = not running, 502 = down behind Caddy)
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: vm.karims.dev' http://127.0.0.1:8808/admin/phrases
```

### `status=217/USER` / "Failed at step USER ... No such process"
The unit's `User=` is a user that doesn't exist on this box (the committed units
ship `User=ubuntu`). `deploy.sh` rewrites this to the deploying user — but if you
see it, the rewrite was skipped or the unit was hand-edited. Fix:
```bash
sudo sed -i 's/^User=.*/User='"$USER"'/' \
  /etc/systemd/system/voicemail-api.service /etc/systemd/system/whisper-server.service
sudo systemctl daemon-reload
sudo systemctl reset-failed voicemail-api.service whisper-server.service
sudo systemctl restart whisper-server.service voicemail-api.service
```
Or just re-run `deploy.sh` (it now sets `User=` correctly and `reset-failed`s first).

### The first run after a script change "didn't apply" / re-broke
A shell script **can't upgrade itself mid-run**: the first `deploy.sh` after a new
commit executes the *old* on-disk copy while resetting the repo to the new one.
**Just run `deploy.sh` once more** — the second run uses the updated script. (This
is why a fix sometimes only "takes" on the second invocation.)

### `ss.html` shows `502` on `/admin/phrases` and `/admin/dnc`
Caddy is up but the API on `127.0.0.1:8808` is down. Check
`systemctl is-active voicemail-api.service` and its journal (above). The page
itself is fine — it's the backend.

### `ss.html` says "wrong password"
Login checks the submitted password against `BASIC_AUTH_PASS` in the **running
unit** (username is ignored). See the live value:
```bash
sudo systemctl show voicemail-api.service -p Environment | tr ' ' '\n' | grep BASIC_AUTH_PASS
```
Log in with that. Note: because the secret is baked into the unit in the repo,
**every deploy resets the password to the repo value.** To keep a custom password,
use `SKIP_SYSTEMD=1` on deploys, or move secrets to an `EnvironmentFile` (below).

### Browser shows Caddy's "Your web server is working / Point your domain's
### A/AAAA records at this machine"
That's Caddy's **built-in welcome page**, served when the request matches no site
block — i.e. you hit the box by **IP** or a hostname that isn't in the Caddyfile
(common over HTTPS). Reach it via a configured host:
```bash
# confirm the real landing page is on disk + served for the right Host:
grep -c "Voicemail Detector" /usr/share/caddy/index.html
curl -s -H 'Host: vm.karims.dev' http://127.0.0.1/ | grep -o "Voicemail Detector" | head -1
```
If those match, the landing page is live — point `vm.karims.dev`'s DNS at this box.

### `auth: 000` / `curl` can't connect to `:8808`
The API isn't listening — it's crash-looping or stopped. `is-active` will say
`activating`/`failed`; read the journal for the real error (USER, missing module,
missing model).

### whisper-server won't start / API returns transcription errors
Usually a missing build or model:
```bash
ls -la "$WORKSPACE/whisper.cpp/build/bin/whisper-server"     # binary present + executable?
ls -la "$WORKSPACE/whisper.cpp/models/"*.bin                 # model present?
grep -- '-m ' /etc/systemd/system/whisper-server.service     # which model the unit expects
```
If the binary/model are missing, run `setup.sh` (builds whisper.cpp + downloads
the model). If the unit points at a model you don't have, redeploy with the right
`WHISPER_MODEL=...`.

### `sudo: rsync: command not found`
Harmless — `deploy.sh` falls back to `cp`. Install it for faster syncs if you like:
`sudo apt-get install -y rsync`.

### Caddyfile change won't load
`deploy.sh` validates before reloading and **keeps the old Caddyfile if invalid**
(you'll see `Caddyfile validation FAILED`). Validate manually:
```bash
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```
The `Unnecessary header_up X-Forwarded-Proto` lines are warnings, not errors.

### Private-repo clone/fetch fails (`Authentication failed`)
The repo is private; `deploy.sh`'s internal `git fetch` needs credentials. Either
pass a token in `REPO_URL="https://<TOKEN>@github.com/KarimAntar/SS-whisper.cpp.git"`,
or run `git config --global credential.helper store` + one manual `git pull` so the
token is cached and future runs need no `REPO_URL`.

## Rollback

Every run backs up what it replaced to `~/ss-deploy-backups/<timestamp>/`
(mirroring absolute paths). To restore, e.g. the API code + units:
```bash
B=~/ss-deploy-backups/<timestamp>
sudo cp -a "$B/etc/systemd/system/." /etc/systemd/system/
cp -a  "$B$WORKSPACE/voicemail_api/." "$WORKSPACE/voicemail_api/"
sudo cp -a "$B/etc/caddy/Caddyfile" /etc/caddy/Caddyfile
sudo systemctl daemon-reload
sudo systemctl restart caddy whisper-server.service voicemail-api.service
```

## Optional: keep secrets out of the repo (`EnvironmentFile`)

To stop deploys from resetting your password/keys, move them to a host-only file:

1. Create `/etc/voicemail-api.env` (chmod 600) with the `KEY=value` lines.
2. In `voicemail-api.service`, replace the `Environment=...` secret lines with
   `EnvironmentFile=/etc/voicemail-api.env`.
3. Commit only a `voicemail-api.env.example` with placeholders.

Deploys then never touch the real secrets. (Ask and this can be wired in.)

## Security note

The old credentials previously committed here have been removed from history.
Rotate any secret that was ever public (API key, basic-auth password, Resend
API key) if you have not already.
