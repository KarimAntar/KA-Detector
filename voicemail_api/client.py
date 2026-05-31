import requests

BASE_URL = "https://ss.karims.dev"
API_KEY = "<YOUR_API_KEY>"


def transcribe(audio_path: str, language: str = "en", duration_ms: int | None = None):
    files = {"audio": open(audio_path, "rb")}
    data = {"language": language}
    if duration_ms is not None:
        data["duration_ms"] = str(duration_ms)
    headers = {"X-API-Key": API_KEY}
    resp = requests.post(f"{BASE_URL}/transcribe", files=files, data=data, headers=headers, timeout=300)
    resp.raise_for_status()
    return resp.json()


def voicemail(audio_path: str, language: str = "en", decision_window_ms: int = 8000, session_id: str = "default", dead_air_threshold: int = 2):
    files = {"audio": open(audio_path, "rb")}
    data = {
        "language": language,
        "decision_window_ms": str(decision_window_ms),
        "session_id": session_id,
        "dead_air_threshold": str(dead_air_threshold),
    }
    headers = {"X-API-Key": API_KEY}
    resp = requests.post(f"{BASE_URL}/voicemail", files=files, data=data, headers=headers, timeout=300)
    resp.raise_for_status()
    return resp.json()


def voicemail_json(audio_path: str, language: str = "en", decision_window_ms: int = 4000, session_id: str = "default", dead_air_threshold: int = 2):
    with open(audio_path, "rb") as f:
        audio_b64 = requests.utils.to_native_string(__import__("base64").b64encode(f.read()))
    payload = {
        "audio_base64": audio_b64,
        "language": language,
        "decision_window_ms": decision_window_ms,
        "session_id": session_id,
        "dead_air_threshold": dead_air_threshold,
    }
    headers = {"X-API-Key": API_KEY}
    resp = requests.post(f"{BASE_URL}/voicemail-json", json=payload, headers=headers, timeout=300)
    resp.raise_for_status()
    return resp.json()


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 3:
        print("Usage: python client.py [transcribe|voicemail|voicemail_json] /path/to/audio.wav")
        raise SystemExit(1)

    cmd, audio = sys.argv[1], sys.argv[2]
    if cmd == "transcribe":
        print(transcribe(audio))
    elif cmd == "voicemail":
        print(voicemail(audio))
    elif cmd == "voicemail_json":
        print(voicemail_json(audio))
    else:
        print("Unknown command")
