---
name: Arena Suite Architecture
description: Apply Arena Suite's v3 plan — read-only native archiver scope, protocol-evidence rules, journal invariants, traffic policy, phase gates, and testing expectations.
---

# Arena Suite implementation skill

Use `Arena-Suite-Master-Plan-v3.md` as the source of truth. v2 is superseded; consult it only for background, and where the two conflict, v3 wins. This skill is a compact operating guide, not a replacement for the plan.

## 1. Before changing code

Identify the current phase (v3 §13) and read its section plus any sections it references. Inspect the current implementation, fixtures, tests and recent diff. Write down:

- phase scope and its definition of done;
- evidence already verified (ledger IDs);
- assumptions still needing live verification;
- acceptance tests;
- module boundaries touched.

Do not build later phases because their abstractions look convenient.

## 2. Scope

v1 is a **native, read-only archiver**: sign in, restore sessions, sync history, journal it, index it, browse/search, export Raw/Normalized/Markdown.

Out of scope for v1: natively sending prompts, continuing, stopping, voting, revealing models, uploading, timing fingerprints. Native generation (Track B) is blocked by reCAPTCHA v3 (N-004) and starts only under v3 §1's conditions. Never copy browser tokens, run a hidden WebView, or solve/bypass challenges.

The one browser runtime is the embedded arena.ai in the main window (ADR 0006, `App/ArenaWebPane.swift`). The user drives it; it has one web profile and at most one session (one web view) per account, opened only by the user's click. Keep it free of injected scripts, page/cookie/storage reads, scheme handlers, user-agent changes and any additional web view. Its traffic is outside the journal; it archives only through the native history sync. Voting and reveal exist only inside Track B as manual, user-clicked actions (v3 §1); never automated, batched, suggested, or exposed to MCP.

## 3. Evidence rules

- Never invent endpoints, parameters, fields, cursor names or semantics. Use only what the ledger records.
- Classify evidence: `verified_observation`, `repository_evidence`, `design_decision`, `assumption`, `NEEDS PROTOCOL VERIFICATION`.
- Live experiments: announce each one, one request at a time, no retries without the user's say-so, record results in the ledger.
- Compare identity by server IDs (`id`, `supabaseUserId`), never by email.

## 4. Traffic policy (v3 §2)

User-initiated sync by default; one request in flight per account; a minimum delay between detail requests; honor `Retry-After`/429/503; stop on 403, challenge, or unexpected HTML; incremental sync; no user-agent or TLS spoofing; never use extra accounts to get around limits.

## 5. Journal rules

- Journal every response body exactly as Foundation delivered it, before decoding.
- The journal is authoritative; SQLite is rebuildable. Local user state that must survive a rebuild goes into `local.control` records.
- An exchange counts as archived only after it is appended; say "appended" or "synced to disk" precisely.
- Torn tails are quarantined before repair; corruption in sealed segments is never skipped silently.
- Credentials: passwords are never stored; cookies live only in Keychain; evidence records the omission, not the values.

## 6. Data-model rules

- Conversations have many snapshots; later snapshots never overwrite earlier ones.
- Messages form a graph via parent IDs; missing ancestors stay as unresolved nodes; lanes and branches are never merged.
- Remote IDs are opaque and scoped by account and entity kind.
- Model claims keep their source (`history_list`, `history_detail`, …) and are never upgraded to verified identity.
- Value states: `known`, `not_exposed`, `parse_failed`, `redacted`, `unknown`. "Complete" always names its scope.

## 7. Account isolation

Each sync job binds one account at start. Identity is verified before every job and after every restore; a mismatch quarantines the session. Switching the UI's selected account never redirects or cancels another account's job.

## 8. Boundaries

Only `ArenaAdapter` knows Arena routes. Views call `ApplicationActions`; they never touch URLSession, the journal or GRDB. `CaptureJournal` knows nothing about Arena schemas. Nothing links `Tools/NativeAuthProof`. `Scripts/check-boundaries.py` enforces this; register new modules there.

## 9. Testing expectations

- Journal: golden binary fixture, subprocess kill at every write boundary, torn tail, ENOSPC/EIO.
- Decoders: unknown fields, unknown entry types, malformed and truncated bodies, large integers.
- Sync: repeated cursor, missing cursor with `hasMore`, `partial`/`failedSources`, 401/403/429 handling, resume after interruption without refetching.
- Projection: delete the index, replay, and get identical entity IDs and content hashes.
- Accounts: two accounts (or one, per A7), identity mismatch quarantine, relaunch and rebuild restore.
- Exports: deterministic bytes for frozen inputs; nothing partial left after cancellation.

## 10. Definition of done for a phase

- The phase's definition of done in v3 §13 is met.
- `Scripts/test-offline.sh` passes.
- No invariant was weakened silently.
- New evidence and assumptions are recorded in the ledger or status file.
- The reviewer examined the diff at phase end (and for credential/Keychain/journal/recovery changes), running one shell command per call, and stated whether it saw the diff and ran the tests.
- Important findings are fixed or explicitly deferred.

When in doubt, choose evidence preservation and explicit uncertainty over convenient inference.
