#!/bin/bash
# Personal release (plan v3 §13, Phase 7): Release build signed with the local identity, verified,
# then installed to ~/Applications/Arena Suite.app. An existing install is replaced only after the
# new copy is complete; the archive in ~/Library/Application Support/Arena Suite is never touched.
# Usage: Scripts/package.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f Config/Signing.local.xcconfig ]; then
  echo "Config/Signing.local.xcconfig is missing. A stable signing identity is required so the" >&2
  echo "Keychain keeps granting access to saved sessions after upgrades (N-009)." >&2
  exit 1
fi

xcodebuild -project ArenaSuite.xcodeproj -scheme ArenaSuite -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build -quiet
built="DerivedData/Build/Products/Release/ArenaSuite.app"

codesign --verify --deep --strict "$built"
if codesign -dv "$built" 2>&1 | grep -q 'Signature=adhoc'; then
  echo "The Release build is ad-hoc signed; refusing to install it." >&2
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$built/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$built/Contents/Info.plist")
if /usr/libexec/PlistBuddy -c 'Print' "$built/Contents/Info.plist" | grep -qi 'debug'; then
  echo "Unexpected debug marker in Info.plist." >&2
  exit 1
fi
echo "Built Arena Suite $version ($build), signature verified."

[ "${1:-}" = "--no-install" ] && exit 0

destination="$HOME/Applications/Arena Suite.app"
mkdir -p "$HOME/Applications"
staging="$HOME/Applications/.Arena Suite.app.installing"
rm -rf "$staging"
ditto "$built" "$staging"
codesign --verify --deep --strict "$staging"
if [ -d "$destination" ]; then
  previous=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$destination/Contents/Info.plist" 2>/dev/null || echo "?")
  if pgrep -f "$destination/Contents/MacOS/" >/dev/null; then
    rm -rf "$staging"
    echo "Arena Suite is running from $destination. Quit it, then run this again." >&2
    exit 1
  fi
  rm -rf "$destination.previous"
  mv "$destination" "$destination.previous"
  mv "$staging" "$destination"
  rm -rf "$destination.previous"
  echo "Upgraded $previous -> $version in ~/Applications."
else
  mv "$staging" "$destination"
  echo "Installed $version in ~/Applications."
fi
