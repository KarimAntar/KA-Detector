#!/usr/bin/env bash
#
# deploy.sh — Pull the KA Detector voicemail API + Caddy config from GitHub and
# apply them on this (target) VPS, then restart the services.
#
# Run this ON THE OTHER VPS:
#     curl -fsSL https://raw.githubusercontent.com/KarimAntar/KA-Detector/master/deploy.sh -o deploy.sh
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
REPO_URL="${REPO_URL:-https://github.com/KarimAntar/KA-Detector.git}"
BRANCH="${BRANCH:-master}"

# The workspace path baked into the committed files (the source server). Any
# occurrence of this inside systemd units / run.sh is rewritten to $WORKSPACE on
# install, so this bundle is portable to a VPS using a different home dir.
SRC_WORKSPACE="${SRC_WORKSPACE:-/home/ubuntu/.ka/workspace}"

WORKSPACE="${WORKSPACE:-/home/ubuntu/.ka/workspace}"
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
# Default model resolution: explicit env  >  saved choice (ka-ctl.sh switch)  >  tiny.
_SAVED_MODEL=""
[[ -f /etc/ka-whisper/whisper-model ]] && _SAVED_MODEL="$(tr -d '[:space:]' </etc/ka-whisper/whisper-model 2>/dev/null || true)"
WHISPER_MODEL="${WHISPER_MODEL:-${_SAVED_MODEL:-tiny}}"

# Transcription engine + faster-whisper model: explicit env > saved choice > default.
_SAVED_ENGINE=""
[[ -f /etc/ka-whisper/engine ]] && _SAVED_ENGINE="$(tr -d '[:space:]' </etc/ka-whisper/engine 2>/dev/null || true)"
TRANSCRIBE_ENGINE="${TRANSCRIBE_ENGINE:-${_SAVED_ENGINE:-whispercpp}}"
_SAVED_FW=""
[[ -f /etc/ka-whisper/fw-model ]] && _SAVED_FW="$(tr -d '[:space:]' </etc/ka-whisper/fw-model 2>/dev/null || true)"
FW_MODEL="${FW_MODEL:-${_SAVED_FW:-tiny.en}}"

# uvicorn workers: explicit env > saved choice (ka menu) > 2.
_SAVED_WORKERS=""
[[ -f /etc/ka-whisper/workers ]] && _SAVED_WORKERS="$(tr -dc '0-9' </etc/ka-whisper/workers 2>/dev/null || true)"
UVICORN_WORKERS="${UVICORN_WORKERS:-${_SAVED_WORKERS:-2}}"

# Where the ka-whisper config (phrases.txt / dnc.txt) lives — server.py default.
SS_CONFIG_DIR="${SS_CONFIG_DIR:-/etc/ka-whisper}"

# PULL=0 skips the git clone/fetch and uses CLONE_DIR as-is (used by setup.sh,
# or when you've already checked the repo out and don't want a network pull).
PULL="${PULL:-1}"

# Where to clone/pull the repo to.
CLONE_DIR="${CLONE_DIR:-$WORKSPACE/ka-deploy-repo}"

# Services to restart (in order).
SERVICES=(whisper-server.service voicemail-api.service)

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-$HOME/ka-deploy-backups/$TS}"

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
      -e "s#^Environment=TRANSCRIBE_ENGINE=.*#Environment=TRANSCRIBE_ENGINE=${TRANSCRIBE_ENGINE}#" \
      -e "s#^Environment=FW_MODEL=.*#Environment=FW_MODEL=${FW_MODEL}#" \
      -e "s#^Environment=UVICORN_WORKERS=.*#Environment=UVICORN_WORKERS=${UVICORN_WORKERS}#" \
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

# dump the tail of a unit's journal (used when something fails)
dump_journal() {
  local svc="$1" n="${2:-25}"
  err "---- last $n log lines for $svc ----"
  $SUDO journalctl -u "$svc" -n "$n" --no-pager 2>/dev/null | sed 's/^/    /' || true
  err "---- end $svc log ----"
}

# wait_active <svc> <timeout_s> — poll until the unit is active; return non-zero
# (and dump its journal) if it ends up failed or never becomes active in time.
wait_active() {
  local svc="$1" timeout="${2:-45}" waited=0 state
  while true; do
    state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    case "$state" in
      active)     return 0 ;;
      failed)     err "$svc entered 'failed'"; dump_journal "$svc"; return 1 ;;
    esac
    if (( waited >= timeout )); then
      err "$svc did not become active within ${timeout}s (state: ${state:-unknown})"
      dump_journal "$svc"; return 1
    fi
    sleep 2; waited=$((waited + 2))
  done
}

