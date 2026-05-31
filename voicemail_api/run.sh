#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/.venv/bin/activate"

export WHISPER_CPP_PATH="${WHISPER_CPP_PATH:-/home/ubuntu/.openclaw/workspace/whisper.cpp}"
export WHISPER_MODEL_PATH="${WHISPER_MODEL_PATH:-$WHISPER_CPP_PATH/models/ggml-base.bin}"

# Allow passing extra uvicorn args via UVICORN_ARGS and control workers with UVICORN_WORKERS
exec uvicorn server:app --host 0.0.0.0 --port 8808 ${UVICORN_ARGS:-} --workers ${UVICORN_WORKERS:-2}
