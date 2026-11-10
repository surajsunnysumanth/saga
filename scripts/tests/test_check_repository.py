"""Synthetic-only regression tests for the repository privacy gate."""
import pathlib
import subprocess
import shutil
import sys
import os
import tempfile
import unittest

SCANNER = pathlib.Path(__file__).resolve().parents[1] / "check_repository.py"


class RepositoryCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def track(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        subprocess.run(["git", "add", "--", name], cwd=self.root, check=True)

    def scan(self):
        return subprocess.run([sys.executable, str(SCANNER)], cwd=self.root,
                              capture_output=True, text=True)

    def test_private_key_fails_without_disclosing_value(self):
        secret = "-----BEGIN " + "PRIVATE KEY-----\nsynthetic-sensitive-value"
        self.track("Sources/Bad.swift", secret)
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("private-key", result.stdout)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertNotIn("synthetic-sensitive-value", result.stdout + result.stderr)

    def test_home_path_fails_but_portable_documentation_passes(self):
        self.track("docs/guide.md", "Use ~/Developer/saga-swift and /Applications/Saga.app")
        self.assertEqual(self.scan().returncode, 0)
        self.track("Sources/Bad.swift", 'let path = "' + "/Users/" + 'fixture/private"')
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("home-path", result.stdout)
        self.assertNotIn("fixture/private", result.stdout + result.stderr)


    def test_sensitive_artifacts_are_rejected_even_when_empty(self):
        for name in ["fixture.db", "fixture.sqlite3", "fixture.db-wal", "fixture.vcf",
                     "fixture.key", "fixture.crypt15", ".env", "segments/fixture.ndjson.gz"]:
            with self.subTest(name=name):
                self.track(name, "")
                result = self.scan()
                subprocess.run(["git", "rm", "-q", "--cached", "--", name],
                               cwd=self.root, check=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("private-artifact", result.stdout)


    def test_literal_credentials_fail_without_disclosing_values(self):
        for value in ['let crypt15Key = "' + "ab" * 32 + '"',
                      'token = "' + "ghp_" + "x" * 36 + '"',
                      'apiKey = "' + "sk-proj-" + "x" * 40 + '"']:
            with self.subTest():
                self.track("Sources/Credentials.swift", value)
                result = self.scan()
                self.assertEqual(result.returncode, 1)
                self.assertIn("credential", result.stdout)
                self.assertNotIn(value, result.stdout + result.stderr)


    def test_check_runs_release_build_and_tests_and_propagates_failure(self):
        scripts = self.root / "scripts"
        (scripts / "tests").mkdir(parents=True)
        (scripts / "tests" / "test_fixture.py").write_text(
            "import unittest\nclass Fixture(unittest.TestCase):\n"
            "    def test_synthetic(self):\n        self.assertTrue(True)\n")
        self.assertTrue(SCANNER.with_name("check.sh").is_file(), "CI entry point missing")
        for name in ["check.sh", "check_repository.py"]:
            shutil.copyfile(SCANNER.with_name(name), scripts / name)
        binaries = self.root / "bin"
        binaries.mkdir()
        swift = binaries / "swift"
        swift.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$SWIFT_CALLS"\n'
                         'if [[ "$*" == "$FAIL_COMMAND" ]]; then exit 17; fi\n')
        swift.chmod(0o755)
        log = self.root / "swift-calls"
        env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                   SWIFT_CALLS=str(log), FAIL_COMMAND="")
        def run():
            return subprocess.run(["bash", str(scripts / "check.sh")], cwd=self.root,
                                  env=env, capture_output=True, text=True)
        result = run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(log.read_text().splitlines(), ["build -c release", "test"])
        for command, calls in [("build -c release", ["build -c release"]),
                               ("test", ["build -c release", "test"])]:
            with self.subTest(command=command):
                log.unlink()
                env["FAIL_COMMAND"] = command
                self.assertEqual(run().returncode, 17)
                self.assertEqual(log.read_text().splitlines(), calls)
        log.unlink()
        self.track("private.db", "")
        self.assertEqual(run().returncode, 1)
        self.assertFalse(log.exists(), "Privacy failure must stop before building")


    def test_owner_identifiers_fail_matches_without_disclosing_values(self):
        marker = "synthetic-owner-identifier-token"
        identifiers = self.root / "private-identifiers.txt"
        identifiers.write_text("# one literal per line\n" + marker + "\n")
        self.track("docs/contact.md", "Reach me at " + marker.upper() + " for details")
        result = subprocess.run([sys.executable, str(SCANNER), "--identifiers", str(identifiers)],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("owner-identifier", result.stdout)
        self.assertNotIn(marker, result.stdout + result.stderr)

    def test_owner_identifiers_only_fail_on_real_matches(self):
        identifiers = self.root / "private-identifiers.txt"
        identifiers.write_text("synthetic-owner-identifier-token\n")
        self.track("docs/safe.md", "Unrelated text and a generic 4155550100 style example")
        result = subprocess.run([sys.executable, str(SCANNER), "--identifiers", str(identifiers)],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_scanner_next_to_identifiers_file_autodetects_it(self):
        marker = "autodetected-owner-token"
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(SCANNER, scripts / "check_repository.py")
        (scripts / ".private_identifiers").write_text(marker + "\n")
        self.track("Sources/Bad.swift", "owner = \"" + marker + "\"")
        result = subprocess.run([sys.executable, str(scripts / "check_repository.py")],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("owner-identifier", result.stdout)
        self.assertNotIn(marker, result.stdout + result.stderr)
        (scripts / ".private_identifiers").unlink()
        result = subprocess.run([sys.executable, str(scripts / "check_repository.py")],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_explicit_identifiers_path_is_honoured(self):
        marker = "another-synthetic-owner-token"
        outside = self.root / "private-list.txt"
        outside.write_text(marker + "\n")
        self.track("Sources/Bad.swift", "let owner = \"" + marker + "\"")
        result = subprocess.run([sys.executable, str(SCANNER), "--identifiers", str(outside)],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("owner-identifier", result.stdout)
        self.assertNotIn(marker, result.stdout + result.stderr)
        result = subprocess.run([sys.executable, str(SCANNER), "--identifiers", str(self.root / "missing.txt")],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("owner-identifier:", result.stdout)

    def test_invalid_arguments_are_rejected(self):
        result = subprocess.run([sys.executable, str(SCANNER), "--unknown"], cwd=self.root,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)


    def test_symlinks_are_rejected_without_following_targets(self):
        target = self.root / "outside"
        target.write_text("synthetic-value")
        (self.root / "link").symlink_to(target)
        subprocess.run(["git", "add", "link"], cwd=self.root, check=True)
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("tracked-symlink", result.stdout)
        self.assertNotIn("synthetic-value", result.stdout + result.stderr)

    def test_scans_tracked_working_tree_and_handles_space_in_name(self):
        self.track("docs/a guide.md", "Safe text")
        (self.root / "not-tracked.db").write_text("ignored")
        self.assertEqual(self.scan().returncode, 0)
        (self.root / "docs/a guide.md").write_text("-----BEGIN " + "PRIVATE KEY-----")
        self.assertEqual(self.scan().returncode, 1)


if __name__ == "__main__":
    unittest.main()
