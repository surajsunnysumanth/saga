"""Tests for scripts/make_public_snapshot.py (offline, synthetic fixtures only)."""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import make_public_snapshot as snapshot  # noqa: E402


class PublicSnapshotTests(unittest.TestCase):
    def test_internal_material_is_excluded(self):
        paths = [
            "README.md",
            "Package.swift",
            "Sources/SagaCore/Vault.swift",
            "Tests/SagaCoreTests/VaultTests.swift",
            ".github/workflows/ci.yml",
            "site/index.html",
            "docs/ARCHITECTURE.md",
            "docs/tasks/10-github-launch.md",
            "docs/WORKER-BRIEF.md",
            "docs/LAUNCH.md",
            "docs/launch/launch-post.md",
            "docs/website-assets.md",
            "docs/website-copy.md",
            "docs/mockups/site-home.html",
            "scripts/check_repository.py",
            "scripts/parity.sh",
            "scripts/.private_identifiers",
            "build/Saga.app/Contents/MacOS/Saga",
            ".launch-doc-verification/verify.py",
        ]
        selected = snapshot.select_paths(paths)
        self.assertEqual(
            selected,
            [
                "README.md",
                "Package.swift",
                "Sources/SagaCore/Vault.swift",
                "Tests/SagaCoreTests/VaultTests.swift",
                ".github/workflows/ci.yml",
                "site/index.html",
                "docs/ARCHITECTURE.md",
                "scripts/check_repository.py",
            ],
        )

    def test_unknown_prefixes_are_not_exported(self):
        self.assertFalse(snapshot.is_public_path("private/notes.md"))
        self.assertFalse(snapshot.is_public_path("VERSION.backup"))
        self.assertTrue(snapshot.is_public_path("VERSION"))

    def test_link_check_reports_missing_and_escaping_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "docs").mkdir()
            (root / "README.md").write_text(
                "[ok](docs/guide.md) [anchor](#top) [web](https://example.com) "
                "[missing](docs/gone.md) [escape](../outside.md)\n",
                encoding="utf-8",
            )
            (root / "docs" / "guide.md").write_text("# Guide\n", encoding="utf-8")
            broken = snapshot.find_broken_links(root)
            reasons = {(source, target): reason for source, target, reason in broken}
            self.assertIn(("README.md", "docs/gone.md"), reasons)
            self.assertEqual(reasons[("README.md", "docs/gone.md")], "missing")
            self.assertIn(("README.md", "../outside.md"), reasons)
            self.assertEqual(len(broken), 2)

    def test_html_links_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "site").mkdir()
            (root / "site" / "index.html").write_text(
                '<a href="page.html">ok</a><img src="assets/x.png">', encoding="utf-8"
            )
            (root / "site" / "page.html").write_text("ok", encoding="utf-8")
            broken = snapshot.find_broken_links(root)
            self.assertEqual(broken, [("site/index.html", "assets/x.png", "missing")])


if __name__ == "__main__":
    unittest.main()
