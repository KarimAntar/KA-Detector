import asyncio
import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List, Optional

import httpx
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile, Cookie, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials, HTTPAuthorizationCredentials, HTTPBearer

APP_DIR = Path(__file__).resolve().parent
WORK_DIR = APP_DIR / "work"
WORK_DIR.mkdir(parents=True, exist_ok=True)

DEFAULT_WHISPER_CPP = Path(os.environ.get("WHISPER_CPP_PATH", "/home/ubuntu/.ka/workspace/whisper.cpp"))
DEFAULT_MODEL = Path(os.environ.get("WHISPER_MODEL_PATH", str(DEFAULT_WHISPER_CPP / "models/ggml-tiny.bin")))

WHISPER_SERVER_URL = os.environ.get("WHISPER_SERVER_URL", "http://127.0.0.1:9305")
WHISPER_SERVER_TIMEOUT = float(os.environ.get("WHISPER_SERVER_TIMEOUT", "30"))

# ── Transcription engine selection ───────────────────────────────────────────
# whispercpp   -> POST chunks to whisper.cpp whisper-server (default, current)
# fasterwhisper-> in-process faster-whisper / CTranslate2 (WhisperLive's engine);
#                 model stays resident, int8 on CPU => lower latency per chunk.
TRANSCRIBE_ENGINE = os.environ.get("TRANSCRIBE_ENGINE", "whispercpp").lower()
FW_MODEL    = os.environ.get("FW_MODEL", "tiny.en")          # tiny.en | base.en | small.en | distil-small.en | ...
FW_COMPUTE  = os.environ.get("FW_COMPUTE", "int8")           # int8 | int8_float16 | float32
FW_BEAM     = int(os.environ.get("FW_BEAM", "1"))            # 1 = greedy (fastest)
FW_THREADS  = int(os.environ.get("FW_THREADS", "0"))         # 0 = CTranslate2 default
FW_VAD      = os.environ.get("FW_VAD", "true").lower() in ("1", "true", "yes")

_fw_model = None
_fw_model_lock = None  # set in module init below (threading imported later)

DEFAULT_PHRASES = [
    "please leave a message",
    "leave a message",
    "after the tone",
    "at the tone",
    "record your message",
    "your call has been forwarded",
    "not available",
    "cannot take your call",
    "can't take your call",
    "away from the phone",
    "voicemail",
    "mailbox",
    "mailbox is full",
    "sorry i missed your call",
    "you have reached",
    "the person you are calling",
    "please leave your name",
    "please leave your number",
    "press any key",
    "press any button",
    "press any number",
    "press any digit",
    "press any key to continue",
    "press any button to continue",
    "to continue",
    "i will call you back shortly",
    "please stay on the line",
    "i can't answer your call now",
    "please leave a detailed message",
    "i couldn't hear you, please leave a message",
    "leave your name",
    "please hung up",
    "you reached the voice mail",
    "voice mail",
    "thanks please stay on the line",
    "as soon as possible thank you",
    "thank you for calling",
    "thanks for calling",
    "i couldn't hear you please try again",
    "your number or a detailed message",
    "and i will get back to you",
    "i will get back",
    "get back to you",
    "i'll back to you",
    "i'll text you right back",
    "we have a message",
    "or text me or information and i will",
    "brief message and we will be sure to",
    "please be sure to leave",
    "press 1 to record your",
    "press 1",
    "[beep]",
    "(beep)",
    "[music]",
    "(upbeat music)",
    "hello, please",
    "(bell rings)",
    "[bell ringing]",
    "please feel free to contact",
    "thank you so much and have a great day",
    "or because of a bad connection",
]

PHRASES_FILE = Path(os.environ.get("PHRASES_FILE", "/etc/ka-whisper/phrases.txt"))

_PHRASES_CACHE = None
_PHRASES_MTIME = 0.0

def _load_phrases():
    global _PHRASES_CACHE, _PHRASES_MTIME
    try:
        if not PHRASES_FILE.parent.exists():
            PHRASES_FILE.parent.mkdir(parents=True, exist_ok=True)
        if not PHRASES_FILE.exists():
            with PHRASES_FILE.open("w", encoding="utf-8") as f:
                for p in DEFAULT_PHRASES:
                    f.write(p + "\n")
        mtime = PHRASES_FILE.stat().st_mtime
        if _PHRASES_CACHE is None or mtime != _PHRASES_MTIME:
            with PHRASES_FILE.open("r", encoding="utf-8") as f:
                lines = [l.strip() for l in f.readlines()]
            phrases = [l for l in lines if l]
            _PHRASES_CACHE = phrases if phrases else DEFAULT_PHRASES
            _PHRASES_MTIME = mtime
        return _PHRASES_CACHE
    except Exception:
        return DEFAULT_PHRASES

PHRASES = _load_phrases()

DNC_FILE = Path(os.environ.get("DNC_FILE", "/etc/ka-whisper/dnc.txt"))
_DNC_CACHE = None
_DNC_MTIME = 0.0

