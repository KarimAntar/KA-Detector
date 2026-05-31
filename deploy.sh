#!/usr/bin/env bash
#
# deploy.sh — Pull the SS-whisper voicemail API + Caddy config from GitHub and
# apply them on this (target) VPS, then restart the services.
#
# Run this ON THE OTHER VPS:
#     curl -fsSL https://raw.githubusercontent.com/KarimAntar/SS-whisper.cpp/master/deploy.sh -o deploy.sh
#     chmod +x deploy.sh
#     ./deploy.sh
#
# Or, if you already cloned the repo:
#     ./deploy.sh
#
# It is safe to re-run: every file it overwrites is backed up first to a
# timestamped folder, the live Python venv / call-recording data is preserved,
# and the Caddy config is validated before reload.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration (override by exporting before running, e.g. WORKSPACE=/opt/ss)
# ----------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/KarimAntar/SS-whisper.cpp.git}"
BRANCH="${BRANCH:-master}"

WORKSPACE="${WORKSPACE:-/home/ubuntu/.openclaw/workspace}"
API_DIR="${API_DIR:-$WORKSPACE/voicemail_api}"
CADDY_ROOT="${CADDY_ROOT:-/usr/share/caddy}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

# Where to clone/pull the repo to.
CLONE_DIR="${CLONE_DIR:-$WORKSPACE/ss-deploy-repo}"

# Services to restart (in order).
SERVICES=(whisper-server.service voicemail-api.service)

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-$HOME/ss-deploy-backups/$TS}"

# ----------------------------------------------------------------------------
log()  { printf '\033[1;32m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

# sudo wrapper (no-op if already root)
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi

backup() {
  # backup <path> — copy an existing file/dir into the timestamped backup dir
  local src="$1"
  if [[ -e "$src" ]]; then
    mkdir -p "$BACKUP_DIR$(dirname "$src")"
    $SUDO cp -a "$src" "$BACKUP_DIR$(dirname "$src")/" 2>/dev/null \
      || cp -a "$src" "$BACKUP_DIR$(dirname "$src")/" 2>/dev/null || true
    log "backed up $src"
  fi
}

# ----------------------------------------------------------------------------
log "Target VPS deploy starting (backups -> $BACKUP_DIR)"
mkdir -p "$BACKUP_DIR"

# 1) Get the repo --------------------------------------------------------------
if [[ -d "$CLONE_DIR/.git" ]]; then
  log "Updating existing clone at $CLONE_DIR"
  git -C "$CLONE_DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$CLONE_DIR" checkout -q "$BRANCH"
  git -C "$CLONE_DIR" reset --hard "origin/$BRANCH"
else
  log "Cloning $REPO_URL -> $CLONE_DIR"
  mkdir -p "$(dirname "$CLONE_DIR")"
  git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$CLONE_DIR"
fi

SRC="$CLONE_DIR"

# 2) Voicemail API code --------------------------------------------------------
# Replace ONLY the code files. The .venv, work/ (recordings) and backups/ on the
# target are intentionally preserved.
log "Updating voicemail API code in $API_DIR"
mkdir -p "$API_DIR"
for f in server.py client.py run.sh README.md requirements.txt; do
  if [[ -f "$SRC/voicemail_api/$f" ]]; then
    backup "$API_DIR/$f"
    install -m "$( [[ $f == run.sh ]] && echo 755 || echo 644 )" \
      "$SRC/voicemail_api/$f" "$API_DIR/$f"
  fi
done

# Create the venv only if it does not already exist (never rebuild a live one).
if [[ ! -d "$API_DIR/.venv" ]]; then
  warn "No venv at $API_DIR/.venv — creating one and installing requirements"
  python3 -m venv "$API_DIR/.venv"
  "$API_DIR/.venv/bin/pip" install --upgrade pip
  "$API_DIR/.venv/bin/pip" install -r "$API_DIR/requirements.txt" || \
    warn "pip install reported errors — review requirements.txt (CUDA pkgs may not apply)"
else
  log "Existing venv preserved (run pip install -r requirements.txt manually if deps changed)"
fi

# 3) Caddy: public files + Caddyfile ------------------------------------------
log "Updating Caddy site root $CADDY_ROOT"
$SUDO mkdir -p "$CADDY_ROOT"
backup "$CADDY_ROOT"
# Sync web assets. --delete is deliberately NOT used so any large local backups
# or extra assets on the target are left untouched.
$SUDO rsync -a "$SRC/caddy/public/" "$CADDY_ROOT/"

log "Updating $CADDYFILE"
$SUDO mkdir -p "$(dirname "$CADDYFILE")"
backup "$CADDYFILE"
$SUDO install -m 644 "$SRC/caddy/Caddyfile" "$CADDYFILE"

# Validate before we touch the running server.
if command -v caddy >/dev/null 2>&1; then
  if $SUDO caddy validate --config "$CADDYFILE" --adapter caddyfile; then
    log "Caddyfile validated OK"
  else
    err "Caddyfile validation FAILED — restoring previous Caddyfile and aborting Caddy reload"
    $SUDO cp -a "$BACKUP_DIR$CADDYFILE" "$CADDYFILE"
    CADDY_BAD=1
  fi
fi

# 4) systemd units -------------------------------------------------------------
log "Installing systemd units"
for unit in "$SRC"/systemd/*.service; do
  name="$(basename "$unit")"
  backup "$SYSTEMD_DIR/$name"
  $SUDO install -m 644 "$unit" "$SYSTEMD_DIR/$name"
done
$SUDO systemctl daemon-reload

# 5) Restart services ----------------------------------------------------------
if command -v caddy >/dev/null 2>&1 && [[ -z "${CADDY_BAD:-}" ]]; then
  log "Reloading Caddy"
  $SUDO systemctl reload caddy 2>/dev/null || $SUDO systemctl restart caddy || warn "caddy reload/restart failed"
fi

# Warn if whisper.cpp binary/model are missing (this script does NOT build them).
if [[ ! -x "$WORKSPACE/whisper.cpp/build/bin/whisper-server" ]]; then
  warn "whisper-server binary not found under $WORKSPACE/whisper.cpp/build/bin — build whisper.cpp on this VPS or the API will not transcribe."
fi

for svc in "${SERVICES[@]}"; do
  if [[ -f "$SYSTEMD_DIR/$svc" ]]; then
    log "Enabling + restarting $svc"
    $SUDO systemctl enable "$svc" >/dev/null 2>&1 || true
    $SUDO systemctl restart "$svc" || warn "failed to restart $svc"
  fi
done

# 6) Status --------------------------------------------------------------------
echo
log "Service status:"
for svc in caddy.service "${SERVICES[@]}"; do
  state="$($SUDO systemctl is-active "$svc" 2>/dev/null || echo unknown)"
  printf '   %-26s %s\n' "$svc" "$state"
done

echo
log "Done. Backups of everything replaced are in: $BACKUP_DIR"
[[ -n "${CADDY_BAD:-}" ]] && err "NOTE: Caddyfile from repo did not validate — kept the old one. Fix and re-run."
exit 0
