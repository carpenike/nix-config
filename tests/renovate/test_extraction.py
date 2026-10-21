import os
from pathlib import Path
import unittest

import json5
import re2


ROOT = Path(__file__).resolve().parents[2]


class DockerExtractionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        config_path = Path(
            os.environ.get("RENOVATE_CONFIG", ROOT / ".github/renovate.json5")
        )
        config = json5.loads(config_path.read_text())
        cls.patterns = []
        for manager in config["customManagers"]:
            for expression in manager["matchStrings"]:
                pattern = re2.compile(expression)
                if manager.get("datasourceTemplate") == "docker":
                    cls.patterns.append(pattern)

    def extract(self, source):
        return [
            match.groupdict()
            for pattern in self.patterns
            for match in pattern.finditer(source)
        ]

    def test_image_assignments_and_option_defaults(self):
        digest = "sha256:" + "a" * 64
        for assignment in (
            "image",
            "container.image",
            "default",
            "serverImage",
            "daemonImage",
            "container.tikaImage",
        ):
            for package in (
                "ghcr.io/home-operations/plex",
                "docker.io/library/redis",
                "grafana/oncall",
            ):
                with self.subTest(assignment=assignment, package=package):
                    self.assertEqual(
                        self.extract(f'  {assignment} = "{package}:1.2.3@{digest}";'),
                        [
                            {
                                "depName": package,
                                "currentValue": "1.2.3",
                                "currentDigest": digest,
                            }
                        ],
                    )

    def test_channels_and_multiline_values(self):
        for package, tag in (
            ("ghcr.io/koush/scrypted", "latest"),
            ("docker.io/gotenberg/gotenberg", "8"),
            ("grafana/oncall", "v1.16.7"),
            ("ghcr.io/home-operations/plex", "1.43.4.10903"),
        ):
            with self.subTest(package=package, tag=tag):
                self.assertEqual(
                    self.extract(f'  default =\n    "{package}:{tag}";'),
                    [
                        {
                            "depName": package,
                            "currentValue": tag,
                            "currentDigest": None,
                        }
                    ],
                )

    def test_real_plex_option_is_detected_once(self):
        path = Path(
            os.environ.get(
                "PLEX_MODULE", ROOT / "modules/nixos/services/plex/default.nix"
            )
        )
        dependencies = self.extract(path.read_text())
        self.assertEqual(
            [dependency["depName"] for dependency in dependencies],
            ["ghcr.io/home-operations/plex"],
        )

    def test_comments_examples_and_non_image_values_are_ignored(self):
        for source in (
            '# image = "ghcr.io/example/ignored:1.2.3";',
            '  # default = "grafana/oncall:v1.16.7";',
            'example = "ghcr.io/example/ignored:1.2.3";',
            'default = "https://ghcr.io/example/ignored:1.2.3";',
            'default = "/var/lib/plex";',
            'default = "grafana/oncall";',
            "image = cfg.image;",
            'default = "${cfg.registry}/example:1.2.3";',
        ):
            with self.subTest(source=source):
                self.assertEqual(self.extract(source), [])

    def test_adjacent_assignments_and_inline_comments(self):
        dependencies = self.extract(
            'image = "ghcr.io/home-operations/plex:1.2.3"; # image = "x/y:9";\n'
            'default = "grafana/oncall:v1.16.7";\n'
        )
        self.assertEqual(
            {
                (dependency["depName"], dependency["currentValue"])
                for dependency in dependencies
            },
            {
                ("ghcr.io/home-operations/plex", "1.2.3"),
                ("grafana/oncall", "v1.16.7"),
            },
        )


if __name__ == "__main__":
    unittest.main()
