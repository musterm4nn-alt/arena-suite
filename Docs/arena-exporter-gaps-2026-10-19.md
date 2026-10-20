# What arena-suite is missing from arena-exporter

Oct 19, 2026 · @Max Mustermann

## Summary

arena-suite (AS) lacks nine capabilities that arena-exporter (AE) has. Four can be added within AS's rules and one partly. Three need the page read live, which ADR 0006 rules out, and one, other platforms, is out of scope by design.

The biggest gaps are full Agent conversations and attachment contents. AS saves `agentic` entries from the history list only, and keeps attachment names but not the files.

Compared: `musterm4nn-alt/arena-exporter` at `1168227` (v2.2.2) and `musterm4nn-alt/arena-suite` at `6da813d`.

## The gaps

| # | Missing in AS | How AE does it | AS today | Can AS close it? |
| --- | --- | --- | --- | --- |
| 1 | Full Agent conversations | Captures the live Agent stream and workspace output; `/agent/` page fallback for older ones | `agentic` entries saved from the list only | Yes, once a detail route is observed |
| 2 | Attachment and file contents | Downloads files into `files/` and the Battle A/B folders | Name, type and whether a URL existed | Yes, plan §9.4 |
| 3 | Failed and retried requests | `meta.request_attempts[]` with outcome, `retry_of` and timestamps | Only what history keeps: message status, `failureReason` | No: needs live traffic |
| 4 | Live stream evidence | Stream framing, event counts, finish evidence, 3 headers | None; reads finished JSON | No: needs live traffic |
| 5 | Which model was requested | Requested model IDs and the page's model catalog at that moment | Model claims stored in history | No: needs live traffic |
| 6 | Correcting your own vote | Popup buttons to override or clear a Battle vote | Votes are read-only | Yes, as a local note |
| 7 | Archive encryption, GitHub backup, folder import, saving each turn automatically | Built into the extension | FileVault, local backup only, save on sync | Partly: encryption, off-machine backup and import fit; saving per turn needs live traffic |
| 8 | Export options: Last answer only, clipboard, JSONL per conversation | Popup actions | Raw, Normalized, Markdown; JSONL only for datasets | Yes |
| 9 | Platforms beyond the Mac | Chrome and Firefox on any OS | macOS 14, Apple Silicon | No, by design |

## Details

**1. Agent conversations.** AE reads the Agent stream at `/ai-proxy/realtime/v1/sessions/<id>/out` (`src/injected-main.js`). It pulls workspace output from `workspace/latest` (`src/capture.js`). `src/history-backfill.js` falls back to the `/agent/` page when no JSON detail exists. AS status.md accepts `agentic` as list-only until a detail route is observed.

**2. Attachments.** AE writes files below each conversation folder. Its manifest grants access to Arena's file storage hosts (`*.r2.cloudflarestorage.com`, `*.r2.dev`). AS decodes `experimental_attachments` into name and content type only (`ArenaArchiveDecoder.swift`). The index stores only whether a URL was present. `Capabilities.swift` lists `downloadWorkspace` without implementing it.

**3. Request attempts.** AE's schema 2.1 records one entry per request: `started_at`, `responded_at`, `completed_at`, `retry_of`, and an outcome. Outcomes include `captcha_rejected`, `selection_rejected`, `network_error`, `stream_error` and `aborted` (`docs/export-schema.md`). A send that never became a saved message is invisible to AS.

**4. Stream evidence.** AE's `meta.transport` keeps event counts, completion evidence and three response headers: `x-session-settled`, `x-stream-version`, `x-arena-chat-id`. AS's history JSON has none of this.

**5. Requested model.** AE stores `requested_model_a_id`, `requested_model_b_id`, `requested_agent_model_id` and the catalog snapshot (`meta.model_catalog`). AS only has the model claims history returns.

**6. Vote correction.** AE's popup sends `AE_SET_MANUAL_VOTE` with A, B, both good, neither good or clear (`src/popup.js`). AS decodes votes read-only and treats their meaning as an assumption (ledger N-016).

**7. Archive features.** AE has these that AS lacks:

- AES-GCM encryption with PBKDF2 keys and a recovery tool (`src/encrypted-archive.js`, `tools/decrypt-archive.mjs`).
- GitHub backup through a durable upload queue (`src/github-backup.js`).
- Importing existing archive folders (`src/archive-import.js`).
- Saving automatically when a turn completes.

**8. Export options.** AE's popup offers a Full or Last answer scope, copy to clipboard, and JSONL (`src/streaming-export.js`). AS exports whole conversations as files.

**9. Platforms.** AE runs in Chrome and in Firefox 140 or later on any OS. Its optional native helper is Mac-only. AS requires macOS 14 on Apple Silicon.

## Already covered by AS

These look like gaps but are not:

- **Reasoning and tool calls.** AS decodes them, shows them as expandable sections, and can include them in search. It drops only reasoning that Arena sends encrypted (`providerOptions`).
- **Multiple turns and Battle lanes.** AS keeps the message graph with lanes and branches.
- **JSON and Markdown export.** AS's Raw and Normalized JSON cover AE's JSON export.
- **History backfill.** AS syncs past conversations through the same history routes AE's backfill uses (ledger R-001).
- **Browsing on the Mac.** AS replaces AE's `macos/ArenaArchive` reader.

## Closing the gaps

This order puts the cheapest local work first and the work that needs new protocol evidence last:

- [x] **Export options (8):** add a Last answer scope, copy to clipboard, and JSONL per conversation. These are local work on data AS already has.
- [x] **Archive encryption and import (7):** add an encrypted backup format (done) and import of AE archive folders (not to be built: the user chose "Skip import" on 2026-10-20). GitHub backup is a separate decision because it sends private conversations off the Mac.
- [x] **Vote correction (6):** store it as a local note beside Arena's recorded vote. Never send it to Arena: plan §1 limits voting to Track B.
- [x] **Attachments (2):** observed (N-019) and downloaded after each detail fetch, plan §9.4 (`Docs/attachments-2026-10-20.md`). Old conversations' files arrive with their next Refresh.
- [ ] **Agent detail (1):** observe a native detail route for `agentic` entries in `Tools/NativeAuthProof` first. AE's backfill gives leads, not evidence.

Items 3, 4, 5 and per-turn saving need the page read while it streams. ADR 0006 forbids that in AS, and the embedded arena.ai view can't run extensions. Using AE alongside AS in Chrome or Firefox keeps that evidence, but in a separate archive.
