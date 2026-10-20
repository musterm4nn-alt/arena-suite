# Review — Unfinished conversations and Refresh (2026-10-20)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5).
- **Why required:** the change adds a journal job kind (`conversation_refresh`), new detail-record
  metadata (`entry_type_origin`, `source_updated_at_origin`) and changes how interrupted jobs are
  closed (AGENTS.md: journal format and recovery).
- **Scope:** the uncommitted milestone against `907e9dc`. Acceptance criteria:
  `Docs/sync-refresh-2026-10-20.md`. The separate, uncommitted UI fixes in `App/MainView.swift`,
  `App/Theme.swift` and `App/ArenaWebPane.swift` were not part of it.

## Milestone review

- **Reviewer saw the real diff:** yes. It read `git diff HEAD` and the app files directly. The
  worktree changed while it worked (the `pending` vocabulary moved from SuiteDomain to
  `ArenaArchiveDecoder.unfinishedStatuses`, and the Results section was drafted); it reviewed the
  code as it ended up and said so.
- **Reviewer ran tests:**
  - ArenaProtocol `--filter HistorySyncTests`: 36 passed;
  - ArenaSuiteCore `--filter HistorySyncServiceTests`: 8 passed.
  - Its permissions blocked `Scripts/check-boundaries.py`; it read the script and grepped the MCP
    sources instead (no MCP source names the refresh). It did not build the app. The author ran
    both (below).
- **Verdict:** "Not ready for this milestone — narrowly". It found the design sound: no evidence
  discarded, journal before interpretation, refresh and sync excluding each other per account, an
  interrupted sync not resumed by a refresh, interrupted refreshes closed, and the account and
  conversation taken from the transcript. It asked for findings 1 and 2 to be fixed or documented,
  plus finding 4 and the missing bound and 404 tests.

| # | Finding | Outcome |
|---|---|---|
| 1 (Medium) | An entry listed without `updatedAt` is fetched on every sync before any bound or 404 check, so an unfinished one is never bounded, isn't counted as unfinished, and is fetched again after a 404. | **Documented as an exception and pinned.** This is the always-fetch rule that predates the milestone (§9.3: a change can't be detected without `updatedAt`), and it already warns in the manifest. Criterion 3 now says the limit doesn't apply to such entries, they aren't counted as fetched for being unfinished, and a 404 doesn't stop them. All 338 list entries in the live archive carry `updatedAt` (counted 2026-10-20). New test `withoutUpdatedAtAnUnfinishedConversationKeepsTheAlwaysFetchRule`, which also checks that a refresh of it records no `source_updated_at`. |
| 2 (Medium) | `unfinishedLeft` stayed 0 when the sync stopped before details (403, challenge, exhausted 429/503 during listing), a false claim in `job.finished`. It also counted non-`evaluation` entries. | **Fixed.** It is set from the scanned journal before `job.started` (`unfinishedAtLimit`, `evaluation` only), and narrowed in `fetchDetails` to those this job doesn't fetch. The field's doc comment says so. New test `aSyncStoppedWhileListingStillCountsTheUnfinishedItLeft` (403 on the first page: `blocked`, `unfinishedLeft == 1`). It fails with the initial count removed. |
| 3 (Low) | Refresh snapshots use up the sync's budget of three. | **Documented and pinned.** The limit counts unfinished snapshots, not sync jobs: three pending snapshots mean Arena was still generating three times, whoever asked. Refresh always works. Criterion 3 says so. New test `refreshedUnfinishedSnapshotsCountTowardTheLimit`. |
| 4 (Low) | `try?` turned an index that couldn't be read into "the archive holds no transcript of it". | **Fixed.** `ConversationRefreshService` throws `RefreshError.indexUnreadable`; the app says "Refresh: the archive index could not be read. Nothing was fetched." New test `aRefreshIsRefusedWhenTheIndexCannotBeRead` (drops the index's `conversations` table). It fails with the old `try?`. |
| 5 (Low) | A refresh that worked didn't clear an earlier session problem, as a sync does. | **Fixed.** A refresh with no problem calls `resolveSessionProblem` (cleared only if the account is signed in). Not tested: the app target has no test target. |
| 6 (Low) | A refresh record's `entry_type` came from the last listing, with no origin marker. | **Fixed.** Refresh and by-ID records carry `entry_type_origin: last_listed`, like `source_updated_at_origin`. Asserted in `aRefreshVerifiesIdentityThenFetchesOneDetail` and the by-ID test. |

