from __future__ import annotations

import contextlib
import io
import json
import pathlib
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import irc_health

SENTINEL = "not-a-real-credential"
SERVER = "irc.example.invalid"


def _network(
    name: str,
    *,
    enabled: bool = True,
    connected: bool = True,
    healthy: bool = True,
    channels: list[dict] | None = None,
    extra: dict | None = None,
) -> dict:
    payload = {
        "name": name,
        "enabled": enabled,
        "connected": connected,
        "healthy": healthy,
        "server": SERVER,
        "nick": "secret-nick",
        "pass": SENTINEL,
        "channels": channels
        if channels is not None
        else [
            {
                "name": "#announce",
                "enabled": True,
                "monitoring": healthy and connected,
                "password": SENTINEL,
            }
        ],
    }
    if extra:
        payload.update(extra)
    return payload


INCIDENT = [
    _network(
        "Anthelion",
        connected=True,
        healthy=False,
        channels=[
            {
                "name": "#announce",
                "enabled": True,
                "monitoring": False,
                "password": SENTINEL,
                "connection_errors": [f"invite timed out {SENTINEL}"],
            },
            {"name": "#off", "enabled": False, "monitoring": False},
        ],
    ),
    _network("HealthyNet"),
    {
        "name": "TorrentLeech",
        "enabled": False,
        "connected": False,
        "healthy": False,
        "server": SERVER,
        "pass": SENTINEL,
        "channels": "not-a-list",
    },
]


class RenderTests(unittest.TestCase):
    def test_incident_names_the_unmonitored_channel_and_skips_disabled(self) -> None:
        text = irc_health.render(success=True, timestamp=1700000000, networks=INCIDENT)

        self.assertEqual(
            text,
            """\
# HELP autobrr_irc_network_connected 1 if an enabled autobrr IRC network has a live connection
# TYPE autobrr_irc_network_connected gauge
autobrr_irc_network_connected{network="Anthelion"} 1
autobrr_irc_network_connected{network="HealthyNet"} 1
# HELP autobrr_irc_network_healthy 1 if autobrr reports an enabled IRC network healthy
# TYPE autobrr_irc_network_healthy gauge
autobrr_irc_network_healthy{network="Anthelion"} 0
autobrr_irc_network_healthy{network="HealthyNet"} 1
# HELP autobrr_irc_channel_monitoring 1 if an enabled IRC channel is joined and monitoring
# TYPE autobrr_irc_channel_monitoring gauge
autobrr_irc_channel_monitoring{channel="#announce",network="Anthelion"} 0
autobrr_irc_channel_monitoring{channel="#announce",network="HealthyNet"} 1
# HELP autobrr_irc_health_scrape_success 1 if the latest autobrr IRC API read succeeded
# TYPE autobrr_irc_health_scrape_success gauge
autobrr_irc_health_scrape_success 1
# HELP autobrr_irc_health_last_scrape_timestamp_seconds Unix time of the latest autobrr IRC API read attempt
# TYPE autobrr_irc_health_last_scrape_timestamp_seconds gauge
autobrr_irc_health_last_scrape_timestamp_seconds 1700000000
""",
        )
        self.assertNotIn(SENTINEL, text)
        self.assertNotIn(SERVER, text)
        self.assertNotIn("TorrentLeech", text)
        self.assertNotIn("#off", text)
        self.assertNotIn("secret-nick", text)

    def test_disconnected_enabled_channel_is_not_monitoring(self) -> None:
        text = irc_health.render(
            success=True,
            timestamp=10,
            networks=[
                _network(
                    "Anthelion",
                    connected=False,
                    healthy=False,
                    channels=[
                        {
                            "name": "#announce",
                            "enabled": True,
                            "monitoring": False,
                        }
                    ],
                )
            ],
        )
        self.assertIn('autobrr_irc_network_connected{network="Anthelion"} 0', text)
        self.assertIn('autobrr_irc_network_healthy{network="Anthelion"} 0', text)
        self.assertIn(
            'autobrr_irc_channel_monitoring{channel="#announce",network="Anthelion"} 0',
            text,
        )

    def test_label_values_are_escaped(self) -> None:
        text = irc_health.render(
            success=True,
            timestamp=1,
            networks=[
                _network(
                    'Say "hi"\\',
                    channels=[
                        {
                            "name": '#a"b',
                            "enabled": True,
                            "monitoring": True,
                        }
                    ],
                )
            ],
        )
        self.assertIn(
            'autobrr_irc_network_connected{network="Say \\"hi\\"\\\\"} 1',
            text,
        )
        self.assertIn(
            'autobrr_irc_channel_monitoring{channel="#a\\"b",network="Say \\"hi\\"\\\\"} 1',
            text,
        )

    def test_duplicate_channel_keeps_the_unhealthy_sample(self) -> None:
        text = irc_health.render(
            success=True,
            timestamp=1,
            networks=[
                _network(
                    "Anthelion",
                    channels=[
                        {"name": "#announce", "enabled": True, "monitoring": True},
                        {"name": "#announce", "enabled": True, "monitoring": False},
                    ],
                )
            ],
        )
        self.assertEqual(
            text.count(
                'autobrr_irc_channel_monitoring{channel="#announce",network="Anthelion"}'
            ),
            1,
        )
        self.assertIn(
            'autobrr_irc_channel_monitoring{channel="#announce",network="Anthelion"} 0',
            text,
        )

    def test_schema_drift_fails_closed(self) -> None:
        with self.assertRaises(irc_health.SchemaError):
            irc_health.samples_from_networks([{"name": "Anthelion", "enabled": "yes"}])
        with self.assertRaises(irc_health.SchemaError):
            irc_health.samples_from_networks(
                [
                    {
                        "name": "Anthelion",
                        "enabled": True,
                        "connected": True,
                        "healthy": True,
                        "channels": "nope",
                    }
                ]
            )

    def test_failure_render_drops_health_series(self) -> None:
        text = irc_health.render(success=False, timestamp=5, networks=INCIDENT)
        self.assertIn("autobrr_irc_health_scrape_success 0", text)
        self.assertNotIn("Anthelion", text)
        self.assertNotIn(SENTINEL, text)

    def test_exposition_passes_promtool(self) -> None:
        promtool = shutil.which("promtool")
        if promtool is None:
            self.skipTest("promtool not on PATH")
        for success in (True, False):
            text = irc_health.render(
                success=success, timestamp=1700000000, networks=INCIDENT
            )
            result = subprocess.run(
                [promtool, "check", "metrics"],
                input=text,
                text=True,
                check=False,
                capture_output=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                result.stderr or result.stdout,
            )


