#!/usr/bin/env python3
"""Package the built native app. Signing is explicit; notarization/publication is separate."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, default=root / "dist/Logic ARA Launcher.app")
parser.add_argument("--output", type=Path, default=root / "dist/packages")
parser.add_argument("--identity", help="Developer ID Application identity; with --preserve-signature, signs only the DMG")
parser.add_argument("--preserve-signature", action="store_true", help="Verify the existing app/helper and package without re-signing either")
parser.add_argument("--name", default="Logic ARA Launcher")
parser.add_argument("--version", default="0.2.0-candidate.5")
parser.add_argument("--stem", default="Logic-ARA-Launcher-0.2.0-candidate.5-arm64")
parser.add_argument("--helper-relative", default="Contents/Resources/native/LogicARABridge.dylib")
parser.add_argument("--requirements", default="Apple Silicon, macOS 15.4+, and your licensed original Apple-signed Logic Pro 12.4 (6707)")
parser.add_argument("--cache-name", default="LogicARALauncher")
parser.add_argument("--project-type", default=".logicx")
parser.add_argument("--host-name", default="Logic")
args = parser.parse_args()
app = args.app.resolve(strict=True)
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
def run(*argv):
    subprocess.run([str(a) for a in argv], check=True)
identity = args.identity or "-"
sign = ["/usr/bin/codesign", "--force", "--sign", identity]
if args.identity:
    sign += ["--options", "runtime", "--timestamp"]
helper = app / args.helper_relative
with (app / "Contents/Info.plist").open("rb") as stream:
    app_info = plistlib.load(stream)
native_files = [app / "Contents/MacOS" / app_info["CFBundleExecutable"], helper]
native_before = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest() for p in native_files}
if not args.preserve_signature:
    run(*sign, helper)
    run(*sign, app)
else:
    run("/usr/bin/codesign", "--verify", "--strict", helper)
run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
stem = args.stem
if Path(stem).name != stem or not stem:
    raise ValueError("--stem must be a single filename component")
zip_path = out / f"{stem}.zip"
dmg_path = out / f"{stem}.dmg"
if zip_path.exists():
    zip_path.unlink()
run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path)
with tempfile.TemporaryDirectory(prefix="logic-ara-package-", dir=out) as scratch:
    staging = Path(scratch)
    shutil.copytree(app, staging / app.name, symlinks=True)
    (staging / "Applications").symlink_to("/Applications")
    (staging / "Install and start.txt").write_text(
        f"Drag {args.name}.app to Applications, then open it.\n\n"
        f"Requires {args.requirements}.\n"
        "No Python, compiler, Apple binaries, third-party plugins or licenses are included.\n\n"
        f"Open a backed-up {args.project_type} project through the launcher. Keep the launcher open while using its {args.host_name} copy.\n"
        f"Quit that {args.host_name} copy normally to remove the temporary copy. Your installed {args.host_name} is unchanged.\n"
        f"Uninstall: drag only {args.name}.app to Trash. Session diagnostics are in\n"
        f"~/Library/Caches/{args.cache_name}. Quit all launcher copies before cleaning its cache.\n\n"
        "This is an experimental candidate, independent of Apple and plugin vendors.\n"
        "Compatibility is limited to the exact host build and documented test cases.\n"
        "Read the release qualification and known limitations before using backed-up projects.\n"
    )
    run("/usr/bin/hdiutil", "create", "-ov", "-format", "UDZO", "-volname", args.name, "-srcfolder", staging, dmg_path)
    # Some macOS builds leave the creator's unmounted write-once device
    # attached after create returns. Its exclusive file access blocks notarytool.
    # Eject only this invocation's exact newly created image, never other images.
    images = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"]))
    attached = [item for item in images.get("images", []) if item.get("image-path") == str(dmg_path)]
    if attached:
        if len(attached) != 1:
            raise RuntimeError("Ambiguous created-image attachment; preserved for review")
        image = attached[0]
        entities = image.get("system-entities", [])
        if image.get("owner-uid") != os.getuid() or any("mount-point" in item for item in entities):
            raise RuntimeError("Created image has an unexpected owner or mounted user; preserved for review")
        whole_disk = next((item.get("dev-entry") for item in entities if item.get("content-hint") == "GUID_partition_scheme"), None)
        if not whole_disk or not whole_disk.startswith("/dev/disk") or not whole_disk[9:].isdigit():
            raise RuntimeError("Created-image device identity unavailable; preserved for review")
        run("/usr/bin/hdiutil", "detach", whole_disk)
if args.identity:
    run("/usr/bin/codesign", "--sign", identity, "--timestamp", dmg_path)
native_after = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest() for p in native_files}
if args.preserve_signature and native_before != native_after:
    raise RuntimeError("Qualified native files changed while preserving signatures")
signature = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
developer_id = "Authority=Developer ID Application:" in signature
files = [*native_files, zip_path, dmg_path]
receipt = {"schema": "ara-launcher-package/1", "name": args.name, "version": args.version, "architecture": "arm64", "minimum_macos": app_info.get("LSMinimumSystemVersion"), "python_runtime_required": False,
           "signed": developer_id, "app_signature_preserved": args.preserve_signature,
           "native_hashes_unchanged": native_before == native_after,
           "notarized": False, "published": False, "qualification": "see exact release qualification; packaging alone does not establish runtime compatibility",
           "files": [{"path": str(p), "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]}
(out / f"{stem}.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
