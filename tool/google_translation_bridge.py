#!/usr/bin/env python3
"""WebSocket bridge for Google Cloud Media Translation.

The Flutter app should not keep Google service-account credentials. This bridge
owns Google auth server-side and exposes the small JSON/WebSocket protocol used
by GoogleTranslationBridgeService.

Run a local mock:

    python3 tool/google_translation_bridge.py --provider mock

Run against Google Cloud ADC:

    python3 -m pip install google-cloud-media-translation
    GOOGLE_APPLICATION_CREDENTIALS=/path/key.json \
      python3 tool/google_translation_bridge.py --provider google
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import queue
import socket
import struct
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterable
from urllib.parse import parse_qs, urlparse


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8787


@dataclass(frozen=True)
class SessionConfig:
    source_language_code: str
    target_language_code: str
    sample_rate_hz: int = 16000
    audio_encoding: str = "linear16"
    single_utterance: bool = False
    google_model: str = ""


def parse_start_message(message: dict[str, Any]) -> SessionConfig:
    audio = as_dict(message.get("audio"))
    source = str(message.get("source_language_code") or "ko").strip()
    target = str(message.get("target_language_code") or "ja").strip()
    if not source or not target:
        raise ValueError("source_language_code and target_language_code are required")
    return SessionConfig(
        source_language_code=source,
        target_language_code=target,
        sample_rate_hz=int(audio.get("sample_rate_hz") or 16000),
        audio_encoding=str(audio.get("encoding") or "linear16"),
        single_utterance=bool(message.get("single_utterance") or False),
        google_model=str(message.get("google_model") or ""),
    )


def normalize_google_response(response: Any) -> dict[str, Any] | None:
    """Convert a Google Media Translation response to app bridge JSON."""
    error = getattr(response, "error", None)
    if error and getattr(error, "message", ""):
        return {
            "type": "error",
            "error": {"message": str(error.message), "code": getattr(error, "code", "")},
        }

    result = getattr(response, "result", None)
    if not result:
        return None
    text_result = getattr(result, "text_translation_result", None)
    if not text_result:
        return None
    translation = str(getattr(text_result, "translation", "") or "").strip()
    if not translation:
        return None
    is_final = bool(getattr(text_result, "is_final", False))
    if is_final:
        return {"type": "translation.done", "transcript": translation}
    return {"type": "translation.delta", "delta": translation}


def as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


class WebSocketConnection:
    def __init__(self, sock: socket.socket):
        self.sock = sock
        self._write_lock = threading.Lock()
        self.closed = False

    def send_json(self, payload: dict[str, Any]) -> None:
        self.send_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))

    def send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode("utf-8"))

    def send_pong(self, payload: bytes) -> None:
        self._send_frame(0xA, payload)

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

    def read_message(self) -> str | bytes | None:
        header = read_exact(self.sock, 2)
        if not header:
            return None
        first, second = header[0], header[1]
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", read_exact(self.sock, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", read_exact(self.sock, 8))[0]
        mask = read_exact(self.sock, 4) if masked else b""
        payload = read_exact(self.sock, length)
        if masked:
            payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))

        if opcode == 0x8:
            return None
        if opcode == 0x9:
            self.send_pong(payload)
            return self.read_message()
        if opcode == 0x1:
            return payload.decode("utf-8")
        if opcode == 0x2:
            return payload
        return None

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self.closed:
            return
        length = len(payload)
        if length < 126:
            header = struct.pack("!BB", 0x80 | opcode, length)
        elif length <= 0xFFFF:
            header = struct.pack("!BBH", 0x80 | opcode, 126, length)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 127, length)
        with self._write_lock:
            self.sock.sendall(header + payload)


class MockTranslationSession:
    def __init__(
        self,
        conn: WebSocketConnection,
        source_text: str,
        translation_text: str,
        delay_seconds: float,
    ):
        self.conn = conn
        self.source_text = source_text
        self.translation_text = translation_text
        self.delay_seconds = delay_seconds
        self._sent = False

    def start(self, _: SessionConfig) -> None:
        self.conn.send_json({"type": "session.started", "provider": "mock"})

    def push_audio(self, chunk: bytes) -> None:
        if self._sent or not chunk:
            return
        self._sent = True
        threading.Thread(target=self._emit, daemon=True).start()

    def close(self) -> None:
        self.conn.send_json({"type": "session.closed"})

    def _emit(self) -> None:
        self.conn.send_json({"type": "source_transcript.delta", "delta": self.source_text})
        time.sleep(self.delay_seconds)
        self.conn.send_json(
            {"type": "source_transcript.done", "transcript": self.source_text}
        )
        self.conn.send_json({"type": "translation.delta", "delta": self.translation_text})
        time.sleep(self.delay_seconds)
        self.conn.send_json(
            {"type": "translation.done", "transcript": self.translation_text}
        )


class GoogleMediaTranslationSession:
    def __init__(self, conn: WebSocketConnection):
        self.conn = conn
        self._audio_queue: queue.Queue[bytes | None] = queue.Queue(maxsize=256)
        self._thread: threading.Thread | None = None

    def start(self, config: SessionConfig) -> None:
        self.conn.send_json({"type": "session.started", "provider": "google.media_translation"})
        self._thread = threading.Thread(target=self._run_google, args=(config,), daemon=True)
        self._thread.start()

    def push_audio(self, chunk: bytes) -> None:
        if not chunk:
            return
        self._audio_queue.put(chunk)

    def close(self) -> None:
        self._audio_queue.put(None)
        if self._thread is not None:
            self._thread.join(timeout=2)
        self.conn.send_json({"type": "session.closed"})

    def _run_google(self, config: SessionConfig) -> None:
        try:
            from google.cloud import mediatranslation_v1beta1 as media
        except Exception as exc:  # pragma: no cover - depends on local install
            self.conn.send_json(
                {
                    "type": "error",
                    "error": {
                        "message": "Install google-cloud-media-translation to use provider=google",
                        "detail": str(exc),
                    },
                }
            )
            return

        try:
            client = media.SpeechTranslationServiceClient()
            streaming_config = media.StreamingTranslateSpeechConfig()
            streaming_config.audio_config.audio_encoding = config.audio_encoding
            streaming_config.audio_config.source_language_code = config.source_language_code
            streaming_config.audio_config.target_language_code = config.target_language_code
            streaming_config.audio_config.sample_rate_hertz = config.sample_rate_hz
            streaming_config.single_utterance = config.single_utterance
            if config.google_model:
                streaming_config.audio_config.model = config.google_model

            requests = self._google_requests(media, streaming_config)
            for response in client.streaming_translate_speech(requests=requests):
                event = normalize_google_response(response)
                if event is not None:
                    self.conn.send_json(event)
        except Exception as exc:  # pragma: no cover - requires Google credentials
            self.conn.send_json({"type": "error", "error": {"message": str(exc)}})

    def _google_requests(self, media: Any, streaming_config: Any) -> Iterable[Any]:
        yield media.StreamingTranslateSpeechRequest(streaming_config=streaming_config)
        while True:
            chunk = self._audio_queue.get()
            if chunk is None:
                return
            yield media.StreamingTranslateSpeechRequest(audio_content=chunk)


def read_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = sock.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("socket closed")
        chunks.extend(chunk)
    return bytes(chunks)


def read_http_headers(sock: socket.socket) -> tuple[str, dict[str, str]]:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("socket closed during handshake")
        data.extend(chunk)
        if len(data) > 65536:
            raise ValueError("handshake too large")
    text = data.decode("iso-8859-1")
    lines = text.split("\r\n")
    request_line = lines[0]
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return request_line, headers


def accept_websocket(sock: socket.socket) -> tuple[WebSocketConnection, str]:
    request_line, headers = read_http_headers(sock)
    if "upgrade" not in headers.get("connection", "").lower():
        raise ValueError("missing websocket upgrade")
    key = headers.get("sec-websocket-key")
    if not key:
        raise ValueError("missing websocket key")
    accept_key = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest())
    response = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept_key.decode()}\r\n"
        "\r\n"
    )
    sock.sendall(response.encode("ascii"))
    path = request_line.split(" ")[1] if " " in request_line else "/"
    query = parse_qs(urlparse(path).query)
    token = query.get("token", [""])[0]
    return WebSocketConnection(sock), token


def handle_client(
    sock: socket.socket,
    provider: str,
    session_factory: Callable[[WebSocketConnection], Any],
    expected_token: str = "",
) -> None:
    conn: WebSocketConnection | None = None
    session: Any | None = None
    try:
        conn, token = accept_websocket(sock)
        if expected_token and token != expected_token:
            conn.send_json({"type": "error", "error": {"message": "invalid token"}})
            return
        while True:
            raw = conn.read_message()
            if raw is None:
                break
            if isinstance(raw, bytes):
                if session is not None:
                    session.push_audio(raw)
                continue
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                conn.send_json({"type": "error", "error": {"message": "invalid json"}})
                continue
            msg_type = message.get("type")
            if msg_type == "session.start":
                config = parse_start_message(message)
                session = session_factory(conn)
                session.start(config)
            elif msg_type == "audio.append":
                if session is None:
                    conn.send_json({"type": "error", "error": {"message": "session not started"}})
                    continue
                audio_b64 = str(message.get("audio") or "")
                session.push_audio(base64.b64decode(audio_b64))
            elif msg_type == "session.stop":
                break
            else:
                conn.send_json(
                    {"type": "error", "error": {"message": f"unsupported message: {msg_type}"}}
                )
    except Exception as exc:
        if conn is not None and not conn.closed:
            conn.send_json({"type": "error", "error": {"message": str(exc)}})
    finally:
        if session is not None:
            session.close()
        if conn is not None:
            conn.close()
        else:
            try:
                sock.close()
            except OSError:
                pass


def serve(args: argparse.Namespace) -> None:
    if args.provider == "mock":
        source = args.mock_source
        translation = args.mock_translation

        def factory(conn: WebSocketConnection) -> MockTranslationSession:
            return MockTranslationSession(conn, source, translation, args.mock_delay)

    else:

        def factory(conn: WebSocketConnection) -> GoogleMediaTranslationSession:
            return GoogleMediaTranslationSession(conn)

    with socket.create_server((args.host, args.port), reuse_port=False) as server:
        print(f"google translation bridge listening on ws://{args.host}:{args.port}")
        print(f"provider={args.provider}")
        while True:
            client, _ = server.accept()
            threading.Thread(
                target=handle_client,
                args=(client, args.provider, factory, args.token),
                daemon=True,
            ).start()


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--provider", choices=["mock", "google"], default="mock")
    parser.add_argument("--token", default="", help="optional query token for ws://.../?token=...")
    parser.add_argument("--mock-source", default="annyeonghaseyo")
    parser.add_argument("--mock-translation", default="konnichiwa")
    parser.add_argument("--mock-delay", type=float, default=0.08)
    return parser


def main() -> int:
    args = build_arg_parser().parse_args()
    serve(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
