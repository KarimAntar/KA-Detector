#!/usr/bin/env bash
#
# ss-ctl.sh — interactive control panel for the SS-whisper voicemail stack.
#
# A numbered terminal menu to manage everything without remembering commands:
#   - switch the whisper model (tiny / base.en / small.en / ...)
#   - restart / status / health-check the services
#   - check the GitHub repo for updates, pull + redeploy
#   - redeploy (reinstall) from the repo, update Caddy
#   - uninstall the services
#   - view live logs, edit phrases.txt / dnc.txt
#
# Usage:
#   cd ~/SS-whisper.cpp
#   ./ss-ctl.sh                 # interactive menu
#   WORKSPACE=/root/.openclaw/workspace ./ss-ctl.sh   # override workspace if needed
#
# It auto-detects the workspace from the installed systemd unit when possible.
#
set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration / detection
# ----------------------------------------------------------------------------
# resolve symlinks so a /usr/local/bin/ssctl shortcut still finds the repo
_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
BRANCH="${BRANCH:-master}"
SYSTEMD_DIR="/etc/systemd/system"
SS_CONFIG_DIR="${SS_CONFIG_DIR:-/etc/ss-whisper}"
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
WHISPER_SVC="whisper-server.service"
API_SVC="voicemail-api.service"
CADDY_SVC="caddy.service"
API_PORT="${API_PORT:-8808}"
WHISPER_PORT="${WHISPER_PORT:-9305}"

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# Colors
B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; CYN=$'\033[1;36m'; MAG=$'\033[1;35m'

# Detect WORKSPACE / whisper dir from the installed unit, fall back sensibly.
detect_paths() {
  local mp=""
  if [[ -f "$SYSTEMD_DIR/$WHISPER_SVC" ]]; then
    mp="$(grep -oE '\-m[[:space:]]+[^ ]+' "$SYSTEMD_DIR/$WHISPER_SVC" | head -1 | awk '{print $2}')"
  fi
  if [[ -n "$mp" ]]; then
    MODELS_DIR="$(dirname "$mp")"
    WHISPER_DIR="$(dirname "$MODELS_DIR")"
    WORKSPACE="${WORKSPACE:-$(dirname "$WHISPER_DIR")}"
  else
    WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
    WHISPER_DIR="$WORKSPACE/whisper.cpp"
    MODELS_DIR="$WHISPER_DIR/models"
  fi
  DL_SCRIPT="$WHISPER_DIR/models/download-ggml-model.sh"
  API_DIR="${API_DIR:-$WORKSPACE/voicemail_api}"
  VENV_PIP="$API_DIR/.venv/bin/pip"
}

current_engine() {
  if [[ -f "$SS_CONFIG_DIR/engine" ]]; then
    tr -d '[:space:]' <"$SS_CONFIG_DIR/engine"
  elif [[ -f "$SYSTEMD_DIR/$API_SVC" ]]; then
    grep -oE '^Environment=TRANSCRIBE_ENGINE=.*' "$SYSTEMD_DIR/$API_SVC" | head -1 | cut -d= -f3
  else
    echo "whispercpp"
  fi
}

current_model() {
  if [[ -f "$SS_CONFIG_DIR/whisper-model" ]]; then
    tr -d '[:space:]' <"$SS_CONFIG_DIR/whisper-model"
  elif [[ -f "$SYSTEMD_DIR/$WHISPER_SVC" ]]; then
    grep -oE 'ggml-[A-Za-z0-9._-]+\.bin' "$SYSTEMD_DIR/$WHISPER_SVC" | head -1 | sed -E 's/^ggml-//; s/\.bin$//'
  else
    echo "unknown"
  fi
}

pause() { echo; read -rp "${DIM}Press Enter to return to the menu...${R}" _; }
confirm() { local a; read -rp "$1 ${DIM}[y/N]${R} " a; [[ "$a" =~ ^[Yy]$ ]]; }

# ----------------------------------------------------------------------------
# Health helpers
# ----------------------------------------------------------------------------
svc_state() { systemctl is-active "$1" 2>/dev/null || echo "unknown"; }
state_colored() {
  local s; s="$(svc_state "$1")"
  case "$s" in
    active)   printf '%s%s%s' "$GRN" "$s" "$R" ;;
    failed)   printf '%s%s%s' "$RED" "$s" "$R" ;;
    *)        printf '%s%s%s' "$YLW" "$s" "$R" ;;
  esac
}

