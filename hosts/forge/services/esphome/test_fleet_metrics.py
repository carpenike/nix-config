#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import tempfile
import unittest
from unittest import mock

from . import fleet_metrics


class PolicyTests(unittest.TestCase):
    def test_policy_rejects_overlapping_tiers(self) -> None:
        with self.assertRaisesRegex(ValueError, "both critical and ignored"):
            fleet_metrics.parse_policy(
                {
                    "default_tier": "standard",
                    "critical": ["freezer"],
                    "ignore": ["freezer"],
                }
            )

    def test_policy_defaults_unlisted_nodes_to_standard(self) -> None:
        policy = fleet_metrics.parse_policy(
            {
                "default_tier": "standard",
                "critical": ["critical-node"],
                "ignore": ["ignored-node"],
            }
        )

        self.assertEqual(policy.tier_for("critical-node"), "critical")
        self.assertEqual(policy.tier_for("ignored-node"), "ignore")
        self.assertEqual(policy.tier_for("new-node"), "standard")


class InventoryTests(unittest.TestCase):
    def test_inventory_deduplicates_nodes_deterministically(self) -> None:
        nodes = fleet_metrics.build_nodes(
            {
                "configured": [
                    {
                        "name": "freezer",
                        "friendly_name": "Garage Freezer",
                        "configuration": "z.yaml",
                        "api_enabled": True,
                        "uses_deep_sleep": False,
                        "state": "unknown",
                        "ip": "",
                        "ip_addresses": [],
                    },
                    {
                        "name": "freezer",
                        "friendly_name": "Garage Freezer",
                        "configuration": "a.yaml",
                        "api_enabled": True,
                        "uses_deep_sleep": False,
                        "state": "online",
                        "ip": "10.30.100.20",
                        "ip_addresses": ["10.30.100.20"],
                    },
                ]
            }
        )

        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0].configurations, ("a.yaml", "z.yaml"))
        self.assertEqual(nodes[0].configuration_count, 2)
        self.assertEqual(nodes[0].dashboard_state, "online")
        self.assertEqual(nodes[0].dashboard_ip, "10.30.100.20")

    def test_empty_inventory_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "no configured devices"):
            fleet_metrics.build_nodes({"configured": []})


class ProbeTests(unittest.TestCase):
    def test_command_resolver_serializes_subprocesses(self) -> None:
        active_calls = 0
        maximum_active_calls = 0
        counter_lock = fleet_metrics.threading.Lock()

        def fake_run(
            *args: object, **kwargs: object
        ) -> fleet_metrics.subprocess.CompletedProcess[str]:
            nonlocal active_calls, maximum_active_calls
            del args, kwargs
            with counter_lock:
                active_calls += 1
                maximum_active_calls = max(maximum_active_calls, active_calls)
            fleet_metrics.time.sleep(0.01)
            with counter_lock:
                active_calls -= 1
            return fleet_metrics.subprocess.CompletedProcess(
                [], 0, stdout="10.30.100.20 STREAM node.holthome.net\n"
            )

        with mock.patch.object(fleet_metrics.subprocess, "run", side_effect=fake_run):
            with fleet_metrics.concurrent.futures.ThreadPoolExecutor(
                max_workers=4
            ) as executor:
                results = list(
                    executor.map(
                        lambda index: fleet_metrics.command_resolver(
                            f"node-{index}.holthome.net",
                            6053,
                            command="/bin/getent",
                            timeout_seconds=2.0,
                        ),
                        range(4),
                    )
                )

        self.assertEqual(results, ["10.30.100.20"] * 4)
        self.assertEqual(maximum_active_calls, 1)

    def test_command_resolver_reports_success(self) -> None:
        completed = fleet_metrics.subprocess.CompletedProcess(
            [], 0, stdout="10.30.100.20 STREAM freezer.holthome.net\n"
        )
        with mock.patch.object(
            fleet_metrics.subprocess, "run", return_value=completed
        ) as run:
            resolved = fleet_metrics.command_resolver(
                "freezer.holthome.net",
                6053,
                command="/bin/getent",
                timeout_seconds=1.0,
            )

        self.assertEqual(resolved, "10.30.100.20")
        run.assert_called_once_with(
            ["/bin/getent", "ahostsv4", "freezer.holthome.net"],
            check=False,
            stdout=fleet_metrics.subprocess.PIPE,
            stderr=fleet_metrics.subprocess.DEVNULL,
            text=True,
            timeout=1.0,
        )

    def test_command_resolver_treats_timeout_as_unresolved(self) -> None:
        with mock.patch.object(
            fleet_metrics.subprocess,
            "run",
            side_effect=fleet_metrics.subprocess.TimeoutExpired(["getent"], 1.0),
        ):
            resolved = fleet_metrics.command_resolver(
                "missing.holthome.net",
                6053,
                command="/bin/getent",
                timeout_seconds=1.0,
            )

        self.assertIsNone(resolved)

    def test_probe_connects_to_resolved_ip(self) -> None:
        node = fleet_metrics.FleetNode(
            name="freezer",
            friendly_name="Freezer",
            configurations=("freezer.yaml",),
            api_enabled=True,
            uses_deep_sleep=False,
            dashboard_state="online",
            dashboard_ip="10.30.100.21",
        )
        connected_targets: list[str] = []

        def connector(
            host: str, port: int, timeout_seconds: float
        ) -> tuple[bool, float]:
            del port, timeout_seconds
            connected_targets.append(host)
            return True, 0.01

        result = fleet_metrics.probe_node(
            node,
            "critical",
            "holthome.net",
            6053,
            2.0,
            resolver=lambda *_: "10.30.100.20",
            connector=connector,
        )

        self.assertEqual(connected_targets, ["10.30.100.20"])
        self.assertTrue(result.dns_resolves)
        self.assertEqual(result.target_source, "dns")
        self.assertTrue(result.api_up)

    def test_probe_falls_back_to_dashboard_ip_when_dns_is_missing(self) -> None:
        node = fleet_metrics.FleetNode(
            name="freezer",
            friendly_name="Freezer",
            configurations=("freezer.yaml",),
            api_enabled=True,
            uses_deep_sleep=False,
            dashboard_state="online",
            dashboard_ip="10.30.100.20",
        )
        connected_targets: list[str] = []

        def connector(
            host: str, port: int, timeout_seconds: float
        ) -> tuple[bool, float]:
            connected_targets.append(host)
            self.assertEqual(port, 6053)
            self.assertEqual(timeout_seconds, 2.0)
            return True, 0.125

        result = fleet_metrics.probe_node(
            node,
            "critical",
            "holthome.net",
            6053,
            2.0,
            resolver=lambda *_: None,
            connector=connector,
        )

        self.assertEqual(connected_targets, ["10.30.100.20"])
        self.assertFalse(result.dns_resolves)
        self.assertEqual(result.target_source, "dashboard_ip")
        self.assertTrue(result.api_up)
        self.assertEqual(result.duration_seconds, 0.125)

    def test_collection_excludes_ignored_deep_sleep_and_api_disabled_nodes(
        self,
    ) -> None:
        def node(
            name: str, *, api: bool = True, deep_sleep: bool = False
        ) -> fleet_metrics.FleetNode:
            return fleet_metrics.FleetNode(
                name=name,
                friendly_name=name,
                configurations=(f"{name}.yaml",),
                api_enabled=api,
                uses_deep_sleep=deep_sleep,
                dashboard_state="online",
                dashboard_ip="10.30.100.20",
            )

        policy = fleet_metrics.FleetPolicy(
            default_tier="standard",
            critical=frozenset({"critical-node"}),
            ignore=frozenset({"ignored-node"}),
        )
        results = fleet_metrics.collect_probe_results(
            [
                node("critical-node"),
                node("standard-node"),
                node("ignored-node"),
                node("sleeping-node", deep_sleep=True),
                node("no-api-node", api=False),
            ],
            policy,
            "holthome.net",
            6053,
            2.0,
            2,
            resolver=lambda *_: "10.30.100.20",
            connector=lambda *_: (True, 0.01),
        )

        self.assertEqual(
            [(result.node_name, result.tier) for result in results],
            [("critical-node", "critical"), ("standard-node", "standard")],
        )


