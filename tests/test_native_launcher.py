"""Exercise the distributed native executable's admission and safe cleanup paths."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get("LOGIC_ARA_NATIVE_EXECUTABLE", ROOT / "dist/Logic ARA Launcher.app/Contents/MacOS/Logic ARA Launcher"))


@unittest.skipUnless(EXE.exists(), "Build the standalone native app first")
class NativeLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cache = Path(self.temp.name) / "cache"

    def run_native(self, *args):
        return subprocess.run([str(EXE), *map(str, args)], capture_output=True, text=True, timeout=20)

    def make_session(self, *, owner_pid=99999999, child_pid=99999998):
        lock = self.cache / "active.lock"
        lock.mkdir(parents=True)
        run = self.cache / "runs/test-owned-run"
        run.mkdir(parents=True)
        app = run / "Logic Pro.app"
        app.mkdir()
        (app / "owned-test-file").write_text("owned")
        manifest = run / "session.json"
        manifest.write_text(json.dumps({"pid": child_pid, "status": "detached", "owned_app": str(app), "run_directory": str(run)}))
        (lock / "owner.json").write_text(json.dumps({"launcher_pid": owner_pid, "session": str(manifest)}))
        return app, manifest, lock

    def test_version_has_no_runtime_dependency(self):
        result = self.run_native("--version")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0.2.0-candidate.5")

    def test_unknown_build_refuses_without_creating_cache(self):
        source = Path(self.temp.name) / "Unknown Logic.app"
        (source / "Contents").mkdir(parents=True)
        (source / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.apple.logic10", "CFBundleShortVersionString": "12.4", "CFBundleVersion": "9999"}))
        result = self.run_native("--logic", source, "--cache", self.cache)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported Logic", result.stderr)
        self.assertFalse(self.cache.exists())

    def test_finished_session_removes_only_private_copy(self):
        app, manifest, lock = self.make_session()
        unrelated = self.cache / "preserve-me"
        unrelated.write_text("unrelated")
        result = self.run_native("--cleanup", "--cache", self.cache)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(app.exists())
        self.assertFalse(lock.exists())
        self.assertTrue(manifest.exists())
        self.assertEqual(unrelated.read_text(), "unrelated")

    def test_live_launcher_is_never_adopted_or_cleaned(self):
        app, manifest, lock = self.make_session(owner_pid=os.getpid())
        result = self.run_native("--cleanup", "--cache", self.cache)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still alive", result.stderr)
        self.assertTrue(app.exists())
        self.assertTrue(lock.exists())

    def test_live_child_is_never_adopted_or_cleaned(self):
        app, manifest, lock = self.make_session(child_pid=os.getpid())
        result = self.run_native("--cleanup", "--cache", self.cache)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(app.exists())
        self.assertTrue(lock.exists())

    def test_outside_manifest_cannot_be_cleaned(self):
        app, manifest, lock = self.make_session()
        external = Path(self.temp.name) / "outside/session.json"
        external.parent.mkdir()
        external.write_text(manifest.read_text())
        (lock / "owner.json").write_text(json.dumps({"launcher_pid": 99999999, "session": str(external)}))
        result = self.run_native("--cleanup", "--cache", self.cache)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside", result.stderr)
        self.assertTrue(app.exists())
        self.assertTrue(external.exists())

    def test_symlinked_private_app_is_never_followed_or_deleted(self):
        app, manifest, lock = self.make_session()
        (app / "owned-test-file").unlink()
        app.rmdir()
        external = Path(self.temp.name) / "User Logic.app"
        external.mkdir()
        app.symlink_to(external, target_is_directory=True)
        result = self.run_native("--cleanup", "--cache", self.cache)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)
        self.assertTrue(app.is_symlink())
        self.assertTrue(external.exists())

    def test_mismatched_owned_path_is_never_deleted(self):
        app, manifest, lock = self.make_session()
        receipt = json.loads(manifest.read_text())
        receipt["owned_app"] = "/Applications/Logic Pro.app"
        manifest.write_text(json.dumps(receipt))
        result = self.run_native("--cleanup", "--cache", self.cache)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact private app", result.stderr)
        self.assertTrue(app.exists())
        self.assertTrue(lock.exists())

    def test_additional_unrecorded_process_preserves_copy(self):
        app, manifest, lock = self.make_session()
        binary = app / "Contents/MacOS/Logic Pro"
        binary.parent.mkdir(parents=True)
        subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", str(binary)],
                       input="#include <unistd.h>\nint main(void) { sleep(2); return 0; }\n",
                       text=True, check=True, capture_output=True)
        # No DAW is launched. This harmless own helper exits itself;
        # its unrecorded PID exercises the exact live-executable guard.
        child = subprocess.Popen([str(binary)])
        try:
            result = self.run_native("--cleanup", "--cache", self.cache)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("still use this private Logic copy", result.stderr)
            self.assertTrue(app.exists())
            self.assertTrue(lock.exists())
        finally:
            self.assertEqual(child.wait(timeout=10), 0)


if __name__ == "__main__":
    unittest.main()