Test gaps it named, and what was done:

- the unlisted by-ID path run to its limit: **added** `anUnlistedUnfinishedConversationStopsAtTheLimitToo`
  (fails without the limit on unlisted ones);
- a sync closing an interrupted refresh: **added** `aSyncClosesAnInterruptedRefresh`;
- nil `updatedAt` (finding 1), `unfinishedLeft` after a stopped listing (finding 2), an index read
  failure (finding 4), `entry_type_origin` (finding 6): **added** (above);
- the refresh's spacing: **added** to `aRefreshVerifiesIdentityThenFetchesOneDetail` (one pause
  between its two requests);
- a refresh clearing a session problem, and the notice, button and sidebar text: **not added**, the
  app target has no test target. The notice and the disabled button were checked in the app.

Its "unverified assumptions" are recorded in the milestone doc: `pending` as the only unfinished
status (N-020), the list not changing when responses finish or a vote is cast (N-020), and no live
`conversation_refresh` yet.

## Author checks after the fixes

- Each fix reverted on its own makes its test fail: the initial `unfinishedLeft`, the limit on
  unlisted ones, `entry_type_origin`, `indexUnreadable`. The earlier guards (milestone doc) still
  fail theirs.
- Suites: core 128, adapter 185, MCP 17, all passing. `Scripts/check-boundaries.py` passes (60
  files). The Debug app builds.

## Re-review of the fix pass

- **Reviewer saw the real diff:** yes, the milestone files and both docs; it left out the separate
  UI files as asked.
- **Reviewer ran tests:**
  - ArenaProtocol `--filter 'HistorySyncTests|VoteNoteTests'`: 61 passed;
  - ArenaSuiteCore `--filter HistorySyncServiceTests`: 8 passed.
  - It did not run the boundary script, the MCP tests or the build; the author did (below).
- **Verdict:** "Not ready for this milestone". It found the six earlier findings materially
  addressed, each new test load-bearing (finding 1's test pins a documented rule rather than a
  fix), and plan compliance intact: no new route, record before interpret, journal-derived
  state, account isolation, refresh and sync kept apart in interrupted-job handling. It asked for
  findings 1, 2 and 4 to be fixed, plus the kind check.

| # | Finding | Outcome |
|---|---|---|
| 1 (Medium) | A snapshot without `updatedAt` started an unfinished count keyed by `nil`, and `snapshots[id] == run.updatedAt` matched `nil` with `nil`. Such a conversation the listing didn't reach was fetched by ID and counted as fetched for being unfinished, then as left at the limit, which criterion 3 rules out. | **Fixed at the type.** `UnfinishedRun.updatedAt` is a `String`; a snapshot without one starts no count. Such a conversation keeps the always-fetch rule when listed and isn't fetched by ID when not. New test `anUnlistedConversationWithoutUpdatedAtIsNotTrackedAsUnfinished` (identity and one list page, nothing else). It fails with the optional key restored. |
| 2 (Low) | The count of conversations left at the limit, taken when the job starts, stayed 1 when the listing showed a new `updatedAt` for one of them and the job then stopped. | **Fixed.** The job records what it lists, and `unfinishedLeft` is counted again however the job ends: a conversation this job listed with another `updatedAt` isn't held by the limit. The earlier exclusion of what the job fetches was redundant with that and was removed. New test `aChangedUpdatedAtIsNotCountedAsLeftWhenTheSyncStopsBeforeDetails` (403 on page 2), which fails without the recount and also without the listed check; the limit test also checks 0 after a change. |
| 3 (Low) | The service checked only for a snapshot, not the kind; the button was on for any kind. The adapter refused other kinds before any request, but after writing a job start and finish, and the app showed a job outcome instead of "can't be refreshed". | **Fixed.** The adapter defines `ArenaHistorySync.refreshableKinds` (`evaluation`, Arena vocabulary, like `unfinishedStatuses`); the app passes it to `ConversationRefreshService`, whose `canRefresh(kind:latestSnapshot:)` both the service and the button use. New test `aRefreshIsRefusedForAKindArenaCannotFetchAgain` (a snapshot recorded as `agentic`: `notRefreshable`, engine not called). It fails without the kind check. |
| 4 (Low) | A refresh answered 404 has proved the session works, but it didn't clear a shown session problem. | **Fixed.** A refresh that completed (200 or 404) resolves the session problem first, then shows its own message, so the 404 message stays. Not tested: the app target has no test target. |
| 5 (Low) | The refactor freed the account's slot, then awaited `noteSessionState`, and only then cleared the sync's progress and kept its manifest: a sync started in that gap could lose its progress or have its manifest overwritten by the older one. | **Fixed.** `runJob` clears the progress and keeps the manifest (syncs only) right after freeing the slot, before any suspension, as the service did before this milestone. Not tested: the gap is one actor hop, which no seam can hold open. |
| 6 (Low) | Criterion 10 said the early stop is not taken; criteria 3 and 8 overstated. | **Fixed** with the above: criterion 10 says the listing stops early as before; criteria 2, 3, 4, 5, 6 and 8 say what the code now does. |

