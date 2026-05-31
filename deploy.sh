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

# The workspace path baked into the committed files (the source server). Any
# occurrence of this inside systemd units / run.sh is rewritten to $WORKSPACE on
# install, so this bundle is portable to a VPS using a different home dir.
SRC_WORKSPACE="${SRC_WORKSPACE:-/home/ubuntu/.openclaw/workspace}"

WORKSPACE="${WORKSPACE:-/home/ubuntu/.openclaw/workspace}"
API_DIR="${API_DIR:-$WORKSPACE/voicemail_api}"

# Set SKIP_SYSTEMD=1 to leave the target's existing systemd units untouched.
SKIP_SYSTEMD="${SKIP_SYSTEMD:-0}"

# The Unix user the services run as. Baked-in source value is "ubuntu"; rewritten
# to the user actually running this deploy unless overridden.
SRC_SERVICE_USER="${SRC_SERVICE_USER:-ubuntu}"
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(id -un)}}"
CADDY_ROOT="${CADDY_ROOT:-/usr/share/caddy}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

# whisper model. The unit ships referencing ggml-tiny.bin (the source server's
# model); set WHISPER_MODEL=tiny.en (etc.) to point the unit at a different one.
SRC_WHISPER_MODEL="${SRC_WHISPER_MODEL:-tiny}"
WHISPER_MODEL="${WHISPER_MODEL:-tiny}"

# Where the ss-whisper config (phrases.txt / dnc.txt) lives — server.py default.
SS_CONFIG_DIR="${SS_CONFIG_DIR:-/etc/ss-whisper}"

# PULL=0 skips the git clone/fetch and uses CLONE_DIR as-is (used by setup.sh,
# or when you've already checked the repo out and don't want a network pull).
PULL="${PULL:-1}"

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

# install_rewritten <mode> <src> <dest> — install a file, rewriting the baked-in
# source workspace path to the target $WORKSPACE first.
install_rewritten() {
  local mode="$1" src="$2" dest="$3"
  local tmp; tmp="$(mktemp)"
  # Rewrite, for this host: workspace path, systemd User=, and the whisper model.
  sed -e "s#${SRC_WORKSPACE}#${WORKSPACE}#g" \
      -e "s#^User=${SRC_SERVICE_USER}\$#User=${SERVICE_USER}#" \
      -e "s#ggml-${SRC_WHISPER_MODEL}\.bin#ggml-${WHISPER_MODEL}.bin#g" \
      "$src" > "$tmp"
  $SUDO install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

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
if [[ "$PULL" == "0" ]]; then
  log "PULL=0 — using existing checkout at $CLONE_DIR (no network pull)"
  [[ -e "$CLONE_DIR/deploy.sh" ]] || { err "PULL=0 but $CLONE_DIR has no repo content"; exit 1; }
elif [[ -d "$CLONE_DIR/.git" ]]; then
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
    install_rewritten "$( [[ $f == run.sh ]] && echo 755 || echo 644 )" \
      "$SRC/voicemail_api/$f" "$API_DIR/$f"
  fi
done

# Create the venv only if it does not already exist (never rebuild a live one).
if [[ ! -d "$API_DIR/.venv" ]]; then
  warn "No venv at $API_DIR/.venv — creating one and installing requirements"
  python3 -m venv "$API_DIR/.venv"
  "$API_DIR/.venv/bin/pip" install --upgrade pip
  "$API_DIR/.venv/bin/pip" install -r "$API_DIR/requirements.txt" || \
    warn "pip install reported errors — review requirements.txt"
else
  log "Existing venv preserved (run pip install -r requirements.txt manually if deps changed)"
fi

# 2b) ss-whisper config (phrases.txt / dnc.txt) -------------------------------
# server.py reads/writes these as the service user, so the dir must exist and be
# writable. Existing files are PRESERVED (never overwrite live admin edits) —
# only missing ones are seeded from the repo.
log "Ensuring config dir $SS_CONFIG_DIR (owner $SERVICE_USER)"
$SUDO mkdir -p "$SS_CONFIG_DIR"
$SUDO chown "$SERVICE_USER" "$SS_CONFIG_DIR" 2>/dev/null || true
for cf in phrases.txt dnc.txt; do
  if [[ -f "$SRC/config/ss-whisper/$cf" ]]; then
    if [[ -f "$SS_CONFIG_DIR/$cf" ]]; then
      log "  $SS_CONFIG_DIR/$cf exists — left untouched"
    else
      $SUDO install -m 644 -o "$SERVICE_USER" "$SRC/config/ss-whisper/$cf" "$SS_CONFIG_DIR/$cf"
      log "  seeded $SS_CONFIG_DIR/$cf"
    fi
  fi
done

# 3) Caddy: public files + Caddyfile ------------------------------------------
log "Updating Caddy site root $CADDY_ROOT"
$SUDO mkdir -p "$CADDY_ROOT"
backup "$CADDY_ROOT"
# Sync web assets. --delete is deliberately NOT used so any large local backups
# or extra assets on the target are left untouched. Falls back to cp if rsync
# is not installed.
if command -v rsync >/dev/null 2>&1; then
  $SUDO rsync -a "$SRC/caddy/public/" "$CADDY_ROOT/"
else
  warn "rsync not found — using cp"
  $SUDO cp -a "$SRC/caddy/public/." "$CADDY_ROOT/"
fi

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
if [[ "$SKIP_SYSTEMD" == "1" ]]; then
  warn "SKIP_SYSTEMD=1 — leaving existing systemd units untouched"
else
  log "Installing systemd units (workspace paths rewritten to $WORKSPACE)"
  for unit in "$SRC"/systemd/*.service; do
    name="$(basename "$unit")"
    backup "$SYSTEMD_DIR/$name"
    install_rewritten 644 "$unit" "$SYSTEMD_DIR/$name"
  done
  $SUDO systemctl daemon-reload
fi

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
  state="$(systemctl is-active "$svc" 2>/dev/null)" || true
  printf '   %-26s %s\n' "$svc" "${state:-unknown}"
done

# 7) Health check --------------------------------------------------------------
# The API requires auth on /admin/*, so a healthy backend answers 200 or 401.
# Anything else (502/000/connection refused) means it did not come up.
log "Health check: GET :8808/admin/phrases"
sleep 3
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
        -H 'Host: vm.karims.dev' http://127.0.0.1:8808/admin/phrases || echo 000)"
if [[ "$code" == "200" || "$code" == "401" ]]; then
  log "API healthy (HTTP $code)"
else
  err "API NOT healthy (HTTP $code). Check: sudo journalctl -u voicemail-api.service -n 40 --no-pager"
fi

echo
log "Done. Backups of everything replaced are in: $BACKUP_DIR"
[[ -n "${CADDY_BAD:-}" ]] && err "NOTE: Caddyfile from repo did not validate — kept the old one. Fix and re-run."
exit 0
