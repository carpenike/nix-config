import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(os.environ["OPENPROJECT_TOKEN_SCRIPT"])
TOKEN_OUTPUT = "bot-grok\tfixture-not-a-real-token\n"


class ContainerTests(unittest.TestCase):
    def test_every_process_uses_writable_upload_staging(self):
        containers = json.loads(Path(os.environ["OPENPROJECT_CONTAINERS"]).read_text())
        self.assertEqual(
            set(containers),
            {"openproject-seeder", "openproject-web", "openproject-worker"},
        )
        for name, container in containers.items():
            with self.subTest(container=name):
                self.assertEqual(container["user"], "1069:1069")
                self.assertEqual(container["environment"]["HOME"], "/app/tmp")
                self.assertEqual(container["environment"]["TMPDIR"], "/app/tmp")
                self.assertIn(
                    "--tmpfs=/app/tmp:rw,size=512m,mode=1777",
                    container["extraOptions"],
                )


class DatabaseTests(unittest.TestCase):
    def test_extensions_match_the_image_sql_dump(self):
        database = json.loads(Path(os.environ["OPENPROJECT_DATABASE"]).read_text())
        self.assertEqual(database["owner"], "openproject")
        self.assertEqual(len(database["extensions"]), 3)
        self.assertEqual(
            {
                extension["name"]: extension["schema"]
                for extension in database["extensions"]
            },
            {
                "btree_gist": "pg_catalog",
                "pg_trgm": "pg_catalog",
                "unaccent": "pg_catalog",
            },
        )
        for extension in database["extensions"]:
            with self.subTest(extension=extension["name"]):
                self.assertFalse(extension["dropBeforeCreate"])


class TokenMintingTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="openproject-tokens-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.output = self.root / "tokens.tsv"
        self.called = self.root / "podman-called"
        self.podman = self.root / "podman"
        self.podman.write_text(
            f"#!{sys.executable}\n"
            "import os, stat, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['PODMAN_CALL_MARKER']).touch()\n"
            "info = os.fstat(sys.stdout.fileno())\n"
            "assert stat.S_ISREG(info.st_mode)\n"
            "assert stat.S_IMODE(info.st_mode) == 0o600\n"
            "assert info.st_uid == os.geteuid()\n"
            "sys.stdin.read()\n"
            f"sys.stdout.write({TOKEN_OUTPUT!r})\n"
            "sys.exit(int(os.environ.get('PODMAN_EXIT', '0')))\n"
        )
        self.podman.chmod(0o700)

    def run_mint(self, exit_code=0):
        result = subprocess.run(
            ["bash", str(SCRIPT), str(self.output)],
            env=os.environ
            | {
                "PATH": f"{self.root}:{os.environ['PATH']}",
                "PODMAN_CALL_MARKER": str(self.called),
                "PODMAN_EXIT": str(exit_code),
            },
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.stdout, "")
        self.assertNotIn(TOKEN_OUTPUT.strip(), result.stderr)
        self.assertFalse(list(self.root.glob(".openproject-bot-tokens.*")))
        return result

    def assert_private_output(self):
        self.assertTrue(self.called.exists())
        self.assertEqual(self.output.read_text(), TOKEN_OUTPUT)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(self.output.stat().st_uid, os.geteuid())

    def test_new_file_is_private(self):
        result = self.run_mint()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_private_output()

    def test_existing_readable_file_is_replaced_privately(self):
        self.output.write_text("previous output\n")
        self.output.chmod(0o644)
        result = self.run_mint()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_private_output()

    def test_failed_mint_preserves_existing_file(self):
        self.output.write_text("previous output\n")
        self.output.chmod(0o600)
        result = self.run_mint(exit_code=23)
        self.assertEqual(result.returncode, 23)
        self.assertNotIn("wrote ", result.stderr)
        self.assertEqual(self.output.read_text(), "previous output\n")
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)

    def test_failed_mint_leaves_no_output_file(self):
        result = self.run_mint(exit_code=23)
        self.assertEqual(result.returncode, 23)
        self.assertNotIn("wrote ", result.stderr)
        self.assertFalse(self.output.exists())

    def test_symlink_output_is_refused(self):
        target = self.root / "existing.tsv"
        target.write_text("do not overwrite\n")
        self.output.symlink_to(target)
        result = self.run_mint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing token output path", result.stderr)
        self.assertFalse(self.called.exists())
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(target.read_text(), "do not overwrite\n")

    def test_dangling_symlink_output_is_refused(self):
        target = self.root / "missing.tsv"
        self.output.symlink_to(target)
        result = self.run_mint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing token output path", result.stderr)
        self.assertFalse(self.called.exists())
        self.assertTrue(self.output.is_symlink())
        self.assertFalse(target.exists())

    def test_directory_output_is_refused(self):
        self.output.mkdir()
        result = self.run_mint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing token output path", result.stderr)
        self.assertFalse(self.called.exists())
        self.assertTrue(self.output.is_dir())

    def test_fifo_output_is_refused(self):
        os.mkfifo(self.output)
        result = self.run_mint()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing token output path", result.stderr)
        self.assertFalse(self.called.exists())
        self.assertTrue(stat.S_ISFIFO(self.output.stat().st_mode))

    def test_existing_hardlink_target_is_not_modified(self):
        target = self.root / "other.tsv"
        target.write_text("do not overwrite\n")
        self.output.hardlink_to(target)
        result = self.run_mint()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_private_output()
        self.assertEqual(target.read_text(), "do not overwrite\n")

    def test_output_path_with_spaces(self):
        directory = self.root / "private output"
        directory.mkdir()
        self.output = directory / "bot tokens.tsv"
        result = self.run_mint()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_private_output()
        self.assertFalse(list(directory.glob(".openproject-bot-tokens.*")))


if __name__ == "__main__":
    unittest.main()
