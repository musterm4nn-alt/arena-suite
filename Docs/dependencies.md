# Dependency/toolchain baseline

Tested host: Xcode 27.0 (27A266a), Swift 6.4, macOS 27.2 ARM64; app deployment target 14.0.
`Config/toolchain.json` records exact compiler/OS versions. XcodeBuildMCP defaults were inspected;
available workflow tools were simulator-oriented, so macOS builds use ordinary `xcodebuild`.
Context7 discovery initially returned no tools. On continuation it became available and was used
to cross-check GRDB requirements/APIs and the MCP product name. Version-specific dependency checks
also used the actual pinned upstream Package.swift/source/license files and compilation; see
`verification-results.md` for documentation scope and version caveats.

App and two production local packages currently have **zero third-party dependencies**.
`Tools/DependencyProbe` is an isolated build probe for the master-plan selected dependencies.
Its `Package.resolved` pins all exact revisions and must be retained when committing this foundation.

| Package | Tested version | License inventory at pinned checkout |
|---|---|---|
| GRDB.swift | 7.11.1 (`b83108d10f42680d78f23fe4d4d80fc88dab3212`) | MIT |
| MCP Swift SDK | 0.12.1 (`a0ae212ebf6eab5f754c3129608bc5557637e605`) | Transition: Apache-2.0 for new/consented code, retained MIT contributions; docs CC-BY-4.0 per LICENSE |
| EventSource | 1.5.1 | MIT |
| swift-atomics | 1.3.1 | Apache-2.0 with Swift exception |
| swift-collections | 1.6.0 | Apache-2.0 with Swift exception |
| swift-log | 1.15.1 | Apache-2.0 with Swift exception |
| swift-nio | 2.103.0 | Apache-2.0 with Swift exception; retain bundled third-party notices when distributing |
| swift-system | 1.8.1 | Apache-2.0 with Swift exception |

## Tested deviation from proposed MCP pin

MCP 0.11.0 (`6112a3995a992d159ad0e82c2d62a008ce932666`) failed Swift 6.4 compilation in
`NetworkTransport.swift:532,763`: mutable send/receive continuation flags captured across
isolation boundaries (`sending ... risks causing data races`). Strict concurrency was retained.
The observed upstream 0.12.1 tag builds successfully with the same toolchain; pin advanced to it.
No upstream code was patched or warnings disabled. MCP handshake/stdio/server conformance remains
Phase 9 work; successful import/link is not that conformance gate.

The probe reads system SQLite diagnostics from an in-memory GRDB connection:
`sqlite_version() = 3.54.0`, including `ENABLE_FTS5`, `ENABLE_SNAPSHOT`, `THREADSAFE=2`.
Run the probe for the complete sorted compile-option inventory; values are host-specific and are
not hardcoded production assertions. Future packaged releases retain licenses/notices and runtime
diagnostics, and reverify on the macOS support floor. No Package.resolved is fabricated for the
local-only production packages, since there are no remote pins there.
