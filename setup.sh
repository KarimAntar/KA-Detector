#!/usr/bin/env bash
#
# setup.sh — FULL provisioning for a fresh VPS. Installs everything needed to run
# the SS-whisper voicemail stack exactly like the source server, then hands off
# to deploy.sh to install the code/config/units and start the services.
#
# What it does:
#   1. apt packages (build tools, ffmpeg, python venv, rsync, git, curl)
#   2. Caddy (from the official apt repo) if not already installed
#   3. clones + builds whisper.cpp (CPU / Release) -> build/bin/whisper-server
#   4. downloads the whisper model (default: tiny, matching the source server)
#   5. creates the Python venv and installs requirements.txt
#   6. runs deploy.sh (PULL=0) to install API code, Caddy config, systemd units,
#      seed /etc/ss-whisper, and start + health-check everything.
#
# Usage on a FRESH box (repo already cloned, e.g. into ~/ss-deploy-repo):
#   cd ~/ss-deploy-repo
#   WORKSPACE=/home/<you>/.openclaw/workspace ./setup.sh
#
# Re-runnable: each step is skipped if already done (idempotent).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# Configuration (override via env)
# ----------------------------------------------------------------------------
WORKSPACE="${WORKSPACE:-/home/ubuntu/.openclaw/workspace}"
API_DIR="${API_DIR:-$WORKSPACE/voicemail_api}"
WHISPER_DIR="${WHISPER_DIR:-$WORKSPACE/whisper.cpp}"
WHISPER_REPO="${WHISPER_REPO:-https://github.com/ggerganov/whisper.cpp.git}"
# Pin to a commit for an exact match of the source server, or leave empty for latest.
WHISPER_COMMIT="${WHISPER_COMMIT:-}"
# Model to download + run: tiny | tiny.en | base | base.en | small | ...
WHISPER_MODEL="${WHISPER_MODEL:-tiny}"
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(id -un)}}"
INSTALL_CADDY="${INSTALL_CADDY:-1}"
JOBS="${JOBS:-$(nproc)}"

log()  { printf '\033[1;36m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then SUDO="sudo"; fi

# ----------------------------------------------------------------------------
log "Provisioning voicemail stack — workspace=$WORKSPACE user=$SERVICE_USER model=$WHISPER_MODEL"

# 1) System packages -----------------------------------------------------------
log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -y
$SUDO apt-get install -y \
  build-essential cmake git curl ca-certificates ffmpeg \
  python3 python3-venv python3-pip rsync

# 2) Caddy ---------------------------------------------------------------------
if [[ "$INSTALL_CADDY" == "1" ]] && ! command -v caddy >/dev/null 2>&1; then
  log "Installing Caddy from the official apt repo"
  $SUDO apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | $SUDO gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y caddy
else
  command -v caddy >/dev/null 2>&1 && log "Caddy already installed ($(caddy version | head -1))"
fi

# 3) whisper.cpp: clone + build ------------------------------------------------
if [[ ! -d "$WHISPER_DIR/.git" ]]; then
  log "Cloning whisper.cpp -> $WHISPER_DIR"
  mkdir -p "$(dirname "$WHISPER_DIR")"
  git clone "$WHISPER_REPO" "$WHISPER_DIR"
fi
if [[ -n "$WHISPER_COMMIT" ]]; then
  log "Checking out whisper.cpp @ $WHISPER_COMMIT"
  git -C "$WHISPER_DIR" fetch --all -q
  git -C "$WHISPER_DIR" checkout -q "$WHISPER_COMMIT"
fi
if [[ ! -x "$WHISPER_DIR/build/bin/whisper-server" ]]; then
  log "Building whisper.cpp (CPU, Release, -j$JOBS) — this can take a few minutes"
  cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=OFF
  cmake --build "$WHISPER_DIR/build" --config Release -j "$JOBS" \
    --target whisper-server whisper-cli
else
  log "whisper.cpp already built (build/bin/whisper-server present)"
fi

# 4) Model ---------------------------------------------------------------------
MODEL_FILE="$WHISPER_DIR/models/ggml-${WHISPER_MODEL}.bin"
if [[ ! -f "$MODEL_FILE" ]]; then
  log "Downloading whisper model: $WHISPER_MODEL"
  ( cd "$WHISPER_DIR" && bash ./models/download-ggml-model.sh "$WHISPER_MODEL" )
else
  log "Model already present: $MODEL_FILE"
fi
[[ -f "$MODEL_FILE" ]] || { err "Model $MODEL_FILE missing after download"; exit 1; }

# 5) Python venv ---------------------------------------------------------------
if [[ ! -d "$API_DIR/.venv" ]]; then
  log "Creating Python venv at $API_DIR/.venv"
  mkdir -p "$API_DIR"
  python3 -m venv "$API_DIR/.venv"
fi
log "Installing Python requirements"
"$API_DIR/.venv/bin/pip" install --upgrade pip -q
"$API_DIR/.venv/bin/pip" install -q -r "$SCRIPT_DIR/voicemail_api/requirements.txt"

# Make sure the workspace + venv are owned by the service user (build may run as root via sudo).
$SUDO chown -R "$SERVICE_USER" "$API_DIR" "$WHISPER_DIR" 2>/dev/null || true

# 6) Hand off to deploy.sh -----------------------------------------------------
log "Running deploy.sh to install code, Caddy config, systemd units, control panel and start"
chmod +x "$SCRIPT_DIR/deploy.sh" "$SCRIPT_DIR/ss-ctl.sh" 2>/dev/null || true
PULL=0 \
WORKSPACE="$WORKSPACE" \
API_DIR="$API_DIR" \
SERVICE_USER="$SERVICE_USER" \
WHISPER_MODEL="$WHISPER_MODEL" \
CLONE_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/deploy.sh"

log "Setup complete."
log "Control panel installed — run 'ka' to manage everything (status / model / engine / restart / update)."
