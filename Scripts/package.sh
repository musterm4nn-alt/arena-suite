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
if pgrep -f "^$destination/Contents/MacOS/ArenaSuite" >/dev/null; then
  echo "Arena Suite is running from $destination. Quit it, then run this again." >&2
  exit 1
fi
# Unique staging next to the destination (same volume, so the swap is a rename). If this script is
# killed mid-swap, the previous app is in ~/Applications/.arena-suite-install.*/previous.app.
staging=$(mktemp -d "$HOME/Applications/.arena-suite-install.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$built" "$staging/Arena Suite.app"
codesign --verify --deep --strict "$staging/Arena Suite.app"
if [ -d "$destination" ]; then
  previous=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$destination/Contents/Info.plist" 2>/dev/null || echo "?")
  mv "$destination" "$staging/previous.app"
  if ! mv "$staging/Arena Suite.app" "$destination"; then
    mv "$staging/previous.app" "$destination"
    echo "Install failed; the previous version was put back." >&2
    exit 1
  fi
  echo "Upgraded $previous -> $version in ~/Applications."
else
  mv "$staging/Arena Suite.app" "$destination"
  echo "Installed $version in ~/Applications."
fi
# ditto keeps the build's folder date, so the Dock and Finder could keep an older install's cached
# icon: give the bundle a new date and register it again with Launch Services.
touch "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination" || true