def _load_dnc():
    global _DNC_CACHE, _DNC_MTIME
    try:
        if not DNC_FILE.parent.exists():
            DNC_FILE.parent.mkdir(parents=True, exist_ok=True)
        if not DNC_FILE.exists():
            with DNC_FILE.open("w", encoding="utf-8") as f:
                f.write("")
        mtime = DNC_FILE.stat().st_mtime
        if _DNC_CACHE is None or mtime != _DNC_MTIME:
            with DNC_FILE.open("r", encoding="utf-8") as f:
                lines = [l.strip() for l in f.readlines()]
            phrases = [l for l in lines if l]
            _DNC_CACHE = phrases if phrases else []
            _DNC_MTIME = mtime
        return _DNC_CACHE
    except Exception:
        return []

API_KEY = os.environ.get("API_KEY")
BASIC_AUTH_USER = os.environ.get("BASIC_AUTH_USER")
BASIC_AUTH_PASS = os.environ.get("BASIC_AUTH_PASS")
CORS_ORIGINS    = os.environ.get("CORS_ORIGINS", "*")
RESEND_API_KEY  = os.environ.get("RESEND_API_KEY", "")
CONTACT_EMAIL   = os.environ.get("CONTACT_EMAIL", "info@karims.dev")
SMTP_FROM       = os.environ.get("SMTP_FROM", "KA Voicemail <onboarding@resend.dev>")

basic_scheme = HTTPBasic(auto_error=False)
bearer_scheme = HTTPBearer(auto_error=False)

_http_client: Optional[httpx.AsyncClient] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _http_client
    _http_client = httpx.AsyncClient(timeout=WHISPER_SERVER_TIMEOUT)
    # Pre-load the faster-whisper model so the first live chunk isn't slow.
    if TRANSCRIBE_ENGINE == "fasterwhisper":
        try:
            await asyncio.to_thread(_get_fw_model)
        except Exception as exc:
            print(f"[warn] faster-whisper preload failed ({exc}); will fall back to whisper.cpp")
    yield
    await _http_client.aclose()
    _http_client = None


app = FastAPI(title="KA Detector API", version="0.5.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[origin.strip() for origin in CORS_ORIGINS.split(",") if origin.strip()] or ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _authorize(
    api_key_header: Optional[str] = Header(None, alias="X-API-Key"),
    bearer: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    basic: Optional[HTTPBasicCredentials] = Depends(basic_scheme),
):
    if not API_KEY and not BASIC_AUTH_USER:
        return

    api_key_ok = False
    basic_ok = False

    if API_KEY:
        if api_key_header and api_key_header == API_KEY:
            api_key_ok = True
        if bearer and bearer.credentials == API_KEY:
            api_key_ok = True

    if BASIC_AUTH_USER and BASIC_AUTH_PASS:
        if basic and basic.username == BASIC_AUTH_USER and basic.password == BASIC_AUTH_PASS:
            basic_ok = True

    if API_KEY and BASIC_AUTH_USER:
        if api_key_ok or basic_ok:
            return
    elif API_KEY and api_key_ok:
        return
    elif BASIC_AUTH_USER and basic_ok:
        return

    raise HTTPException(status_code=401, detail="Unauthorized")


def _whisper_cli_path() -> Path:
    exe = DEFAULT_WHISPER_CPP / "build/bin/whisper-cli"
    if not exe.exists():
        raise FileNotFoundError("whisper-cli not found. Build whisper.cpp first.")
    return exe


import threading

ACTIVE_TRANSCRIPTS = {}
ACTIVE_TRANSCRIPTS_LOCK = threading.Lock()

DEAD_AIR_ENABLED = os.environ.get("DEAD_AIR_ENABLED", "true").lower() in ("1", "true", "yes")
DEAD_AIR_THRESHOLD_DEFAULT = int(os.environ.get("DEAD_AIR_THRESHOLD", "3"))
DEAD_AIR_STATE = {}
DEAD_AIR_LOCK = threading.Lock()


def _is_blank_text(text: str) -> bool:
    if text is None:
        return True
    t = text.strip().lower()
    if not t:
        return True
    if t in ("[blank_audio]", "[beep]", "[silence]", "[noise]"):
        return True
    if re.match(r"^\W*$", t):
        return True
    return False


import io
import wave
import audioop

def _read_wav_frames_from_bytes(wav_bytes: bytes):
    try:
        with io.BytesIO(wav_bytes) as b:
            with wave.open(b, "rb") as w:
                sr = w.getframerate()
                sampwidth = w.getsampwidth()
                nch = w.getnchannels()
                pcm = w.readframes(w.getnframes())
        return sr, sampwidth, nch, pcm
    except Exception:
        raise


def _frames_from_pcm(pcm_bytes: bytes, frame_ms: int, sample_rate: int):
    bytes_per_frame = int(sample_rate * (frame_ms / 1000.0) * 2)
    for i in range(0, len(pcm_bytes), bytes_per_frame):
        yield pcm_bytes[i:i+bytes_per_frame]


