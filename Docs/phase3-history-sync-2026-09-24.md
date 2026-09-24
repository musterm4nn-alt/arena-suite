# Phase 3 — history sync

Plan v3 §9 and §13, Phase 3. Completed 2026-09-24.

## Acceptance criteria and result (N-012)

| Criterion (plan §13) | Result |
|---|---|
| Sync of the user's **real history completes with a manifest** | **Passed.** Three accounts: 14 (9 evaluation, 5 agentic), 30 (29 evaluation, 1 agentic, 2 pages) and 13 entries; all `completed`, `listingEnd = hasMore=false`, 0 failures. Manifests are the `job.finished` payloads. |
| **Interrupting and resuming refetches nothing already committed** | **Passed.** The app was `kill -9`ed after 1 list page and 4 details of the first account (journal: `job.started`, no `job.finished`). The relaunch closed that job as `interrupted` (`resumed_by` = new job), reused its recorded page (no list request: it had `hasMore=false`), fetched only the 5 missing details. Independent journal audit: every conversation has exactly one detail snapshot in every account. |
| **403 / 429 stop the job cleanly** | Offline tests: 403 → `blocked`, 401 → `needsSignIn`, both recorded then stopped with `job.finished`; 429/503 honor a `Retry-After` ≤ 120 s once, else `partial`. Not provoked live (no reason to). |
| Incremental | A second live sync of all three accounts: 1 list page each, 0 details, `caught up: page 1 unchanged and newest-first`. |

**New observation:** on every page seen live, entries are ordered newest-first by `updatedAt`
(evaluation and agentic mixed). The early stop checks this per page and falls back to listing
everything if a page is not ordered.

## Design

- **Record before interpret.** Every list and detail response is appended to
  `Archive/accounts/<uuid>/journal` as an `exchange` record (exact body as delivered by Foundation;
  method, route template, path, query, status, transfer end, byte counts, response headers with
  `Set-Cookie` values `[omitted]`, request header names, start/end ticks; `credential_omitted`) and
  synced, then decoded. Undecodable, challenge and error responses are recorded too.
- **Journal is the checkpoint.** At job start `ArchivedState.scan` derives, from raw records only,
  which conversations have a valid snapshot (and for which `updatedAt`), which entries were listed,
  and which job never finished. No separate state file.
- **Jobs:** verify identity → `job.started`, `session.verified` → list (`limit=20`,
  `includeArchived=true`, cursor from the previous page) → details for `evaluation` entries that are
  new or whose `updatedAt` changed → `job.finished` with the manifest. `agentic` entries are archived
  list-only (no observed detail route).
- **Stops:** 401 → needs sign-in; 403, HTML/challenge → blocked; repeated cursor, repeated page,
  `hasMore` without cursor, transport failure, other HTTP → partial (resumable); session replaced by a
  new sign-in → stop; cancellation → cancelled. `partial=true`/`failedSources` become warnings.
- **Traffic:** one request in flight per account (session single-flight), ≥ 1 s between requests,
  user-initiated only (`--sync-on-launch` is a development flag used for this verification).

## Tests

Adapter sync tests (14): pagination and exact recording, Set-Cookie omission, incremental catch-up,
changed-only refetch, full pass, resume from an interrupted journal, 403/401, Retry-After, anomalies,
challenge and undecodable pages recorded first, session replacement, identity failure writes nothing,
cancellation. Service tests: signed-in only, one job per account, accounts independent.
`Tools/FixtureHarness/audit_archive_journals.py` re-reads live journals with an independent spec reader.

## Not in Phase 3

Decoding into conversations/messages and the SQLite index (Phase 4). Sync status lives in the job
manifests and the value-free diagnostics status file only.