class FetchTests(unittest.TestCase):
    def _serve(
        self, handler: type[BaseHTTPRequestHandler]
    ) -> tuple[ThreadingHTTPServer, str]:
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        host, port = server.server_address[:2]
        return server, f"http://{host}:{port}/api/irc"

    def test_read_uses_api_token_header_and_writes_metrics(self) -> None:
        payload = INCIDENT

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                if self.headers.get("X-API-Token") != "test-token":
                    self.send_response(401)
                    self.end_headers()
                    return
                if self.path != "/api/irc":
                    self.send_response(404)
                    self.end_headers()
                    return
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, fmt: str, *args: object) -> None:
                return

        _server, url = self._serve(Handler)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            token_file = root / "token"
            metrics_file = root / "autobrr_irc.prom"
            token_file.write_text("test-token\n", encoding="utf-8")
            code = irc_health.main(
                [
                    "--url",
                    url,
                    "--token-file",
                    str(token_file),
                    "--metrics-file",
                    str(metrics_file),
                ]
            )
            text = metrics_file.read_text(encoding="utf-8")
        self.assertEqual(code, 0)
        self.assertIn(
            'autobrr_irc_channel_monitoring{channel="#announce",network="Anthelion"} 0',
            text,
        )
        self.assertNotIn("test-token", text)
        self.assertNotIn(SENTINEL, text)

    def test_http_failure_keeps_the_previous_file_from_looking_healthy(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                self.send_response(401)
                self.end_headers()

            def log_message(self, fmt: str, *args: object) -> None:
                return

        _server, url = self._serve(Handler)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            token_file = root / "token"
            metrics_file = root / "autobrr_irc.prom"
            token_file.write_text("test-token", encoding="utf-8")
            metrics_file.write_text(
                'autobrr_irc_channel_monitoring{channel="#announce",network="Anthelion"} 0\n',
                encoding="utf-8",
            )
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code = irc_health.main(
                    [
                        "--url",
                        url,
                        "--token-file",
                        str(token_file),
                        "--metrics-file",
                        str(metrics_file),
                    ]
                )
            text = metrics_file.read_text(encoding="utf-8")
        self.assertEqual(code, 0)
        self.assertIn("HTTP 401", stderr.getvalue())
        self.assertIn("autobrr_irc_health_scrape_success 0", text)
        self.assertNotIn("Anthelion", text)

    def test_redirect_is_not_followed(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:1/stolen")
                self.end_headers()

            def log_message(self, fmt: str, *args: object) -> None:
                return

        _server, url = self._serve(Handler)
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            token_file = root / "token"
            metrics_file = root / "autobrr_irc.prom"
            token_file.write_text("test-token", encoding="utf-8")
            with contextlib.redirect_stderr(stderr):
                code = irc_health.main(
                    [
                        "--url",
                        url,
                        "--token-file",
                        str(token_file),
                        "--metrics-file",
                        str(metrics_file),
                    ]
                )
            text = metrics_file.read_text(encoding="utf-8")
        self.assertEqual(code, 0)
        self.assertIn("HTTP 302", stderr.getvalue())
        self.assertIn("autobrr_irc_health_scrape_success 0", text)


if __name__ == "__main__":
    unittest.main()
