#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional stable signing identity (plan v3 §4, A6). Without it the proof is ad-hoc signed and
# Keychain items saved by one build may need re-approval or a new sign-in after the next.
if [[ -f Config/Signing.local.env ]]; then source Config/Signing.local.env; fi
identity="${ARENA_SUITE_SIGNING_IDENTITY:--}"

swift build --package-path Tools/NativeAuthProof --arch arm64
bin="$(swift build --package-path Tools/NativeAuthProof --arch arm64 --show-bin-path)"
app="DerivedData/NativeAuthProof.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/NativeAuthProof" "$app/Contents/MacOS/NativeAuthProof"
cp Tools/NativeAuthProof/Info.plist "$app/Contents/Info.plist"
# A unique build number per build, so every rebuild has a distinct code signature.
plutil -replace CFBundleVersion -string "$(date +%Y%m%d%H%M%S)" "$app/Contents/Info.plist"
codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
codesign --verify --deep --strict "$app"
if [[ "$identity" == "-" ]]; then echo "Signed ad-hoc"; else echo "Signed with configured identity"; fi
