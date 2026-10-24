#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname -m)" != arm64 ]; then
  echo 'Build natively on an Apple Silicon Mac.' >&2
  exit 1
fi
xcrun clang++ -arch arm64 -mmacosx-version-min=15.4 -std=c++17 -fobjc-arc -dynamiclib \
  -framework Foundation -framework AppKit -framework AudioToolbox -framework Carbon \
  -Wl,-undefined,dynamic_lookup native/Bridge.mm -o native/LogicARABridge.dylib
codesign --force --sign - native/LogicARABridge.dylib
/usr/bin/python3 tools/build_app.py
codesign --force --sign - 'dist/Logic ARA Launcher.app'
echo 'Built standalone native dist/Logic ARA Launcher.app. No Python or compiler is needed to run the app.'