def _audio_has_speech_vad(wav_bytes: bytes, aggressiveness: int = 2, frame_ms: int = 30, speech_ratio_threshold: float = 0.10) -> bool:
    try:
        sr, sampwidth, nch, pcm = _read_wav_frames_from_bytes(wav_bytes)
    except Exception:
        return True
    if sampwidth != 2 or nch != 1 or sr not in (8000, 16000, 32000, 48000):
        return True
    try:
        import webrtcvad
    except Exception:
        return True
    vad = webrtcvad.Vad(int(aggressiveness))
    frames = list(_frames_from_pcm(pcm, frame_ms, sr))
    if not frames:
        return False
    speech_frames = 0
    full_frame_size = int(sr * (frame_ms / 1000.0) * 2)
    for f in frames:
        if len(f) != full_frame_size:
            f = f.ljust(full_frame_size, b"\x00")
        try:
            if vad.is_speech(f, sr):
                speech_frames += 1
        except Exception:
            return True
    speech_ratio = speech_frames / max(1, len(frames))
    return speech_ratio >= speech_ratio_threshold


def _audio_has_speech_rms(wav_bytes: bytes, rms_threshold: int = 200) -> bool:
    try:
        sr, sampwidth, nch, pcm = _read_wav_frames_from_bytes(wav_bytes)
    except Exception:
        return True
    if sampwidth != 2:
        return True
    try:
        rms = audioop.rms(pcm, 2)
    except Exception:
        return True
    return rms >= rms_threshold


def _dead_air_update(session_id: str, is_blank: bool, threshold: int) -> bool:
    if not DEAD_AIR_ENABLED or not session_id:
        return False

    with DEAD_AIR_LOCK:
        s = DEAD_AIR_STATE.get(session_id, {"consec_blank": 0})
        if is_blank:
            s["consec_blank"] = s.get("consec_blank", 0) + 1
        else:
            s["consec_blank"] = 0
        DEAD_AIR_STATE[session_id] = s
        return s["consec_blank"] >= threshold


async def _run_transcription_server(audio_path: Path, language: str = "en") -> dict:
    """POST audio to the persistent whisper-server; returns normalized CLI-format dict."""
    with open(audio_path, "rb") as f:
        audio_data = f.read()

    resp = await _http_client.post(
        f"{WHISPER_SERVER_URL}/inference",
        files={"file": (audio_path.name, audio_data, "audio/wav")},
        data={"response_format": "verbose_json", "language": language},
    )
    resp.raise_for_status()
    raw = resp.json()

    segments = raw.get("segments", [])
    transcription = [{"text": s.get("text", "")} for s in segments]
    if not transcription:
        text = raw.get("text", "")
        if text:
            transcription = [{"text": text}]

    return {
        "result": {"language": raw.get("language", language)},
        "transcription": transcription,
    }


async def _run_transcription_cli(
    audio_path: Path,
    language: str = "en",
    duration_ms: Optional[int] = None,
    session_id: Optional[str] = None,
) -> dict:
    """Async whisper-cli subprocess fallback. Model reloads per call but doesn't block the event loop."""
    cli = _whisper_cli_path()

    with tempfile.TemporaryDirectory(dir=WORK_DIR) as tmpdir:
        out_base = Path(tmpdir) / "out"
        cmd = [
            str(cli),
            "-m", str(DEFAULT_MODEL),
            "-f", str(audio_path),
            "-l", language,
            "-oj", "-of", str(out_base),
            "-np",
            "-t", "2",
            "-bs", "1",
            "-ac", "256",
        ]
        if duration_ms and duration_ms > 0:
            cmd += ["-d", str(duration_ms)]

        if session_id:
            with ACTIVE_TRANSCRIPTS_LOCK:
                prev = ACTIVE_TRANSCRIPTS.get(session_id)
                if prev and prev.get("proc"):
                    try:
                        prev_proc = prev["proc"]
                        if prev_proc.returncode is None:
                            prev_proc.terminate()
                            try:
                                prev_proc.kill()
                            except Exception:
                                pass
                    except Exception:
                        pass

        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        if session_id:
            with ACTIVE_TRANSCRIPTS_LOCK:
                ACTIVE_TRANSCRIPTS[session_id] = {"proc": proc}

        _stdout, stderr = await proc.communicate()

        if session_id:
            with ACTIVE_TRANSCRIPTS_LOCK:
                if ACTIVE_TRANSCRIPTS.get(session_id, {}).get("proc") is proc:
                    ACTIVE_TRANSCRIPTS.pop(session_id, None)

        if proc.returncode != 0:
            raise RuntimeError(stderr.decode() if stderr else "whisper-cli failed")

        json_path = Path(f"{out_base}.json")
        if not json_path.exists():
            raise RuntimeError("Transcription JSON not created")

        with json_path.open("r", encoding="utf-8") as f:
            data = json.load(f)

    return data


# ── faster-whisper (CTranslate2) engine — WhisperLive's backend ───────────────
_fw_model_lock = threading.Lock()


def _get_fw_model():
    """Lazily load and cache the faster-whisper model (CPU, int8). Stays resident."""
    global _fw_model
    if _fw_model is None:
        with _fw_model_lock:
            if _fw_model is None:
                from faster_whisper import WhisperModel  # imported lazily so the
                # whisper.cpp default works even when faster-whisper isn't installed
                kwargs = {"device": "cpu", "compute_type": FW_COMPUTE}
                if FW_THREADS > 0:
                    kwargs["cpu_threads"] = FW_THREADS
                _fw_model = WhisperModel(FW_MODEL, **kwargs)
    return _fw_model


