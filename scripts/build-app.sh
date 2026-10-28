#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=".build/DellKVMFlash.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DellKVMFlash "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
[[ "${1:-}" == "--no-open" ]] || open "$APP"