health_check() {
  echo "${B}Health check${R}"
  echo -n "  whisper-server (:$WHISPER_PORT) ... "
  if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:$WHISPER_PORT/" 2>/dev/null \
     || curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$WHISPER_PORT/" 2>/dev/null | grep -qE '^[24]'; then
    echo "${GRN}OK${R}"; else echo "${RED}no response${R}"; fi
  echo -n "  voicemail-api  (:$API_PORT) ... "
  local code="000" i=0
  # poll up to ~10s — uvicorn reports "active" before it finishes binding the port
  while (( i < 10 )); do
    code="$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT/admin/phrases" 2>/dev/null)"
    [[ "$code" =~ ^(200|401)$ ]] && break
    sleep 1; ((i++))
  done
  if [[ "$code" =~ ^(200|401)$ ]]; then echo "${GRN}OK (HTTP $code)${R}"; else echo "${RED}HTTP ${code:-000}${R}"; fi
}

wait_active() {  # wait_active <unit> <timeout>
  local unit="$1" timeout="${2:-60}" i=0
  while (( i < timeout )); do
    case "$(svc_state "$unit")" in
      active) return 0 ;;
      failed) return 1 ;;
    esac
    sleep 1; ((i++))
  done
  [[ "$(svc_state "$unit")" == active ]]
}

restart_one() {  # restart_one <unit>
  local unit="$1"
  echo "  restarting $unit ..."
  $SUDO systemctl reset-failed "$unit" 2>/dev/null || true
  $SUDO systemctl restart "$unit"
  if wait_active "$unit" 60; then
    echo "  $unit -> ${GRN}active${R}"
  else
    echo "  $unit -> ${RED}$(svc_state "$unit")${R}"
    $SUDO journalctl -u "$unit" -n 20 --no-pager 2>/dev/null || true
  fi
}

# ----------------------------------------------------------------------------
# Menu actions
# ----------------------------------------------------------------------------
MODELS=(tiny tiny.en base base.en small small.en medium medium.en large-v3 large-v3-turbo)
MDESC=(
  "fastest, lowest accuracy (~75MB)"
  "English-only tiny — fastest (~75MB)"
  "fast, better accuracy (~142MB)"
  "English-only base — recommended upgrade (~142MB)"
  "slower, good accuracy (~466MB)"
  "English-only small (~466MB)"
  "slow on CPU, high accuracy (~1.5GB)"
  "English-only medium (~1.5GB)"
  "very slow on CPU, best accuracy (~3GB) — wants a GPU"
  "faster large variant (~1.5GB) — still heavy on CPU"
)