def _fw_transcribe_sync(audio_path: str, language: str) -> dict:
    """Blocking faster-whisper transcription; returns the normalized CLI-format dict."""
    model = _get_fw_model()
    lang = None if language in ("auto", "", None) else language
    # .en models only support English; force it to avoid CTranslate2 errors
    if FW_MODEL.endswith(".en"):
        lang = "en"
    segments, info = model.transcribe(
        audio_path,
        language=lang,
        beam_size=FW_BEAM,
        vad_filter=FW_VAD,
        condition_on_previous_text=False,
    )
    transcription = [{"text": s.text} for s in segments]
    return {
        "result": {"language": getattr(info, "language", language)},
        "transcription": transcription,
    }


async def _run_transcription_fasterwhisper(audio_path: Path, language: str = "en") -> dict:
    """Run faster-whisper off the event loop so it doesn't block other requests."""
    return await asyncio.to_thread(_fw_transcribe_sync, str(audio_path), language)


async def _run_transcription(
    audio_path: Path,
    language: str = "en",
    duration_ms: Optional[int] = None,
    session_id: Optional[str] = None,
) -> dict:
    """Dispatch to the selected engine; fall back to whisper.cpp server then CLI."""
    if TRANSCRIBE_ENGINE == "fasterwhisper":
        try:
            return await _run_transcription_fasterwhisper(audio_path, language)
        except Exception:
            pass  # fall through to whisper.cpp so a missing dep / bad model never hard-fails
    if _http_client is not None:
        try:
            return await _run_transcription_server(audio_path, language)
        except Exception:
            pass
    return await _run_transcription_cli(audio_path, language, duration_ms, session_id)


def _extract_text(data: dict) -> str:
    parts = []
    for seg in data.get("transcription", []):
        text = seg.get("text", "")
        if text:
            parts.append(text.strip())
    return " ".join(parts).strip()