Its test gaps: the non-`evaluation` filter in `unfinishedAtLimit` has no fixture (only the listing
can set a type, and a list entry of another kind never gets a detail snapshot in a sync); the
app-level behaviour and the reentrancy window are untested, as above.

## Author checks after the second fixes

- Each new fix reverted on its own makes its test fail: the `nil` key, the final recount, the
  listed check, the service's kind check.
- Suites: core 128, adapter 188, MCP 17, all passing. `Scripts/check-boundaries.py` passes (60
  files). The Debug app builds, and so does the milestone without the separate UI change (its
  files applied alone to a temporary worktree at `907e9dc`, unsigned).

## Third run

- **Reviewer saw the real diff:** yes, all 19 changed and new files.
- **Reviewer ran tests:**
  - ArenaProtocol `--filter 'HistorySyncTests|VoteNoteTests'`: 64 passed;
  - ArenaSuiteCore `--filter HistorySyncServiceTests`: 8 passed.
  - Not run by it: the full suites, the boundary script, the build.
- **Verdict:** "ready for this milestone". It confirmed the second run's outcomes 1, 2, 3 and 5, including a resumed job: the interrupted job's entries go through the same `add`, so a new `updatedAt` it had listed is excluded from the recount. It called outcome 4 right in its order but overstated, and every finding Low.

| # | Finding | Outcome |
|---|---|---|
| 1 | `detailsRefetchedUnfinished` counted planned refetches, so a 404, a failure or a stop made it larger than what arrived, contradicting its doc comment ("Of `detailsFetched`"). | **Fixed.** It counts valid snapshots that arrived. The 404 test asserts 0 and fails with the old count. |
| 2 | Clearing a session problem after a completed refresh is nearly unreachable: a session problem usually leaves the account not signed in, which turns Refresh off. A 200 the decoder doesn't recognize is `partial`, so it doesn't count as answered. | **Documented.** Criterion 8 says the problem is cleared only if the account is signed in, that this is rare, and that signing in again clears the message anyway. The code is kept for the race where a newer sign-in lands while a refresh runs. The criterion now quotes the button's help exactly. |
| 3 | If the listing stopped stating `updatedAt` for a conversation with a count, it would be fetched by ID "every sync", defeating the limit. | **Checked, overstated; pinned.** It is fetched by ID once more: that snapshot has no `updatedAt`, so the count ends and nothing more is fetched by ID (listed, it keeps the always-fetch rule). New test `anUnfinishedConversationWhoseListingLostUpdatedAtIsFetchedByIDOnceMore`; criterion 3 says so. |
| 4 | Before listing, the count of conversations left at the limit comes from the journal, so a resumed job stopped at the identity check can't account for a page its interrupted job listed. | **Documented** in criterion 3 (the count from the journal). |
| 5 | A by-ID record wrote `entry_type` `evaluation` as a constant with a `last_listed` origin. | **Fixed:** it writes the type from the last listing, so the origin stays true if more kinds become refreshable. No test can tell the difference today: `evaluation` is the only refreshable kind. |
| 6 | A refresh's trailing writes in the app can land after a newer job started in the `await` window. | **Not changed.** Transient, as it says: the newer job writes last on every path. |

## Author checks after the third run

- The planned-count fix reverted makes the 404 test fail.
- Suites: core 128, adapter 189, MCP 17, all passing. `Scripts/check-boundaries.py` passes (60
  files). The Debug app builds.
