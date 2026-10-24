"""Build the native standalone app; no Logic files or Python runtime are bundled."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path, default=root / "dist")
parser.add_argument("--module-cache", type=Path, default=os.environ.get("CLANG_MODULE_CACHE_PATH"))
args = parser.parse_args()
app = args.output.resolve() / "Logic ARA Launcher.app"
resources = app / "Contents/Resources"
macos = app / "Contents/MacOS"
if app.exists():
    shutil.rmtree(app)
resources.mkdir(parents=True, exist_ok=True)
macos.mkdir(parents=True, exist_ok=True)
(resources / "native").mkdir(exist_ok=True)
shutil.copy2(root / "native/LogicARABridge.dylib", resources / "native/LogicARABridge.dylib")
entry = macos / "Logic ARA Launcher"
compiler = ["xcrun", "swiftc", "-target", "arm64-apple-macos15.4", "-O"]
if args.module_cache:
    args.module_cache.mkdir(parents=True, exist_ok=True)
    compiler += ["-module-cache-path", str(args.module_cache.resolve())]
subprocess.run([*compiler, str(root / "native/Launcher.swift"), "-o", str(entry)], check=True)
with (app / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump({"CFBundleIdentifier": "org.rysupaudio.logic-ara-launcher",
                   "CFBundleName": "Logic ARA Launcher", "CFBundleExecutable": entry.name,
                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.2.0",
                   "CFBundleVersion": "7", "LSMinimumSystemVersion": "15.4",
                   "LSArchitecturePriority": ["arm64"],
                   "NSHumanReadableCopyright": "Copyright © 2026 Rys Up Audio LLC. MIT License. Independent of Apple.",
                   "NSHighResolutionCapable": True}, stream)
shutil.copy2(root / "LICENSE", resources / "LICENSE.txt")
shutil.copy2(root / "README.md", resources / "README.md")
print(app)
