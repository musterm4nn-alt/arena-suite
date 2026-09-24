#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --package-path Tools/NativeAuthProof --arch arm64
bin="$(swift build --package-path Tools/NativeAuthProof --arch arm64 --show-bin-path)"
app="DerivedData/NativeAuthProof.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/NativeAuthProof" "$app/Contents/MacOS/NativeAuthProof"
cp Tools/NativeAuthProof/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --options runtime "$app"
codesign --verify --deep --strict "$app"
