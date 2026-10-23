import os
from pathlib import Path
import re
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


PIN_PATTERN = re.compile(r"^[ \t]*# nix-pin-version:[ \t]*(\S+)[ \t]*$", re.M)
DECLARED_PATTERN = re.compile(
    r'(?i)version\s*=\s*"([^"]+)"|https://github\.com/[^"\s]+/v([^/"\s]+)/'
)


def declared_versions(text):
    return {
        value
        for match in DECLARED_PATTERN.finditer(text)
        for value in match.groups()
        if value
    }


class NixPinVersionTests(unittest.TestCase):
    """Renovate regex managers rewrite version text and leave pinned revs and
    hashes behind. A `# nix-pin-version: X` marker must name a version that
    the same file still declares, so a version-only bump fails Lint.
    """

    def pin_files(self):
        listed = os.environ.get("NIX_PIN_FILES")
        if listed:
            return [
                Path(line.strip())
                for line in Path(listed).read_text().splitlines()
                if line.strip()
            ]
        return [
            path
            for root in (ROOT / "modules", ROOT / "pkgs")
            if root.exists()
            for path in root.rglob("*.nix")
        ]

    def test_version_only_bump_leaves_the_marker_behind(self):
        before = '\n'.join(
            [
                'version = "2.11.2";',
                "# nix-pin-version: 2.11.2",
                'rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";',
            ]
        )
        self.assertIn("2.11.2", declared_versions(before))
        bumped = before.replace('version = "2.11.2";', 'version = "2.11.3";')
        pins = PIN_PATTERN.findall(bumped)
        self.assertEqual(pins, ["2.11.2"])
        self.assertNotIn(pins[0], declared_versions(bumped))

    def test_markers_match_declared_versions(self):
        found = False
        for path in self.pin_files():
            text = path.read_text()
            pins = PIN_PATTERN.findall(text)
            if not pins:
                continue
            found = True
            declared = declared_versions(text)
            for pin in pins:
                self.assertIn(
                    pin,
                    declared,
                    f"{path} nix-pin-version {pin} is not a declared version {sorted(declared)}",
                )
        self.assertTrue(found, "expected at least one nix-pin-version marker")


if __name__ == "__main__":
    unittest.main()
