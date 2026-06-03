# KA Detector API (whisper.cpp)

Lightweight HTTP API that transcribes audio and detects voicemail phrases using whisper.cpp.

## Requirements
- whisper.cpp built at: `/home/ubuntu/.openclaw/workspace/whisper.cpp`
- base model at: `/home/ubuntu/.openclaw/workspace/whisper.cpp/models/ggml-base.bin`

## Run
```bash
cd /home/ubuntu/.openclaw/workspace/voicemail_api
./run.sh
```

Server listens on **http://0.0.0.0:8808** (local)
Public HTTPS: **https://ss.karims.dev**

## Auth
API key (preferred): send `X-API-Key: <YOUR_API_KEY>` or `Authorization: Bearer <YOUR_API_KEY>`

Basic auth (optional): `username:password`

CORS: configured via `CORS_ORIGINS` env (currently `*`).

## Endpoints
### `GET /health`

### `POST /transcribe`
Form fields:
- `audio` (file)
- `language` (default: `en`)
- `duration_ms` (optional)

Example:
```bash
curl -s -X POST https://ss.karims.dev/transcribe \
  -H "X-API-Key: <YOUR_API_KEY>" \
  -F "audio=@/tmp/output_test.wav" \
  -F "language=en" | jq
```

### `POST /voicemail`
Form fields:
- `audio` (file)
- `language` (default: `en`)
- `decision_window_ms` (default: `2000`)
- `session_id` (optional, default: `default`)
- `dead_air_threshold` (optional, default: `2`)

Example:
```bash
curl -s -X POST https://ss.karims.dev/voicemail \
  -H "X-API-Key: <YOUR_API_KEY>" \
  -F "audio=@/tmp/output_test.wav" \
  -F "language=en" \
  -F "decision_window_ms=2000" \
  -F "session_id=call-123" \
  -F "dead_air_threshold=2" | jq
```

### `POST /voicemail-json`
JSON body:
```json
{
  "audio_base64": "<BASE64_WAV>",
  "language": "en",
  "decision_window_ms": 2000,
  "session_id": "call-123",
  "dead_air_threshold": 2
}
```

Example:
```bash
curl -s -X POST https://ss.karims.dev/voicemail-json \
  -H "X-API-Key: <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"audio_base64":"<BASE64>","language":"en","decision_window_ms":2000,"session_id":"call-123","dead_air_threshold":2}' | jq
```

## Client helper (for Claude code agent)
```bash
pip install requests
```
```bash
python client.py transcribe /path/to/audio.wav
python client.py voicemail /path/to/audio.wav
python client.py voicemail_json /path/to/audio.wav
```

## Notes
- Detection is phrase-based. Update `PHRASES` in `server.py` to tailor behavior.
- Added voicemail tone detection (audio beep) and additional phrases like "at the tone" and "press any key".
- For better precision, tune the decision window and dead air threshold.
