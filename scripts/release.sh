#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
./scripts/build-app.sh --no-open

mkdir -p dist
ZIP="dist/DellKVMFlash-$VERSION.zip"
rm -f "$ZIP"
# --norsrc: the system provenance xattr would otherwise become ._ AppleDouble entries in the zip.
ditto -c -k --norsrc --keepParent .build/DellKVMFlash.app "$ZIP"

cd dist
shasum -a 256 "DellKVMFlash-$VERSION.zip" | tee "DellKVMFlash-$VERSION.zip.sha256"
echo "Released dist/DellKVMFlash-$VERSION.zip"