# restart_verify <svc> <timeout_s> — clear any prior failure counter, enable,
# restart, and wait for it to be active. On failure, retry once after a daemon-reload.
restart_verify() {
  local svc="$1" timeout="${2:-45}"
  [[ -f "$SYSTEMD_DIR/$svc" ]] || { warn "$svc not installed — skipping"; return 0; }
  log "Restarting $svc"
  $SUDO systemctl reset-failed "$svc" 2>/dev/null || true
  $SUDO systemctl enable "$svc" >/dev/null 2>&1 || true
  $SUDO systemctl restart "$svc" 2>/dev/null || true
  if wait_active "$svc" "$timeout"; then return 0; fi
  warn "$svc failed first attempt — daemon-reload + one retry"
  $SUDO systemctl daemon-reload
  $SUDO systemctl reset-failed "$svc" 2>/dev/null || true
  $SUDO systemctl restart "$svc" 2>/dev/null || true
  wait_active "$svc" "$timeout"
}

# wait_http — poll a URL until it returns one of the accepted codes (or timeout).
# Prints the final code via the global REPLY.
wait_http() {
  local url="$1" host="$2" timeout="${3:-40}" accept="${4:-200 401}" waited=0 code
  while true; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $host" "$url" 2>/dev/null || echo 000)"
    for ok in $accept; do [[ "$code" == "$ok" ]] && { REPLY="$code"; return 0; }; done
    if (( waited >= timeout )); then REPLY="$code"; return 1; fi
    sleep 2; waited=$((waited + 2))
  done
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

# Ensure the venv exists, then ALWAYS sync requirements into it. We preserve an
# existing venv (don't rebuild it), but we do (idempotently) install the pinned
# requirements every run — otherwise an existing-but-incomplete venv can be
# missing a dependency (e.g. the websockets lib uvicorn needs for /ws/*) and the
# API will silently fail to upgrade WebSocket connections. Set PIP_SYNC=0 to skip.
PIP_SYNC="${PIP_SYNC:-1}"
if [[ ! -d "$API_DIR/.venv" ]]; then
  warn "No venv at $API_DIR/.venv — creating it"
  python3 -m venv "$API_DIR/.venv"
  "$API_DIR/.venv/bin/pip" install --upgrade pip -q || true
fi
if [[ "$PIP_SYNC" == "1" && -x "$API_DIR/.venv/bin/pip" ]]; then
  log "Syncing Python requirements into venv (incl. uvicorn[standard] for WebSockets)"
  "$API_DIR/.venv/bin/pip" install -q -r "$API_DIR/requirements.txt" \
    || warn "pip install reported errors — review requirements.txt"
else
  log "PIP_SYNC=0 — skipping requirements install"
fi

# 2b) ka-whisper config (phrases.txt / dnc.txt) -------------------------------
# server.py reads/writes these as the service user, so the dir must exist and be
# writable. Existing files are PRESERVED (never overwrite live admin edits) —
# only missing ones are seeded from the repo.
log "Ensuring config dir $SS_CONFIG_DIR (owner $SERVICE_USER)"
$SUDO mkdir -p "$SS_CONFIG_DIR"
$SUDO chown "$SERVICE_USER" "$SS_CONFIG_DIR" 2>/dev/null || true
for cf in phrases.txt dnc.txt; do
  if [[ -f "$SRC/config/ka-whisper/$cf" ]]; then
    if [[ -f "$SS_CONFIG_DIR/$cf" ]]; then
      log "  $SS_CONFIG_DIR/$cf exists — left untouched"
    else
      $SUDO install -m 644 -o "$SERVICE_USER" "$SRC/config/ka-whisper/$cf" "$SS_CONFIG_DIR/$cf"
      log "  seeded $SS_CONFIG_DIR/$cf"
    fi
  fi
done

# 2b) Control panel: make ka-ctl.sh executable + install the 'ka' shortcut -----
if [[ -f "$SRC/ka-ctl.sh" ]]; then
  chmod +x "$SRC/ka-ctl.sh" 2>/dev/null || true
  $SUDO ln -sf "$SRC/ka-ctl.sh" /usr/local/bin/ka
  log "Installed control panel shortcut: 'ka' -> $SRC/ka-ctl.sh"
fi

# 2c) Remove legacy ss-* / old-name artifacts so old names don't linger --------
log "Removing legacy ss-* artifacts (if any)"
$SUDO rm -f /usr/local/bin/vm                                   # old command name
$SUDO rm -f "$CADDY_ROOT/ss.html" "$CADDY_ROOT/ss-whisper-editor.html"  # old served pages

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

# 5) Pre-flight: whisper.cpp binary + model present? --------------------------
# (deploy.sh does not build these — setup.sh does. Warn early so a failed
#  whisper-server has an obvious explanation in the output.)
WHISPER_BIN="$WORKSPACE/whisper.cpp/build/bin/whisper-server"
MODEL_FILE="$WORKSPACE/whisper.cpp/models/ggml-${WHISPER_MODEL}.bin"
[[ -x "$WHISPER_BIN"   ]] || warn "whisper-server binary missing: $WHISPER_BIN (run setup.sh to build whisper.cpp)"
[[ -f "$MODEL_FILE"    ]] || warn "model missing: $MODEL_FILE (run setup.sh, or set WHISPER_MODEL to a model you have)"

# Register whisper.cpp's shared libs with ldconfig. The binary's RPATH is baked
# at build time, so if the build was MOVED (e.g. by ka-migrate.sh) it can't find
# libwhisper.so.1 and crash-loops with 127. Idempotent — runs every deploy.
WBUILD="$WORKSPACE/whisper.cpp/build"
if [[ -d "$WBUILD" ]]; then
  { [[ -d "$WBUILD/src" ]]      && echo "$WBUILD/src"
    [[ -d "$WBUILD/ggml/src" ]] && echo "$WBUILD/ggml/src"; } \
    | $SUDO tee /etc/ld.so.conf.d/whisper-cpp.conf >/dev/null
  $SUDO ldconfig 2>/dev/null || true
  log "Registered whisper.cpp libs with ldconfig ($WBUILD)"
fi

# 6) Restart + verify services ------------------------------------------------
OVERALL_OK=1

# Caddy: reload (fast, keeps connections); if that fails, restart; then verify.
if command -v caddy >/dev/null 2>&1 && [[ -z "${CADDY_BAD:-}" ]]; then
  log "Reloading Caddy"
  if ! $SUDO systemctl reload caddy 2>/dev/null; then
    warn "caddy reload failed — trying restart"
    $SUDO systemctl reset-failed caddy 2>/dev/null || true
    $SUDO systemctl restart caddy 2>/dev/null || true
  fi
  if ! wait_active caddy.service 30; then OVERALL_OK=0; fi
fi

# whisper-server FIRST (the API depends on it), then the API.
restart_verify whisper-server.service 60 || OVERALL_OK=0
restart_verify voicemail-api.service  60 || OVERALL_OK=0

# 7) Status --------------------------------------------------------------------
echo
log "Service status:"
for svc in caddy.service "${SERVICES[@]}"; do
  state="$(systemctl is-active "$svc" 2>/dev/null)" || true
  printf '   %-26s %s\n' "$svc" "${state:-unknown}"
done

# 8) Health checks -------------------------------------------------------------
# whisper-server: bound on 9305. API: /admin/* needs auth, so 200/401 = healthy.
log "Waiting for whisper-server on 127.0.0.1:9305"
if wait_http "http://127.0.0.1:9305/" "127.0.0.1" 40 "200 400 404 405"; then
  log "whisper-server responding (HTTP $REPLY)"
else
  warn "whisper-server not responding on :9305 (HTTP $REPLY) — transcription will fail"
  OVERALL_OK=0
fi

log "Health check: GET :8808/admin/phrases (expect 200 or 401)"
if wait_http "http://127.0.0.1:8808/admin/phrases" "vm.karims.dev" 40 "200 401"; then
  log "API healthy (HTTP $REPLY)"
else
  err "API NOT healthy (HTTP $REPLY)"
  dump_journal voicemail-api.service 30
  OVERALL_OK=0
fi

# WebSocket upgrade check: uvicorn needs a ws library (websockets) to serve
# /ws/transcribe. If it's missing the upgrade silently hangs — verify we get 101.
log "WebSocket check: /ws/transcribe (expect 101 Switching Protocols)"
WS_KEY="$(systemctl show voicemail-api.service -p Environment 2>/dev/null \
          | tr ' ' '\n' | sed -n 's/^Environment=API_KEY=//p; s/^API_KEY=//p' | head -1)"
ws_status="$(curl -s -i -N --max-time 6 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "http://127.0.0.1:8808/ws/transcribe?api_key=${WS_KEY}" 2>/dev/null | grep -m1 -oE '\b101\b' || true)"
if [[ "$ws_status" == "101" ]]; then
  log "WebSocket OK (101)"
else
  warn "WebSocket upgrade did NOT return 101 — uvicorn likely lacks the 'websockets' lib."
  warn "  Fix: $API_DIR/.venv/bin/pip install -r $API_DIR/requirements.txt && sudo systemctl restart voicemail-api.service"
  OVERALL_OK=0
fi

# 9) Verdict -------------------------------------------------------------------
echo
log "Backups of everything replaced are in: $BACKUP_DIR"
[[ -n "${CADDY_BAD:-}" ]] && err "NOTE: Caddyfile from repo did not validate — kept the old one. Fix and re-run."
if [[ "$OVERALL_OK" == "1" ]]; then
  log "✅ Deploy complete — Caddy + whisper-server + voicemail-api are all up and healthy."
  exit 0
else
  err "❌ Deploy finished with problems — see the logs dumped above. The previous files are backed up in $BACKUP_DIR (see README 'Rollback')."
  exit 1
fi
