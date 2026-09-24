# Phase 4 — decoding and index

Plan v3 §8, §10, §13 (Phase 4). Completed 2026-09-24. Spec: `Docs/phase4-spec.md`.
Review: `Docs/reviews/2026-09-24-phase4.md`.

## Definition of done (N-013)

| Criterion | Result |
|---|---|
| Deleting the index and replaying reproduces identical entity IDs and content hashes | **Passed on the real archive:** 110 journal records → 57 conversations (51 snapshots; the 6 `agentic` entries are list-only), 628 messages, 3 422 blocks, 571 model claims, 74 feedback records; `rebuild` gives the same `contentDigest` and row counts. Also offline: batch boundaries and crash replay do not change the digest. |
| Unknown fields are counted, not lost | Unknown keys are counted by JSON path; unprojectable elements and type mismatches become counted warnings. Real archive: 0 unknown paths, 0 warnings. |
| Privacy | `metadata` subtrees (anti-abuse telemetry) and `providerOptions` (encrypted reasoning) never reach the index; attachment URLs are reduced to "has URL". Verified by searching the real index for telemetry markers (none found). |

## Design

- `SuiteDomain/Archive.swift`: provider-neutral events and values.
- `ArenaAdapter/Decoders/ArenaArchiveDecoder.swift` (`arena-decoder/1`): journal record → events,
  unknown paths, warnings. Only 200/complete list and detail exchanges project; detail 404 → absence.
- `ArchiveIndex` (GRDB 7.11.1, WAL): deterministic keys (account, remote ID, journal sequence), one
  transaction per batch with its checkpoint, FTS5 over the latest snapshot per conversation, typed
  queries, `contentDigest()`.
- `ApplicationActions/ArchiveService`: incremental projection from each account's checkpoint in
  batches of 200; full rebuild; rebuild automatically if the decoder version changes.
- Real-archive check: `ARENA_SUITE_REAL_ARCHIVE=<archive> swift test --package-path Packages/ArenaProtocol --filter realArchive`
  (read-only on the journals, temporary index, prints counts only).

Not yet wired into the app (Phase 5).