action_switch_model() {
  clear
  echo "${B}Switch whisper model${R}   ${DIM}(current: ${CYN}$(current_model)${DIM})${R}"
  echo
  local i
  for i in "${!MODELS[@]}"; do
    printf "  ${B}%2d${R}) %-16s ${DIM}%s${R}\n" "$((i+1))" "${MODELS[$i]}" "${MDESC[$i]}"
  done
  echo "   ${B} 0${R}) cancel"
  echo
  local choice; read -rp "Pick a model number: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { echo "${RED}invalid${R}"; return; }
  (( choice == 0 )) && return
  local idx=$((choice-1))
  (( idx>=0 && idx<${#MODELS[@]} )) || { echo "${RED}out of range${R}"; return; }
  local model="${MODELS[$idx]}"
  local file="$MODELS_DIR/ggml-${model}.bin"

  if [[ ! -f "$file" ]]; then
    echo "${YLW}Model not present — downloading ${model} ...${R}"
    [[ -x "$DL_SCRIPT" || -f "$DL_SCRIPT" ]] || { echo "${RED}download script not found: $DL_SCRIPT${R}"; return; }
    ( cd "$WHISPER_DIR" && bash "$DL_SCRIPT" "$model" ) || { echo "${RED}download failed${R}"; return; }
  else
    echo "${GRN}Model already present:${R} $file"
  fi
  [[ -f "$file" ]] || { echo "${RED}model file still missing after download${R}"; return; }

  echo "Pointing systemd units at ggml-${model}.bin ..."
  $SUDO sed -i -E "s#ggml-[A-Za-z0-9._-]+\.bin#ggml-${model}.bin#g" \
    "$SYSTEMD_DIR/$WHISPER_SVC" "$SYSTEMD_DIR/$API_SVC"
  # persist the choice so deploy.sh won't revert it
  echo "$model" | $SUDO tee "$SS_CONFIG_DIR/whisper-model" >/dev/null

  $SUDO systemctl daemon-reload
  restart_one "$WHISPER_SVC"
  restart_one "$API_SVC"
  echo
  health_check
  echo
  echo "${GRN}Switched to ${model}.${R}"
}

FW_MODELS=(tiny.en base.en small.en distil-small.en distil-large-v3)
FW_DESC=(
  "fastest, English (~75MB) — like current tiny.en"
  "fast, better accuracy, English (~145MB)"
  "good accuracy, English, slower (~480MB)"
  "distilled — near-base accuracy, very fast (English)"
  "distilled large — high accuracy, heavier on CPU (English)"
)

set_unit_env() {  # set_unit_env <KEY> <VALUE>  — set/replace an Environment= line in the API unit
  local key="$1" val="$2" unit="$SYSTEMD_DIR/$API_SVC"
  if grep -qE "^Environment=${key}=" "$unit"; then
    $SUDO sed -i -E "s#^Environment=${key}=.*#Environment=${key}=${val}#" "$unit"
  else
    # insert after the WHISPER_SERVER_URL line (or append before [Install])
    $SUDO sed -i "/^Environment=WHISPER_SERVER_URL=/a Environment=${key}=${val}" "$unit"
  fi
}

action_switch_engine() {
  clear
  echo "${B}Switch transcription engine${R}   ${DIM}(current: ${CYN}$(current_engine)${DIM})${R}"
  echo
  echo "   ${B}1${R}) whisper.cpp     ${DIM}lightweight C++ (current default); batch-per-chunk${R}"
  echo "   ${B}2${R}) faster-whisper  ${DIM}WhisperLive's CTranslate2 engine; resident, int8, lower latency${R}"
  echo "   ${B}0${R}) cancel"
  echo
  local c; read -rp "Pick engine: " c
  case "$c" in
    1)
      set_unit_env TRANSCRIBE_ENGINE whispercpp
      echo "whispercpp" | $SUDO tee "$SS_CONFIG_DIR/engine" >/dev/null
      $SUDO systemctl daemon-reload
      restart_one "$API_SVC"
      echo; health_check
      echo "${GRN}Engine set to whisper.cpp.${R}"
      ;;
    2)
      # pick a faster-whisper model
      echo
      echo "${B}faster-whisper model:${R}"
      local i
      for i in "${!FW_MODELS[@]}"; do
        printf "  ${B}%d${R}) %-18s ${DIM}%s${R}\n" "$((i+1))" "${FW_MODELS[$i]}" "${FW_DESC[$i]}"
      done
      local m; read -rp "Pick model number [1]: " m; m="${m:-1}"
      [[ "$m" =~ ^[0-9]+$ ]] || { echo "${RED}invalid${R}"; return; }
      local idx=$((m-1)); (( idx>=0 && idx<${#FW_MODELS[@]} )) || { echo "${RED}out of range${R}"; return; }
      local fwm="${FW_MODELS[$idx]}"

      # ensure faster-whisper is installed in the API venv
      if [[ ! -x "$VENV_PIP" ]]; then echo "${RED}venv pip not found at $VENV_PIP${R}"; return; fi
      if ! "$API_DIR/.venv/bin/python" -c "import faster_whisper" 2>/dev/null; then
        echo "${YLW}Installing faster-whisper into the venv (one-time, downloads CTranslate2)...${R}"
        "$VENV_PIP" install -q faster-whisper || { echo "${RED}pip install failed${R}"; return; }
      else
        echo "${GRN}faster-whisper already installed.${R}"
      fi

      set_unit_env TRANSCRIBE_ENGINE fasterwhisper
      set_unit_env FW_MODEL "$fwm"
      echo "fasterwhisper" | $SUDO tee "$SS_CONFIG_DIR/engine"   >/dev/null
      echo "$fwm"          | $SUDO tee "$SS_CONFIG_DIR/fw-model" >/dev/null

      $SUDO systemctl daemon-reload
      echo "${DIM}Restarting API — first start downloads the ${fwm} model, may take a moment...${R}"
      restart_one "$API_SVC"
      echo; health_check
      echo "${GRN}Engine set to faster-whisper (${fwm}).${R}"
      echo "${DIM}Tip: check  curl -s 127.0.0.1:$API_PORT/health  — it shows engine + fw_loaded.${R}"
      ;;
    0) return ;;
    *) echo "${RED}invalid${R}" ;;
  esac
}

action_status() {
  clear
  echo "${B}Service status${R}"
  printf "  %-24s %s\n" "$CADDY_SVC"   "$(state_colored "$CADDY_SVC")"
  printf "  %-24s %s\n" "$WHISPER_SVC" "$(state_colored "$WHISPER_SVC")"
  printf "  %-24s %s\n" "$API_SVC"     "$(state_colored "$API_SVC")"
  echo "  ${DIM}model: ${R}${CYN}$(current_model)${R}   ${DIM}engine: ${R}${CYN}$(current_engine)${R}   ${DIM}workspace: ${R}$WORKSPACE"
  echo
  health_check
}

action_restart() {
  clear
  echo "${B}Restart services${R}"
  echo "   ${B}1${R}) all (caddy + whisper + api)"
  echo "   ${B}2${R}) whisper-server"
  echo "   ${B}3${R}) voicemail-api"
  echo "   ${B}4${R}) caddy"
  echo "   ${B}0${R}) cancel"
  local c; read -rp "Choice: " c
  case "$c" in
    1) restart_one "$CADDY_SVC"; restart_one "$WHISPER_SVC"; restart_one "$API_SVC" ;;
    2) restart_one "$WHISPER_SVC" ;;
    3) restart_one "$API_SVC" ;;
    4) restart_one "$CADDY_SVC" ;;
    0) return ;;
    *) echo "${RED}invalid${R}" ;;
  esac
}

