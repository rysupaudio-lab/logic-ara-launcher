"""Admission and cleanup tests; native end-to-end evidence is separate."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch, MagicMock

spec = importlib.util.spec_from_file_location("launcher", Path(__file__).resolve().parents[1] / "launcher.py")
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Logic Pro.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "com.apple.logic10", "CFBundleShortVersionString": "12.4", "CFBundleVersion": "6707"}
        self.write_info()

    def write_info(self):
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)

    def test_unknown_build_never_checks_signature_or_launches(self):
        self.info["CFBundleVersion"] = "9999"
        self.write_info()
        with patch.object(launcher.platform, "system", return_value="Darwin"), patch.object(launcher.platform, "machine", return_value="arm64"), patch.object(launcher, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "Unsupported Logic"):
                launcher.inspect_logic(self.app)
            run.assert_not_called()

    def test_wrong_engine_is_rejected_before_signature_check(self):
        with patch.object(launcher.platform, "system", return_value="Darwin"), patch.object(launcher.platform, "machine", return_value="arm64"), patch.object(launcher, "sha256", return_value="different"), patch.object(launcher, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "engine differs"):
                launcher.inspect_logic(self.app)
            run.assert_not_called()

    def test_native_architecture_required(self):
        with patch.object(launcher.platform, "system", return_value="Darwin"), patch.object(launcher.platform, "machine", return_value="x86_64"):
            with self.assertRaisesRegex(RuntimeError, "native Apple Silicon"):
                launcher.inspect_logic(self.app)

    def test_wrong_macore_is_rejected(self):
        engine_hash = launcher.SUPPORTED[("12.4", "6707")]
        with patch.object(launcher.platform, "system", return_value="Darwin"), patch.object(launcher.platform, "machine", return_value="arm64"), patch.object(launcher, "sha256", side_effect=[engine_hash, "different"]), patch.object(launcher, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "MACore differs"):
                launcher.inspect_logic(self.app)
            run.assert_not_called()

    def test_active_lock_is_never_stolen(self):
        cache = self.root / "cache"
        lock = cache / "active.lock"
        lock.mkdir(parents=True)
        owner = lock / "owner.json"
        owner.write_text("another session")
        helper = self.root / "helper.dylib"
        helper.write_bytes(b"test")
        with patch.object(launcher, "inspect_logic", return_value={}), patch.object(launcher, "prepare_copy") as prepare:
            with self.assertRaisesRegex(RuntimeError, "session is active"):
                launcher.launch(self.app, None, cache, helper)
            prepare.assert_not_called()
        self.assertEqual(owner.read_text(), "another session")

    def test_copy_failure_preserves_source_and_releases_owned_lock(self):
        cache = self.root / "cache"
        helper = self.root / "helper.dylib"
        helper.write_bytes(b"test")
        receipt = {"engine_sha256": "a", "macore_sha256": "c", "executable_sha256": "b"}
        with patch.object(launcher, "inspect_logic", return_value=receipt.copy()), patch.object(launcher, "prepare_copy", side_effect=RuntimeError("copy failed")):
            with self.assertRaisesRegex(RuntimeError, "copy failed"):
                launcher.launch(self.app, None, cache, helper)
        self.assertFalse((cache / "active.lock").exists())
        sessions = list((cache / "runs").iterdir())
        saved = json.loads((sessions[0] / "session.json").read_text())
        self.assertEqual(saved["status"], "failed")
        self.assertTrue(saved["source_unchanged"])
        self.assertTrue((self.app / "Contents/Info.plist").exists())

    def test_cancel_does_not_launch(self):
        with patch.object(launcher, "dialog", return_value="false"), patch.object(launcher, "launch") as launch:
            launcher.main(["--gui"])
            launch.assert_not_called()

    def test_startup_failure_never_terminates_live_logic(self):
        cache = self.root / "cache"
        helper = self.root / "helper.dylib"
        helper.write_bytes(b"test")
        receipt = {"engine_sha256": "a", "macore_sha256": "c", "executable_sha256": "b"}
        child = MagicMock(pid=987)
        child.poll.return_value = None
        def prepare(source, destination, receipt):
            destination.mkdir()
        def spawn(*args, **kwargs):
            # Keep ordinary system file panels: this OS's native local panel
            # cannot complete Save even in the unredirected control app.
            self.assertNotIn("-NSUseRemoteSavePanel", args[0])
            (Path(kwargs["cwd"]) / "bridge.log").write_text("bridge_refused reason=test\n")
            return child
        with patch.object(launcher, "inspect_logic", return_value=receipt.copy()), patch.object(launcher, "prepare_copy", side_effect=prepare), patch.object(launcher.subprocess, "Popen", side_effect=spawn):
            with self.assertRaisesRegex(RuntimeError, "Bridge refused"):
                launcher.launch(self.app, None, cache, helper)
        child.terminate.assert_not_called()
        child.kill.assert_not_called()
        session = next((cache / "runs").iterdir())
        self.assertTrue((session / "Logic Pro.app").exists())
        self.assertTrue((cache / "active.lock").exists())
        self.assertEqual(json.loads((session / "session.json").read_text())["status"], "detached")

    def test_takeover_marker_preserves_child_and_lock(self):
        cache = self.root / "cache"
        helper = self.root / "helper.dylib"
        helper.write_bytes(b"test")
        marker = self.root / "user-takeover.request"
        receipt = {"engine_sha256": "a", "macore_sha256": "c", "executable_sha256": "b"}
        child = MagicMock(pid=987)
        child.poll.return_value = None
        def spawn(*args, **kwargs):
            marker.write_text("foreign document observed")
            return child
        with patch.object(launcher, "inspect_logic", return_value=receipt.copy()), patch.object(launcher, "prepare_copy", side_effect=lambda source, destination, receipt: destination.mkdir()), patch.object(launcher.subprocess, "Popen", side_effect=spawn):
            result = launcher.launch(self.app, None, cache, helper, extra_env={"LOGIC_ARA_DETACH_REQUEST_FILE": str(marker)})
        self.assertEqual(result["status"], "detached")
        child.terminate.assert_not_called()
        child.kill.assert_not_called()
        self.assertTrue((Path(result["owned_app"])).exists())
        self.assertTrue((cache / "active.lock").exists())


if __name__ == "__main__":
    unittest.main()
