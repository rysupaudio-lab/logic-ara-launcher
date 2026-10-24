"""Build a small source distribution launcher; no Logic files are bundled."""
from pathlib import Path
import plistlib
import shutil

root = Path(__file__).resolve().parents[1]
app = root / "dist/Logic ARA Launcher.app"
resources = app / "Contents/Resources"
macos = app / "Contents/MacOS"
resources.mkdir(parents=True, exist_ok=True)
macos.mkdir(parents=True, exist_ok=True)
(resources / "native").mkdir(exist_ok=True)
shutil.copy2(root / "launcher.py", resources / "launcher.py")
shutil.copy2(root / "native/LogicARABridge.dylib", resources / "native/LogicARABridge.dylib")
entry = macos / "Logic ARA Launcher"
entry.write_text('''#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../Resources"
if [ "$#" -gt 0 ]; then
  exec /usr/bin/python3 launcher.py "$@"
fi
exec /usr/bin/python3 launcher.py --gui
''')
entry.chmod(0o755)
with (app / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump({"CFBundleIdentifier": "org.rysupaudio.logic-ara-launcher",
                   "CFBundleName": "Logic ARA Launcher", "CFBundleExecutable": entry.name,
                   "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0",
                   "CFBundleVersion": "2", "LSMinimumSystemVersion": "15.4",
                   "NSHighResolutionCapable": True}, stream)
print(app)