action_check_updates() {
  clear
  echo "${B}Check repo for updates${R}   ${DIM}($REPO_DIR @ $BRANCH)${R}"
  if [[ ! -d "$REPO_DIR/.git" ]]; then echo "${RED}not a git checkout${R}"; return; fi
  echo "Fetching ..."
  if ! git -C "$REPO_DIR" fetch -q origin "$BRANCH" 2>/dev/null; then
    echo "${YLW}fetch failed (private repo may need a token).${R}"
    echo "Set the token into the remote once with:"
    echo "  ${DIM}git -C $REPO_DIR remote set-url origin https://<user>:<token>@github.com/KarimAntar/SS-whisper.cpp.git${R}"
    return
  fi
  local local_sha remote_sha
  local_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  remote_sha="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"
  if [[ "$local_sha" == "$remote_sha" ]]; then
    echo "${GRN}Already up to date.${R} ($(git -C "$REPO_DIR" rev-parse --short HEAD))"
    return
  fi
  echo "${YLW}Updates available:${R}"
  git -C "$REPO_DIR" log --oneline "$local_sha..$remote_sha"
  echo
  if confirm "Pull these changes and redeploy now?"; then
    git -C "$REPO_DIR" merge --ff-only "origin/$BRANCH" || { echo "${RED}fast-forward failed${R}"; return; }
    action_redeploy noclear
  fi
}

action_redeploy() {
  [[ "${1:-}" == noclear ]] || clear
  echo "${B}Redeploy from repo${R}   ${DIM}(model: $(current_model))${R}"
  if [[ ! -x "$REPO_DIR/deploy.sh" ]]; then chmod +x "$REPO_DIR/deploy.sh" 2>/dev/null || true; fi
  PULL=0 CLONE_DIR="$REPO_DIR" WORKSPACE="$WORKSPACE" WHISPER_MODEL="$(current_model)" \
    bash "$REPO_DIR/deploy.sh"
}

action_update_caddy() {
  clear
  echo "${B}Update / reload Caddy${R}"
  echo "Validating $CADDYFILE ..."
  if $SUDO caddy validate --config "$CADDYFILE" --adapter caddyfile 2>&1 | tail -3; then
    echo "Reloading caddy ..."
    if $SUDO systemctl reload "$CADDY_SVC"; then
      echo "${GRN}Caddy reloaded.${R}"
    else
      echo "${YLW}reload failed — trying restart${R}"; restart_one "$CADDY_SVC"
    fi
  else
    echo "${RED}Caddyfile invalid — not reloading.${R}"
  fi
}

action_logs() {
  clear
  echo "${B}View logs${R}  (live follow — Ctrl+C to stop)"
  echo "   ${B}1${R}) whisper-server   ${B}2${R}) voicemail-api   ${B}3${R}) caddy   ${B}0${R}) cancel"
  local c; read -rp "Choice: " c
  case "$c" in
    1) $SUDO journalctl -u "$WHISPER_SVC" -n 80 -f ;;
    2) $SUDO journalctl -u "$API_SVC" -n 80 -f ;;
    3) $SUDO journalctl -u "$CADDY_SVC" -n 80 -f ;;
    *) return ;;
  esac
}

