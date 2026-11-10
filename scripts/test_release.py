"""Local release safety checks; no credentials or network required."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ReleaseTests(unittest.TestCase):
    def test_release_requires_explicit_mode(self):
        script = ROOT / "scripts/release.sh"
        self.assertTrue(script.exists(), "release entry point must exist")
        result = subprocess.run(["bash", str(script)], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--dry-run", result.stderr)

    def test_rejects_unknown_modes(self):
        result = subprocess.run(["bash", "scripts/release.sh", "--publish"], cwd=ROOT, capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_notarization_requires_credentials_before_build(self):
        import os
        env = dict(os.environ)
        env.pop("DEVELOPER_ID_APPLICATION", None)
        env.pop("NOTARY_KEYCHAIN_PROFILE", None)
        result = subprocess.run(["bash", "scripts/release.sh", "--notarize"], cwd=ROOT, env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"DEVELOPER_ID_APPLICATION", result.stderr)

    def test_bundle_version_uses_single_source(self):
        source = (ROOT / "scripts/make_app.sh").read_text()
        self.assertIn("VERSION", source)
        self.assertNotIn("<string>0.1.0</string>", source)
        self.assertRegex((ROOT / "VERSION").read_text().strip(), r"^\d+\.\d+\.\d+$")

    def test_private_artifacts_are_ignored(self):
        samples = ["fixture.db", "fixture.db-wal", "fixture.sqlite-shm", "fixture.crypt16",
                   "fixture.key", "fixture.vcf", "fixture.ndjson.gz", "fixture.p12",
                   ".env.local", "vault/vault.json", "segments/sample.ndjson.gz",
                   ".build-playback/debug/file", ".service-verification/result.txt"]
        import shutil, tempfile
        with tempfile.TemporaryDirectory() as tmp:   # isolated repo: unaffected by local symlinks
            subprocess.run(["git", "init", "-q", tmp], check=True)
            shutil.copyfile(ROOT / ".gitignore", Path(tmp) / ".gitignore")
            result = subprocess.run(["git", "check-ignore", "--stdin"], cwd=tmp,
                                    input="\n".join(samples) + "\n", capture_output=True, text=True)
        self.assertEqual(set(result.stdout.splitlines()), set(samples))

    def test_versioned_app_manifest(self):
        import plistlib
        manifest = ROOT / "build/Saga.app/Contents/Info.plist"
        if not manifest.exists():
            self.skipTest("Run scripts/make_app.sh to validate the produced bundle")
        info = plistlib.loads(manifest.read_bytes())
        self.assertEqual(info["CFBundleShortVersionString"], (ROOT / "VERSION").read_text().strip())
        self.assertEqual(info["CFBundleVersion"], (ROOT / "VERSION").read_text().strip())
        self.assertEqual(info["LSMinimumSystemVersion"], "14.0")
        self.assertTrue((manifest.parent / "MacOS/saga-mcp").is_file())

if __name__ == "__main__":
    unittest.main()
