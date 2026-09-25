#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/check-boundaries.py
swift test --package-path Packages/ArenaSuiteCore
python3 Tools/FixtureHarness/check_journal_golden.py
swift run --package-path Tools/CrashHarness CrashHarness
swift test --package-path Packages/ArenaProtocol
swift test --package-path Packages/ArenaSuiteMCP
swift test --package-path Tools/NativeAuthProof
python3 Tools/FixtureHarness/run_transport.py
python3 Tools/FixtureHarness/fixture_manifest.py
python3 Tools/FixtureHarness/test_manifest.py