action_edit_config() {
  clear
  local ed="${EDITOR:-nano}"
  echo "${B}Edit config${R}  (editor: $ed)"
  echo "   ${B}1${R}) phrases.txt   ${B}2${R}) dnc.txt   ${B}0${R}) cancel"
  local c; read -rp "Choice: " c
  case "$c" in
    1) $SUDO "$ed" "$SS_CONFIG_DIR/phrases.txt"; restart_one "$API_SVC" ;;
    2) $SUDO "$ed" "$SS_CONFIG_DIR/dnc.txt";     restart_one "$API_SVC" ;;
    *) return ;;
  esac
}

action_reinstall() {
  clear
  echo "${B}Reinstall services from repo${R}"
  echo "This re-installs systemd units, Caddy config and the public site from the repo,"
  echo "re-syncs the venv, and restarts everything (your phrases/dnc are preserved)."
  echo
  confirm "Proceed with reinstall (redeploy)?" && action_redeploy noclear
}

action_uninstall() {
  clear
  echo "${RED}${B}Uninstall services${R}"
  echo "This stops & disables the services and removes their systemd unit files."
  echo
  if ! confirm "Stop, disable and remove ${WHISPER_SVC} + ${API_SVC}?"; then echo "cancelled"; return; fi
  local s
  for s in "$API_SVC" "$WHISPER_SVC"; do
    $SUDO systemctl stop "$s" 2>/dev/null || true
    $SUDO systemctl disable "$s" 2>/dev/null || true
    $SUDO rm -f "$SYSTEMD_DIR/$s"
    echo "  removed $s"
  done
  $SUDO systemctl daemon-reload
  $SUDO systemctl reset-failed 2>/dev/null || true
  echo "${GRN}Services removed.${R}"
  echo
  if confirm "${RED}Also DELETE the whisper.cpp build + models at $WHISPER_DIR ?${R}"; then
    $SUDO rm -rf "$WHISPER_DIR"; echo "  deleted $WHISPER_DIR"
  fi
  if confirm "${RED}Also DELETE config $SS_CONFIG_DIR (phrases/dnc) ?${R}"; then
    $SUDO rm -rf "$SS_CONFIG_DIR"; echo "  deleted $SS_CONFIG_DIR"
  fi
  echo "${DIM}(Caddy itself left installed. Remove its site blocks from $CADDYFILE manually if desired.)${R}"
}

# ----------------------------------------------------------------------------
# Main menu loop
# ----------------------------------------------------------------------------
main_menu() {
  while true; do
    clear
    echo "${MAG}${B}╔══════════════════════════════════════════════╗${R}"
    echo "${MAG}${B}║        SS-whisper  ·  control panel           ║${R}"
    echo "${MAG}${B}╚══════════════════════════════════════════════╝${R}"
    printf "  caddy:%s  whisper:%s  api:%s   ${DIM}model:${R}${CYN}%s${R} ${DIM}engine:${R}${CYN}%s${R}\n" \
      "$(state_colored "$CADDY_SVC")" "$(state_colored "$WHISPER_SVC")" "$(state_colored "$API_SVC")" "$(current_model)" "$(current_engine)"
    echo "  ${DIM}repo:${R} $REPO_DIR  ${DIM}ws:${R} $WORKSPACE"
    echo
    echo "   ${B}1${R}) Status + health check"
    echo "   ${B}2${R}) Switch whisper model"
    echo "   ${B}3${R}) Switch transcription engine  ${DIM}(whisper.cpp / faster-whisper)${R}"
    echo "   ${B}4${R}) Restart services"
    echo "   ${B}5${R}) Check repo for updates  (pull + redeploy)"
    echo "   ${B}6${R}) Redeploy from repo"
    echo "   ${B}7${R}) Update / reload Caddy"
    echo "   ${B}8${R}) View logs"
    echo "   ${B}9${R}) Edit phrases.txt / dnc.txt"
    echo "  ${B}10${R}) Reinstall services"
    echo "  ${B}11${R}) ${RED}Uninstall services${R}"
    echo "   ${B}0${R}) Quit"
    echo
    local c; read -rp "${B}Select:${R} " c
    case "$c" in
      1) action_status ;;
      2) action_switch_model ;;
      3) action_switch_engine ;;
      4) action_restart ;;
      5) action_check_updates ;;
      6) action_redeploy ;;
      7) action_update_caddy ;;
      8) action_logs ;;
      9) action_edit_config ;;
      10) action_reinstall ;;
      11) action_uninstall ;;
      0|q|Q) echo "bye"; exit 0 ;;
      *) echo "${RED}invalid choice${R}"; sleep 1; continue ;;
    esac
    pause
  done
}

detect_paths
main_menu