class MetricsTests(unittest.TestCase):
    def test_metrics_include_coverage_failures_and_policy_orphans(self) -> None:
        policy = fleet_metrics.FleetPolicy(
            default_tier="standard",
            critical=frozenset({"freezer", "missing-critical"}),
            ignore=frozenset(),
        )
        nodes = [
            fleet_metrics.FleetNode(
                name="freezer",
                friendly_name='Garage "Freezer"',
                configurations=("a.yaml", "b.yaml"),
                api_enabled=True,
                uses_deep_sleep=False,
                dashboard_state="online",
                dashboard_ip="10.30.100.20",
            )
        ]
        results = [
            fleet_metrics.ProbeResult(
                node_name="freezer",
                tier="critical",
                dns_resolves=False,
                target_source="dashboard_ip",
                api_up=False,
                duration_seconds=1.25,
            )
        ]

        metrics = fleet_metrics.render_fleet_metrics(
            nodes, policy, results, 1_700_000_000
        )

        self.assertIn('friendly_name="Garage \\"Freezer\\""', metrics)
        self.assertIn('esphome_fleet_config_count{node="freezer"} 2', metrics)
        self.assertIn(
            'esphome_fleet_api_up{node="freezer",target_source="dashboard_ip",tier="critical"} 0',
            metrics,
        )
        self.assertIn("esphome_fleet_duplicate_nodes_total 1", metrics)
        self.assertIn("esphome_fleet_policy_orphans_total 1", metrics)
        self.assertIn("esphome_fleet_unresolved_targets_total 1", metrics)

    def test_failed_run_preserves_last_good_fleet_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = pathlib.Path(temporary_directory)
            policy_file = directory / "policy.json"
            fleet_file = directory / "fleet.prom"
            status_file = directory / "status.prom"
            policy_file.write_text(
                '{"default_tier":"standard","critical":[],"ignore":[]}',
                encoding="utf-8",
            )
            fleet_file.write_text("last_good_metric 1\n", encoding="utf-8")

            with mock.patch.object(
                fleet_metrics, "fetch_inventory", side_effect=OSError("offline")
            ):
                exit_code = fleet_metrics.run(
                    [
                        "--domain",
                        "holthome.net",
                        "--policy-file",
                        str(policy_file),
                        "--metrics-file",
                        str(fleet_file),
                        "--status-file",
                        str(status_file),
                        "--resolver-command",
                        "/bin/getent",
                    ]
                )

            self.assertEqual(exit_code, 1)
            self.assertEqual(
                fleet_file.read_text(encoding="utf-8"), "last_good_metric 1\n"
            )
            self.assertIn(
                "esphome_fleet_collector_success 0",
                status_file.read_text(encoding="utf-8"),
            )


if __name__ == "__main__":
    unittest.main()
