#!/usr/bin/env bash
#
# ka-migrate.sh — migrate an EXISTING install from the old names to the new ones:
#     /etc/ss-whisper            -> /etc/ka-whisper
#     ~/.openclaw/workspace      -> ~/.ka/workspace
#     ~/SS-whisper.cpp (repo)    -> ~/KA-whisper.cpp
#
# Safe to run once on a box already provisioned with the old layout. It:
#   1. stops the services
#   2. moves the config dir (phrases/dnc + engine/model/workers state)
#   3. moves the workspace (whisper.cpp build + models + API code) — NO rebuild
#   4. deletes the moved Python venv (venvs bake absolute paths and can't be moved)
#   5. redeploys: recreates the venv, rewrites the units to the new paths, restarts
#   6. reinstalls faster-whisper if that engine was active
#   7. renames the repo checkout dir and re-points the 'ka' shortcut
#
# Idempotent: if a target already exists it skips that move. Run AFTER pulling the
# renamed repo (git pull), from inside the repo:  ./ka-migrate.sh
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_SVC="voicemail-api.service"
WHISPER_SVC="whisper-server.service"
UNIT_DIR="/etc/systemd/system"

OLD_CFG="/etc/ss-whisper"
NEW_CFG="/etc/ka-whisper"
NEW_WS="${NEW_WS:-$HOME/.ka/workspace}"
NEW_REPO="${NEW_REPO:-$HOME/KA-whisper.cpp}"

B=$'\033[1m'; R=$'\033[0m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'; CYN=$'\033[1;36m'
log()  { printf '%s[migrate]%s %s\n' "$CYN" "$R" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YLW" "$R" "$*"; }
err()  { printf '%s[error]%s %s\n' "$RED" "$R" "$*" >&2; }

SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# Detect the current workspace from the installed unit (fallback to ~/.openclaw/workspace)
OLD_WS=""
if [[ -f "$UNIT_DIR/$API_SVC" ]]; then
  OLD_WS="$(grep -oE '^WorkingDirectory=.*' "$UNIT_DIR/$API_SVC" | head -1 | cut -d= -f2- | sed 's#/voicemail_api/\?$##')"
fi
[[ -z "$OLD_WS" ]] && OLD_WS="$HOME/.openclaw/workspace"

echo
log "Plan:"
log "  config:    $OLD_CFG  ->  $NEW_CFG"
log "  workspace: $OLD_WS  ->  $NEW_WS"
log "  repo:      $REPO_DIR  ->  $NEW_REPO"
echo
read -rp "Proceed? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || { echo "cancelled"; exit 0; }

# 1) stop services -------------------------------------------------------------
log "Stopping services"
$SUDO systemctl stop "$API_SVC" "$WHISPER_SVC" 2>/dev/null || true

# 2) move config dir -----------------------------------------------------------
if [[ -d "$OLD_CFG" && ! -e "$NEW_CFG" ]]; then
  log "Moving $OLD_CFG -> $NEW_CFG"
  $SUDO mv "$OLD_CFG" "$NEW_CFG"
elif [[ -e "$NEW_CFG" ]]; then
  log "$NEW_CFG already exists — leaving it (skip)"
else
  warn "$OLD_CFG not found — will be seeded fresh by deploy"
fi

# 3) move workspace ------------------------------------------------------------
if [[ "$OLD_WS" == "$NEW_WS" ]]; then
  log "workspace already at target ($NEW_WS) — skip move"
elif [[ -d "$OLD_WS" && ! -e "$NEW_WS" ]]; then
  log "Moving workspace $OLD_WS -> $NEW_WS (this keeps the whisper.cpp build + models)"
  mkdir -p "$(dirname "$NEW_WS")"
  mv "$OLD_WS" "$NEW_WS"
elif [[ -e "$NEW_WS" ]]; then
  log "$NEW_WS already exists — leaving it (skip)"
else
  err "workspace $OLD_WS not found and $NEW_WS missing — aborting"; exit 1
fi

# 4) drop the moved venv (not relocatable) -------------------------------------
if [[ -d "$NEW_WS/voicemail_api/.venv" ]]; then
  log "Removing moved venv (will be recreated at the new path)"
  rm -rf "$NEW_WS/voicemail_api/.venv"
fi

# 5) redeploy at the new paths -------------------------------------------------
log "Redeploying (recreates venv, rewrites units to new paths, restarts)"
chmod +x "$REPO_DIR/deploy.sh" 2>/dev/null || true
PULL=0 CLONE_DIR="$REPO_DIR" WORKSPACE="$NEW_WS" SS_CONFIG_DIR="$NEW_CFG" \
  "$REPO_DIR/deploy.sh" || { err "deploy failed — check output above"; exit 1; }

# 6) reinstall faster-whisper if it was the active engine ----------------------
if [[ -f "$NEW_CFG/engine" ]] && grep -q fasterwhisper "$NEW_CFG/engine" 2>/dev/null; then
  PIP="$NEW_WS/voicemail_api/.venv/bin/pip"
  if [[ -x "$PIP" ]]; then
    log "Reinstalling faster-whisper into the fresh venv"
    "$PIP" install -q faster-whisper && $SUDO systemctl restart "$API_SVC" || warn "faster-whisper reinstall failed (engine will fall back to whisper.cpp)"
  fi
fi

# 7) rename the repo checkout dir + re-point the 'ka' shortcut ------------------
if [[ "$REPO_DIR" != "$NEW_REPO" && ! -e "$NEW_REPO" ]]; then
  log "Renaming repo dir $REPO_DIR -> $NEW_REPO"
  mv "$REPO_DIR" "$NEW_REPO"
  $SUDO ln -sf "$NEW_REPO/ss-ctl.sh" /usr/local/bin/ka
  log "Re-pointed 'ka' -> $NEW_REPO/ss-ctl.sh"
else
  $SUDO ln -sf "$REPO_DIR/ss-ctl.sh" /usr/local/bin/ka 2>/dev/null || true
fi

echo
log "${GRN}Migration complete.${R}"
log "Verify:  curl -s 127.0.0.1:8808/health   and   ka"
log "Old paths (${OLD_WS}, ${OLD_CFG}) are gone; new ones in place."
