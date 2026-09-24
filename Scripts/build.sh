#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project ArenaSuite.xcodeproj -scheme ArenaSuite -configuration "${1:-Debug}" -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build