def _normalize_text(text: str) -> str:
    text = text.lower()
    text = re.sub(r"[^\w\s]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _detect_voicemail(text: str) -> List[str]:
    phrases = _load_phrases()
    normalized = _normalize_text(text)
    matched = [p for p in phrases if _normalize_text(p) in normalized]
    return matched


def _detect_dnc(text: str) -> List[str]:
    dnc = _load_dnc()
    normalized = _normalize_text(text)
    matched = [p for p in dnc if _normalize_text(p) in normalized]
    return matched


@app.get("/health")
async def health():
    info = {"status": "ok", "engine": TRANSCRIBE_ENGINE}
    if TRANSCRIBE_ENGINE == "fasterwhisper":
        info["fw_model"] = FW_MODEL
        info["fw_compute"] = FW_COMPUTE
        info["fw_loaded"] = _fw_model is not None
    return info


@app.post("/transcribe")
async def transcribe(
    audio: UploadFile = File(...),
    language: str = Form("en"),
    duration_ms: Optional[int] = Form(None),
    _auth: None = Depends(_authorize),
):
    if audio.content_type and not (audio.content_type.startswith("audio/") or audio.content_type == "application/octet-stream"):
        raise HTTPException(status_code=400, detail="File must be audio")

    with tempfile.NamedTemporaryFile(delete=False, suffix=Path(audio.filename or "audio.wav").suffix) as tmp:
        shutil.copyfileobj(audio.file, tmp)
        tmp_path = Path(tmp.name)

    try:
        data = await _run_transcription(tmp_path, language=language, duration_ms=duration_ms)
        text = _extract_text(data)
        return JSONResponse({
            "text": text,
            "language": data.get("result", {}).get("language", language),
            "segments": data.get("transcription", []),
        })
    finally:
        tmp_path.unlink(missing_ok=True)


@app.post("/voicemail")
async def voicemail(
    audio: UploadFile = File(...),
    language: str = Form("en"),
    decision_window_ms: int = Form(2000),
    session_id: str = Form("default"),
    dead_air_threshold: Optional[int] = Form(None),
    _auth: None = Depends(_authorize),
):
    if audio.content_type and not (audio.content_type.startswith("audio/") or audio.content_type == "application/octet-stream"):
        raise HTTPException(status_code=400, detail="File must be audio")

    with tempfile.NamedTemporaryFile(delete=False, suffix=Path(audio.filename or "audio.wav").suffix) as tmp:
        shutil.copyfileobj(audio.file, tmp)
        tmp_path = Path(tmp.name)

    try:
        data = await _run_transcription(tmp_path, language=language, duration_ms=decision_window_ms, session_id=session_id)
        text = _extract_text(data)
        matched = _detect_voicemail(text)

        threshold = dead_air_threshold if dead_air_threshold is not None else DEAD_AIR_THRESHOLD_DEFAULT
        is_blank = _is_blank_text(text)
        dead_air = _dead_air_update(session_id, is_blank, threshold)

        return JSONResponse({
            "text": text,
            "language": data.get("result", {}).get("language", language),
            "decision_window_ms": decision_window_ms,
            "session_id": session_id,
            "voicemail": len(matched) > 0,
            "matched_phrases": matched,
            "dead_air": dead_air,
        })
    finally:
        tmp_path.unlink(missing_ok=True)


@app.post("/voicemail-json")
async def voicemail_json(
    payload: dict,
    x_call_id: Optional[str] = Header(None, alias="X-Call-ID"),
    _auth: None = Depends(_authorize),
):
    provided_text = payload.get("text")
    language = payload.get("language", "en")
    decision_window_ms = int(payload.get("decision_window_ms", 2000))
    session_id = payload.get("session_id") or x_call_id or "default"
    chunk_index = payload.get("chunk_index")
    dead_air_threshold = payload.get("dead_air_threshold")

    if provided_text is not None:
        matched = _detect_voicemail(provided_text)
        dnc_matched = _detect_dnc(provided_text)
        threshold = int(dead_air_threshold) if dead_air_threshold is not None else DEAD_AIR_THRESHOLD_DEFAULT
        is_blank = _is_blank_text(provided_text)
        dead_air = _dead_air_update(session_id, is_blank, threshold)

        resp = {
            "text": provided_text,
            "language": language,
            "decision_window_ms": decision_window_ms,
            "session_id": session_id,
            "voicemail": len(matched) > 0,
            "matched_phrases": matched,
            "dnc": len(dnc_matched) > 0,
            "dnc_phrases": dnc_matched,
            "dead_air": dead_air,
        }
        if chunk_index is not None:
            resp["chunk_index"] = chunk_index
        return JSONResponse(resp)

    audio_b64 = payload.get("audio_base64")
    if not audio_b64:
        raise HTTPException(status_code=400, detail="audio_base64 is required")

    try:
        audio_bytes = base64.b64decode(audio_b64)
    except Exception:
        raise HTTPException(status_code=400, detail="audio_base64 is invalid")

    try:
        has_speech = _audio_has_speech_vad(audio_bytes)
    except Exception:
        try:
            has_speech = _audio_has_speech_rms(audio_bytes)
        except Exception:
            has_speech = True

    if not has_speech:
        text = "[BLANK_AUDIO]"
        matched = []
        dnc_matched = []
        threshold = int(dead_air_threshold) if dead_air_threshold is not None else DEAD_AIR_THRESHOLD_DEFAULT
        dead_air = _dead_air_update(session_id, True, threshold)
        resp = {
            "text": text,
            "language": language,
            "decision_window_ms": decision_window_ms,
            "session_id": session_id,
            "voicemail": False,
            "matched_phrases": matched,
            "dnc": False,
            "dnc_phrases": dnc_matched,
            "dead_air": dead_air,
        }
        if chunk_index is not None:
            resp["chunk_index"] = chunk_index
        return JSONResponse(resp)

    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(audio_bytes)
        tmp_path = Path(tmp.name)

    try:
        data = await _run_transcription(tmp_path, language=language, duration_ms=decision_window_ms, session_id=session_id)
        text = _extract_text(data)
        matched = _detect_voicemail(text)
        dnc_matched = _detect_dnc(text)

        threshold = int(dead_air_threshold) if dead_air_threshold is not None else DEAD_AIR_THRESHOLD_DEFAULT
        is_blank = _is_blank_text(text)
        dead_air = _dead_air_update(session_id, is_blank, threshold)

        resp = {
            "text": text,
            "language": data.get("result", {}).get("language", language),
            "decision_window_ms": decision_window_ms,
            "session_id": session_id,
            "voicemail": len(matched) > 0,
            "matched_phrases": matched,
            "dnc": len(dnc_matched) > 0,
            "dnc_phrases": dnc_matched,
            "dead_air": dead_air,
        }
        if chunk_index is not None:
            resp["chunk_index"] = chunk_index
        return JSONResponse(resp)
    finally:
        tmp_path.unlink(missing_ok=True)


from fastapi import Request


# ── WebSocket streaming transcription ─────────────────────────────────────────

def _ws_authorized(api_key: Optional[str]) -> bool:
    if not API_KEY and not BASIC_AUTH_USER:
        return True
    if API_KEY and api_key == API_KEY:
        return True
    return False


@app.websocket("/ws/transcribe")
async def ws_transcribe(
    websocket: WebSocket,
    api_key: Optional[str] = None,
    language: str = "en",
    session_id: Optional[str] = None,
    detect_voicemail: bool = True,
    detect_dnc: bool = False,
    dead_air_threshold: Optional[int] = None,
):
    """
    Real-time streaming transcription over WebSocket.

    Protocol:
      Client → server:
        Binary frame:  raw WAV bytes for one audio chunk
        Text frame:    JSON control message, e.g. {"type": "end"}

      Server → client (JSON):
        {"type": "partial", "text": "...", "voicemail": false, "matched_phrases": [], "dnc": false, "dead_air": false, "chunk_index": N}
        {"type": "final",   "text": "...", "voicemail": false, "matched_phrases": [], "dnc": false}
        {"type": "error",   "message": "..."}

    Auth: pass api_key as query param, e.g. /ws/transcribe?api_key=xxx
    """
    if not _ws_authorized(api_key):
        await websocket.close(code=4001, reason="Unauthorized")
        return

    await websocket.accept()

    sid = session_id or f"ws-{id(websocket)}"
    threshold = dead_air_threshold if dead_air_threshold is not None else DEAD_AIR_THRESHOLD_DEFAULT
    accumulated_text: list[str] = []
    chunk_index = 0

    try:
        while True:
            msg = await websocket.receive()

            # Control message
            if "text" in msg and msg["text"]:
                try:
                    ctrl = json.loads(msg["text"])
                except Exception:
                    await websocket.send_json({"type": "error", "message": "Invalid JSON control message"})
                    continue

                if ctrl.get("type") == "end":
                    final_text = " ".join(accumulated_text).strip()
                    matched = _detect_voicemail(final_text) if detect_voicemail else []
                    dnc_matched = _detect_dnc(final_text) if detect_dnc else []
                    await websocket.send_json({
                        "type": "final",
                        "text": final_text,
                        "voicemail": len(matched) > 0,
                        "matched_phrases": matched,
                        "dnc": len(dnc_matched) > 0,
                        "dnc_phrases": dnc_matched,
                    })
                    break
                continue

            # Audio chunk (binary)
            audio_bytes = msg.get("bytes")
            if not audio_bytes:
                continue

            # VAD pre-filter — skip silent chunks cheaply
            try:
                has_speech = _audio_has_speech_vad(audio_bytes)
            except Exception:
                try:
                    has_speech = _audio_has_speech_rms(audio_bytes)
                except Exception:
                    has_speech = True

            if not has_speech:
                dead_air = _dead_air_update(sid, True, threshold)
                await websocket.send_json({
                    "type": "partial",
                    "text": "[BLANK_AUDIO]",
                    "voicemail": False,
                    "matched_phrases": [],
                    "dnc": False,
                    "dnc_phrases": [],
                    "dead_air": dead_air,
                    "chunk_index": chunk_index,
                })
                chunk_index += 1
                continue

            # Write chunk to temp file and transcribe
            with tempfile.NamedTemporaryFile(delete=False, suffix=".wav", dir=WORK_DIR) as tmp:
                tmp.write(audio_bytes)
                tmp_path = Path(tmp.name)

            try:
                data = await _run_transcription(tmp_path, language=language, session_id=sid)
                text = _extract_text(data)
            except Exception as exc:
                await websocket.send_json({"type": "error", "message": str(exc), "chunk_index": chunk_index})
                chunk_index += 1
                continue
            finally:
                tmp_path.unlink(missing_ok=True)

            if text and not _is_blank_text(text):
                accumulated_text.append(text)

            matched = _detect_voicemail(text) if detect_voicemail else []
            dnc_matched = _detect_dnc(text) if detect_dnc else []
            dead_air = _dead_air_update(sid, _is_blank_text(text), threshold)

            await websocket.send_json({
                "type": "partial",
                "text": text,
                "voicemail": len(matched) > 0,
                "matched_phrases": matched,
                "dnc": len(dnc_matched) > 0,
                "dnc_phrases": dnc_matched,
                "dead_air": dead_air,
                "chunk_index": chunk_index,
            })
            chunk_index += 1

    except WebSocketDisconnect:
        pass
    except Exception as exc:
        try:
            await websocket.send_json({"type": "error", "message": str(exc)})
        except Exception:
            pass


def _read_file_atomic(path: Path) -> str:
    try:
        if not path.exists():
            return ""
        with path.open("r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        raise HTTPException(status_code=500, detail="Failed to read file")


def _write_file_atomic(path: Path, content: str):
    try:
        tmp = path.with_suffix(path.suffix + ".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            f.write(content)
        tmp.replace(path)
    except Exception:
        raise HTTPException(status_code=500, detail="Failed to write file")


@app.get("/admin/phrases")
async def admin_get_phrases(_auth: None = Depends(_authorize)):
    content = _read_file_atomic(PHRASES_FILE)
    return JSONResponse({"content": content})


@app.post("/admin/phrases")
async def admin_post_phrases(request: Request, _auth: None = Depends(_authorize)):
    payload = await request.json()
    content = payload.get("content")
    if content is None:
        raise HTTPException(status_code=400, detail="content is required")
    if not PHRASES_FILE.parent.exists():
        PHRASES_FILE.parent.mkdir(parents=True, exist_ok=True)
    _write_file_atomic(PHRASES_FILE, content)
    global _PHRASES_CACHE, _PHRASES_MTIME
    _PHRASES_CACHE = None
    _PHRASES_MTIME = 0.0
    return JSONResponse({"status": "ok"})


@app.get("/admin/dnc")
async def admin_get_dnc(_auth: None = Depends(_authorize)):
    content = _read_file_atomic(DNC_FILE)
    return JSONResponse({"content": content})


@app.post("/admin/dnc")
async def admin_post_dnc(request: Request, _auth: None = Depends(_authorize)):
    payload = await request.json()
    content = payload.get("content")
    if content is None:
        raise HTTPException(status_code=400, detail="content is required")
    if not DNC_FILE.parent.exists():
        DNC_FILE.parent.mkdir(parents=True, exist_ok=True)
    _write_file_atomic(DNC_FILE, content)
    global _DNC_CACHE, _DNC_MTIME
    _DNC_CACHE = None
    _DNC_MTIME = 0.0
    return JSONResponse({"status": "ok"})


# ── Session auth ──────────────────────────────────────────────────────────────

SESSION_TOKEN_TTL = 24 * 3600  # 24 hours


def _sign_token(username: str) -> str:
    ts = str(int(time.time()))
    payload = f"{username}:{ts}"
    secret = (API_KEY or "fallback-secret").encode()
    sig = hmac.new(secret, payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}:{sig}"


def _verify_session_token(token: str) -> bool:
    try:
        username, ts, sig = token.rsplit(":", 2)
        payload = f"{username}:{ts}"
        secret = (API_KEY or "fallback-secret").encode()
        expected = hmac.new(secret, payload.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            return False
        return time.time() - int(ts) < SESSION_TOKEN_TTL
    except Exception:
        return False


@app.post("/auth/login")
async def auth_login(request: Request):
    payload = await request.json()
    password = payload.get("password", "")
    if not BASIC_AUTH_PASS:
        raise HTTPException(status_code=503, detail="Auth not configured")
    if password == BASIC_AUTH_PASS:
        token = _sign_token(BASIC_AUTH_USER or "admin")
        response = JSONResponse({"status": "ok"})
        response.set_cookie(
            "ss_token", token,
            httponly=True, samesite="lax", max_age=SESSION_TOKEN_TTL,
        )
        return response
    raise HTTPException(status_code=401, detail="Invalid password")


@app.get("/auth/verify")
async def auth_verify(ss_token: Optional[str] = Cookie(None)):
    if ss_token and _verify_session_token(ss_token):
        return JSONResponse({"status": "ok"})
    raise HTTPException(status_code=401, detail="Unauthorized")


@app.post("/auth/logout")
async def auth_logout():
    response = JSONResponse({"status": "ok"})
    response.delete_cookie("ss_token")
    return response


# ---------------------------------------------------------------------------
# Book a Demo  (/book-demo)
# ---------------------------------------------------------------------------

def _admin_email_html(name: str, email: str, company: str, phone: str, message: str) -> str:
    escaped = {k: v.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
               for k, v in dict(name=name, email=email, company=company or "—",
                                phone=phone or "—", message=message).items()}
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/></head>
<body style="margin:0;padding:0;background:#0a0e1a;font-family:'Segoe UI',Helvetica,Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#0a0e1a;padding:40px 20px;">
<tr><td align="center">
<table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;background:linear-gradient(145deg,#0f131f,#0a0e1a);border:1px solid rgba(173,198,255,0.15);border-radius:16px;overflow:hidden;">
  <tr><td style="padding:32px;text-align:center;border-bottom:1px solid rgba(255,255,255,0.05);">
    <img src="https://vm.karims.dev/logo-wordmark.svg" width="200" height="53" alt="KA Voicemail" style="display:block;margin:0 auto 14px;border:0;max-width:100%;"/>
    <p style="margin:0;font-size:11px;color:#8c909f;text-transform:uppercase;letter-spacing:2px;">New Demo Request</p>
  </td></tr>
  <tr><td style="padding:32px;">
    <table width="100%" cellpadding="0" cellspacing="0">
      <tr>
        <td width="50%" valign="top" style="padding:0 8px 20px 0;">
          <div style="font-size:11px;color:#8c909f;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px;">Name</div>
          <div style="background:rgba(173,198,255,0.05);border:1px solid rgba(173,198,255,0.12);border-radius:8px;padding:12px 14px;font-size:15px;color:#dfe2f3;">{escaped['name']}</div>
        </td>
        <td width="50%" valign="top" style="padding:0 0 20px 8px;">
          <div style="font-size:11px;color:#8c909f;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px;">Email</div>
          <div style="background:rgba(173,198,255,0.05);border:1px solid rgba(173,198,255,0.12);border-radius:8px;padding:12px 14px;font-size:15px;"><a href="mailto:{escaped['email']}" style="color:#adc6ff;text-decoration:none;">{escaped['email']}</a></div>
        </td>
      </tr>
      <tr>
        <td width="50%" valign="top" style="padding:0 8px 20px 0;">
          <div style="font-size:11px;color:#8c909f;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px;">Company</div>
          <div style="background:rgba(173,198,255,0.05);border:1px solid rgba(173,198,255,0.12);border-radius:8px;padding:12px 14px;font-size:15px;color:#dfe2f3;">{escaped['company']}</div>
        </td>
        <td width="50%" valign="top" style="padding:0 0 20px 8px;">
          <div style="font-size:11px;color:#8c909f;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px;">Phone</div>
          <div style="background:rgba(173,198,255,0.05);border:1px solid rgba(173,198,255,0.12);border-radius:8px;padding:12px 14px;font-size:15px;color:#dfe2f3;">{escaped['phone']}</div>
        </td>
      </tr>
      <tr>
        <td colspan="2" style="padding-bottom:28px;">
          <div style="font-size:11px;color:#8c909f;text-transform:uppercase;letter-spacing:1px;margin-bottom:6px;">Use Case</div>
          <div style="background:rgba(173,198,255,0.05);border:1px solid rgba(173,198,255,0.12);border-radius:8px;padding:16px;font-size:15px;color:#dfe2f3;line-height:1.7;white-space:pre-wrap;">{escaped['message']}</div>
        </td>
      </tr>
    </table>
    <table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
      <a href="mailto:{escaped['email']}?subject=Re:%20KA%20Voicemail%20Demo%20Request"
         style="display:inline-block;background:linear-gradient(135deg,#adc6ff,#4cd7f6);color:#002e6a;text-decoration:none;font-weight:700;padding:13px 32px;border-radius:8px;font-size:15px;">Reply to {escaped['name']}</a>
    </td></tr></table>
  </td></tr>
  <tr><td style="padding:20px 32px;text-align:center;font-size:12px;color:#424754;border-top:1px solid rgba(255,255,255,0.04);">
    © 2026 KA Voicemail &nbsp;·&nbsp; <a href="https://vm.karims.dev" style="color:#8c909f;text-decoration:none;">vm.karims.dev</a>
  </td></tr>
</table>
</td></tr>
</table>
</body></html>"""


def _confirm_email_html(name: str) -> str:
    safe_name = name.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/></head>
<body style="margin:0;padding:0;background:#0a0e1a;font-family:'Segoe UI',Helvetica,Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#0a0e1a;padding:40px 20px;">
<tr><td align="center">
<table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;background:linear-gradient(145deg,#0f131f,#0a0e1a);border:1px solid rgba(173,198,255,0.15);border-radius:16px;overflow:hidden;">
  <tr><td style="background:linear-gradient(135deg,rgba(173,198,255,0.07),rgba(76,215,246,0.07));padding:36px 32px 28px;text-align:center;border-bottom:1px solid rgba(255,255,255,0.05);">
    <img src="https://vm.karims.dev/logo-wordmark.svg" width="210" height="45" alt="KA Voicemail" style="display:block;margin:0 auto 16px;border:0;"/>
    <h1 style="margin:0 0 8px;font-size:22px;font-weight:700;color:#dfe2f3;">You're on the list!</h1>
    <p style="margin:0;font-size:14px;color:#8c909f;">We'll be in touch shortly to schedule your demo.</p>
  </td></tr>
  <tr><td style="padding:36px 32px;">
    <p style="margin:0 0 16px;font-size:16px;color:#c2c6d6;line-height:1.7;">Hi {safe_name},</p>
    <p style="margin:0 0 24px;font-size:15px;color:#8c909f;line-height:1.8;">Thank you for requesting a demo of <strong style="color:#adc6ff;">KA Voicemail</strong>. We've received your details and will reach out within 1 business day to schedule a time that works for you.</p>
    <div style="background:rgba(173,198,255,0.05);border:1px solid rgba(173,198,255,0.15);border-left:3px solid #adc6ff;border-radius:8px;padding:20px 24px;margin:0 0 28px;">
      <p style="margin:0 0 10px;font-size:12px;color:#8c909f;text-transform:uppercase;letter-spacing:1px;">What to expect</p>
      <ul style="margin:0;padding:0 0 0 18px;color:#c2c6d6;font-size:14px;line-height:2.2;">
        <li>30-minute live walkthrough of the API</li>
        <li>Real-time voicemail detection demo</li>
        <li>Integration Q&amp;A with the team</li>
      </ul>
    </div>
    <table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
      <a href="https://vm.karims.dev/docs.html"
         style="display:inline-block;background:linear-gradient(135deg,#adc6ff,#4cd7f6);color:#002e6a;text-decoration:none;font-weight:700;padding:13px 32px;border-radius:8px;font-size:15px;">Explore the API Docs</a>
    </td></tr></table>
  </td></tr>
  <tr><td style="padding:20px 32px;text-align:center;font-size:12px;color:#424754;border-top:1px solid rgba(255,255,255,0.04);">
    © 2026 KA Voicemail &nbsp;·&nbsp; <a href="https://vm.karims.dev" style="color:#8c909f;text-decoration:none;">vm.karims.dev</a>
  </td></tr>
</table>
</td></tr>
</table>
</body></html>"""


@app.post("/book-demo")
async def book_demo(request: Request):
    if not RESEND_API_KEY:
        raise HTTPException(status_code=503, detail="Email service not configured")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")

    name    = (body.get("name")    or "").strip()
    email   = (body.get("email")   or "").strip()
    company = (body.get("company") or "").strip()
    phone   = (body.get("phone")   or "").strip()
    message = (body.get("message") or "").strip()

    if not name or not email or not message:
        raise HTTPException(status_code=400, detail="name, email, and message are required")

    headers = {
        "Authorization": f"Bearer {RESEND_API_KEY}",
        "Content-Type": "application/json",
    }
    async with httpx.AsyncClient(timeout=15) as client:
        r1 = await client.post("https://api.resend.com/emails", headers=headers, json={
            "from": SMTP_FROM,
            "to": [CONTACT_EMAIL],
            "reply_to": email,
            "subject": f"Demo Request from {name}",
            "html": _admin_email_html(name, email, company, phone, message),
        })
        if r1.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"Email send failed: {r1.text}")
        r2 = await client.post("https://api.resend.com/emails", headers=headers, json={
            "from": SMTP_FROM,
            "to": [email],
            "subject": "Your KA Voicemail demo request — we’ll be in touch",
            "html": _confirm_email_html(name),
        })
        if r2.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"Confirmation email failed: {r2.text}")

    return JSONResponse({"status": "ok"})
