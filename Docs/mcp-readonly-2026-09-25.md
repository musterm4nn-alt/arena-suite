# §14 — Read-only MCP (2026-09-25)

Go decision: the user, 2026-09-25 ("get started on the §14 items"). Scope from plan v3 §14:
search, get conversation and export through the existing ApplicationActions; no Arena network
actions, no voting or reveal, no bulk operations.

## Acceptance criteria

1. A stdio MCP server, `arena-suite-mcp`, in its own package, linked only against ArenaSuiteCore
   (`SuiteDomain`, `ApplicationActions`, `ArchiveIndex`). It cannot reach `ArenaAdapter`,
   `FoundationTransport` or any network API; `Scripts/check-boundaries.py` enforces this.
2. The index is opened read-only: nothing is created, migrated, re-permissioned, projected or
   rebuilt, and SQLite itself refuses writes. A missing, symlinked or non-owner-only index or
   registry is refused, never tightened.
3. Tools: `list_accounts`, `list_conversations`, `search`, `get_conversation`,
   `export_conversation` (Markdown, Normalized JSON, raw JSON). All are annotated read-only.
   Nothing is written to disk; results are returned inline.
4. Output is byte-identical to the app's `ExportService.render` for the same snapshot.
5. Arena `metadata` telemetry never leaves: raw JSON is always masked (`mask-metadata/1`), and
   exact raw bodies are unavailable because they need the app's explicit confirmation.
6. Bounded: list ≤ 200 per page, search ≤ 50 hits and ≤ 500-character queries, conversation IDs
   ≤ 256 bytes, renders ≤ 8 MiB, input lines ≤ 16 MiB.
7. "Complete" names its scope: `list_accounts` reports `indexed_through_sequence` per account, and
   every list or search result carries a `scope`.
8. MCP stdio protocol: `initialize` (version negotiation), `ping`, `tools/list`, `tools/call`;
   notifications and client responses get no reply; parse errors, batches and unknown methods
   get JSON-RPC errors; stdout carries only JSON-RPC.

## What was built

| Piece | Where |
|---|---|
| Read-only index open (`readonly` connection, no migration, permission check without chmod) | `ArchiveIndex.init(readingExistingAt:)` |
| Read-only archive service (no decoder: project/rebuild/replay throw `readOnly`; evidence reports the decoder version recorded in the index) | `ArchiveService.init(readOnly:journals:)` |
| Tools | `Packages/ArenaSuiteMCP/Sources/ArchiveMCP/ArchiveTools.swift` |
| Registry read that never tightens | `PrivateFile.readWithoutTightening`, `AccountRegistryStore.loadWithoutTightening` |
| JSON-RPC over stdio (bounded `LineFramer`), no dependencies | `MCPServer.swift`, `JSONValue.swift` |
| Deny-list of write/network APIs in the MCP module, self-tested | `Scripts/check-boundaries.py` |
| Executable (`--archive-root`, `--version`) | `Sources/arena-suite-mcp/main.swift` |
| Build and install to `~/.local/bin` | `Scripts/build-mcp.sh` |

## Evidence

- **Tests** (`swift test --package-path Packages/ArenaSuiteMCP`, 16 tests, part of
  `Scripts/test-offline.sh`):
  - protocol negotiation, errors, notifications and the exact tool list;
  - byte equality with the app's three export formats, and snapshot selection;
  - no telemetry key in any tool output, including the decoded raw payload, and the exact-body
    argument rejected;
  - a full session leaves every archive file unchanged, byte and mtime, except SQLite's `-shm`
    shared-memory index, which WAL readers must update to coordinate with the app;
  - a read-only service refuses projection, rebuild and replay, and SQLite rejects `reset()`;
  - a missing index creates nothing, and loose permissions or a symlink are refused;
  - the built binary answers over real stdio with nothing on stderr;
  - after review: a loose registry is refused without being changed; a session with no `-shm`
    creates only `-shm`; framing (split, CRLF, blank, oversized and unterminated lines);
    `JSONValue` bool/int/double/large-integer handling; bounded IDs; and a corrupted journal
    giving an error with no content in it.
- **Real archive** (counts only):
  - 3 accounts, indexed through 30 / 49 / 31, and 57 conversations.
  - The index and WAL digests were unchanged after a session.
  - All 57 conversations went through all three formats: 153 renders succeeded. The 6 list-only
    entries (×3 formats) got the "no archived detail snapshot" error.
  - No Arena `metadata` object appeared in any output. The only `metadata` objects left are the
    journal's own capture envelope, as in the app's raw export. "recaptcha" appears only inside
    message text.

## Limits

- The server reads whatever the app last indexed. It never syncs, and never projects journal
  records the app has not projected yet.
- Registering the server with an MCP client is left to the user (`Scripts/build-mcp.sh` prints an
  example).
- Local-threat assumption: permissions are checked and then the file is opened, so a local
  process racing the check, or a symlinked parent directory, is not defended against. This is the
  same trust boundary as the app's own index open.
- Independent review: `Docs/reviews/2026-09-25-mcp.md`.
- If the app rebuilds its index during a call, that call may see an empty or partial index. The
  next call sees the rebuilt one.
