import json
import os
import socket
import struct
import threading
import unittest
from types import SimpleNamespace

from tool.google_translation_bridge import (
    MockTranslationSession,
    SessionConfig,
    handle_client,
    normalize_google_response,
    parse_start_message,
)


class FakeConnection:
    def __init__(self):
        self.events = []

    def send_json(self, payload):
        self.events.append(payload)


class GoogleTranslationBridgeTest(unittest.TestCase):
    def test_parse_start_message(self):
        config = parse_start_message(
            {
                "type": "session.start",
                "source_language_code": "ko",
                "target_language_code": "ja",
                "audio": {
                    "encoding": "linear16",
                    "sample_rate_hz": 16000,
                },
            }
        )

        self.assertEqual(config.source_language_code, "ko")
        self.assertEqual(config.target_language_code, "ja")
        self.assertEqual(config.audio_encoding, "linear16")
        self.assertEqual(config.sample_rate_hz, 16000)

    def test_normalize_google_interim_translation(self):
        response = SimpleNamespace(
            error=None,
            result=SimpleNamespace(
                text_translation_result=SimpleNamespace(
                    translation="\u3053\u3093\u306b\u3061\u306f",
                    is_final=False,
                )
            ),
        )

        self.assertEqual(
            normalize_google_response(response),
            {
                "type": "translation.delta",
                "delta": "\u3053\u3093\u306b\u3061\u306f",
            },
        )

    def test_normalize_google_final_translation(self):
        response = SimpleNamespace(
            error=None,
            result=SimpleNamespace(
                text_translation_result=SimpleNamespace(
                    translation="\u3053\u3093\u306b\u3061\u306f",
                    is_final=True,
                )
            ),
        )

        self.assertEqual(
            normalize_google_response(response),
            {
                "type": "translation.done",
                "transcript": "\u3053\u3093\u306b\u3061\u306f",
            },
        )

    def test_normalize_google_error(self):
        response = SimpleNamespace(
            error=SimpleNamespace(message="bad request", code=3),
            result=None,
        )

        self.assertEqual(
            normalize_google_response(response),
            {"type": "error", "error": {"message": "bad request", "code": 3}},
        )

    def test_mock_session_emits_contract_events(self):
        conn = FakeConnection()
        session = MockTranslationSession(conn, "source", "target", 0)

        session.start(SessionConfig("ko", "ja"))
        session._emit()
        session.close()

        types = [event["type"] for event in conn.events]
        self.assertIn("session.started", types)
        self.assertIn("source_transcript.delta", types)
        self.assertIn("source_transcript.done", types)
        self.assertIn("translation.delta", types)
        self.assertIn("translation.done", types)
        self.assertIn("session.closed", types)

    def test_contract_messages_are_json_serializable(self):
        conn = FakeConnection()
        session = MockTranslationSession(conn, "source", "target", 0)
        session.start(SessionConfig("ko", "ja"))
        for event in conn.events:
            json.dumps(event)

    def test_mock_bridge_websocket_round_trip(self):
        client, server = socket.socketpair()

        def factory(conn):
            return MockTranslationSession(conn, "source", "target", 0)

        thread = threading.Thread(
            target=handle_client,
            args=(server, "mock", factory, ""),
            daemon=True,
        )
        thread.start()

        client.sendall(
            b"GET / HTTP/1.1\r\n"
            b"Host: localhost\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n"
            b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            b"Sec-WebSocket-Version: 13\r\n"
            b"\r\n"
        )
        self.assertIn(b"101 Switching Protocols", client.recv(4096))

        send_client_text(
            client,
            json.dumps(
                {
                    "type": "session.start",
                    "source_language_code": "ko",
                    "target_language_code": "ja",
                    "audio": {"encoding": "linear16", "sample_rate_hz": 16000},
                }
            ),
        )
        self.assertEqual(read_server_json(client)["type"], "session.started")

        send_client_text(
            client,
            json.dumps(
                {
                    "type": "audio.append",
                    "audio": "AQID",
                }
            ),
        )
        seen = {read_server_json(client)["type"] for _ in range(4)}
        self.assertEqual(
            seen,
            {
                "source_transcript.delta",
                "source_transcript.done",
                "translation.delta",
                "translation.done",
            },
        )

        send_client_text(client, json.dumps({"type": "session.stop"}))
        self.assertEqual(read_server_json(client)["type"], "session.closed")
        client.close()
        thread.join(timeout=1)


def send_client_text(sock, text):
    payload = text.encode("utf-8")
    mask = os.urandom(4)
    length = len(payload)
    if length < 126:
        header = struct.pack("!BB", 0x81, 0x80 | length)
    elif length <= 0xFFFF:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, length)
    else:
        header = struct.pack("!BBQ", 0x81, 0x80 | 127, length)
    masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    sock.sendall(header + mask + masked)


def read_server_json(sock):
    first, second = sock.recv(2)
    opcode = first & 0x0F
    if opcode == 0x8:
        return {"type": "closed"}
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", sock.recv(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", sock.recv(8))[0]
    payload = sock.recv(length)
    return json.loads(payload.decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
