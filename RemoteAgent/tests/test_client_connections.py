"""New Mac-local connection proxy: authenticated routing without wrong-model fallback."""
from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

AGENT_DIR = Path(__file__).resolve().parents[1]
if str(AGENT_DIR) not in sys.path:
    sys.path.insert(0, str(AGENT_DIR))

import client_connections as connection
import modelmatrix_agent as agent
from agent_core import Profile, ProfileConflictError, UsageError


class Response:
    status = 200
    headers = {"Content-Type": "text/event-stream"}
    def __init__(self): self.body = io.BytesIO(b'data: {"model":"wire-upstream"}\n\ndata: [DONE]\n\n')
    def read1(self, size): return self.body.read(size)
    def __enter__(self): return self
    def __exit__(self, *args): return False


class Handler:
    def __init__(self, service, path):
        self.service, self.path = service, path
        self.wfile = io.BytesIO()
        self.headers_sent = {}
        self.status = None
        self.close_connection = False
    def send_response(self, status): self.status = status
    def send_header(self, name, value): self.headers_sent[name] = value
    def end_headers(self): pass
    def _send_json(self, status, body): self.status = status; self.wfile.write(json.dumps(body).encode())


class ConnectionProxyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name)
        self.file = self.folder / "one.env"
        self.file.write_text("REQUEST_MODEL=matrix-one\nPORT=18081\n")
        self.profile = Profile("one", {"REQUEST_MODEL": "matrix-one", "PORT": "18081", "RUNTIME": "llamacpp",
            "CONTEXT_SIZE": "8192", "UPSTREAM_MODEL": "wire-upstream"})
        self.service = SimpleNamespace(configuration=SimpleNamespace(profiles_directory=self.folder),
            profiles=SimpleNamespace(load=lambda: {"one": self.profile}, profile=lambda name: self.profile),
            status_payload=lambda: {"statuses": [{"profile": "one", "ready": True, "running": True}]})
        self.identity = connection.connection_profiles(self.service)["profiles"][0]["identity_token"]
        self.handler = Handler(self.service, "/api/connect/inference?profile=one&identity=" + self.identity)
    def tearDown(self): self.tmp.cleanup()
    def test_profiles_are_read_only_and_context_is_runtime_qualified(self):
        before = self.file.read_bytes()
        rows = connection.connection_profiles(self.service)["profiles"]
        self.assertEqual(rows[0]["model_id"], "matrix-one")
        self.assertEqual(rows[0]["context"], 8192)
        self.assertEqual(before, self.file.read_bytes())
        self.profile.values["RUNTIME"] = "mlx"
        self.assertIsNone(connection.connection_profiles(self.service)["profiles"][0]["context"])
    def test_wrong_model_is_rejected_before_upstream(self):
        with mock.patch.object(connection.urllib.request, "build_opener") as upstream:
            with self.assertRaises(UsageError):
                connection.forward_connection(self.handler, b'{"model":"another-model"}')
            upstream.assert_not_called()
    def test_missing_model_is_rejected(self):
        with self.assertRaises(UsageError): connection.forward_connection(self.handler, b'{"messages":[]}')
    def test_changed_profile_identity_is_rejected(self):
        self.handler.path = "/api/connect/inference?profile=one&identity=wrong"
        with self.assertRaises(ProfileConflictError): connection.forward_connection(self.handler, b'{"model":"matrix-one"}')
    def test_unready_model_is_not_started_or_retargeted(self):
        self.service.status_payload = lambda: {"statuses": [{"profile": "one", "ready": False, "running": False}]}
        with self.assertRaises(ProfileConflictError): connection.forward_connection(self.handler, b'{"model":"matrix-one"}')
    def test_unsupported_protocol_is_rejected(self):
        self.handler.path += "&endpoint=/v1/embeddings"
        with self.assertRaises(UsageError): connection.forward_connection(self.handler, b'{"model":"matrix-one"}')
    def test_stream_and_wire_id_survive_without_gateway_auth_forwarding(self):
        opener = mock.Mock()
        opener.open.return_value = Response()
        with mock.patch.object(connection.urllib.request, "build_opener", return_value=opener):
            connection.forward_connection(self.handler, b'{"model":"matrix-one","stream":true}')
        request = opener.open.call_args.args[0]
        self.assertEqual(json.loads(request.data)["model"], "wire-upstream")
        self.assertIsNone(request.get_header("Authorization"))
        self.assertIn(b"[DONE]", self.handler.wfile.getvalue())
        self.assertEqual(self.handler.headers_sent["Connection"], "close")
    def test_cross_host_redirect_is_not_followed(self):
        self.assertIsNone(connection._NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))
    def test_agent_proxy_is_inside_existing_auth_guard(self):
        h = object.__new__(agent.AgentRequestHandler)
        h.auth_token = "fixture-private-gateway-token"
        h.headers = {}
        h.close_connection = False
        h._send_json = mock.Mock()
        self.assertFalse(h._accept_request("/api/connect/inference"))
        self.assertEqual(h._send_json.call_args.args[0], 401)


if __name__ == "__main__": unittest.main()
