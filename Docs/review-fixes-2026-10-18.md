# Fixes for the full repository review (2026-10-18)

The user supplied an external review of `main` at `c731c85` ("Arena Suite — full repository review
and critique"). Its verdict: "not ready for this milestone", with 11 defects reproduced on synthetic
inputs.

This page records, for each finding:
- whether it was confirmed against the code;
- the fix;
- the regression test.

It also covers the two UI priorities. The review itself is not committed: it is the user's file, and
it names local paths.

**Status:** all 11 findings were confirmed and fixed. Both UI priorities are done. Each fix has a
regression test; finding 3's was also run against the old code, which trapped. A second model
reviewed the change ("ready for this milestone", `Docs/reviews/2026-10-18-full-review-fixes.md`).
Its correctness findings are fixed below. `bash Scripts/test-offline.sh` passes. The Debug app
builds without warnings. **Committed locally, not pushed.**

## Findings

| # | Finding (review severity) | Confirmed | Fix | Regression tests |
|---|---|---|---|---|
| 1 | A backup could silently lose acknowledged records (High) | Yes. Any scan problem in the active segment was treated as an in-flight tail, so a bad digest in record 2 of 3 gave a "verified" backup with 1 record. | `JournalCopy.copy` leaves out only an incomplete final record: a `.truncated` scan with no complete record after it (`SegmentScanner.firstCompleteRecord`). The writer appends a record's parts in order, so a crash or a running append can leave only that shape. Any other damage throws the new `JournalError.damagedRecord`, and the backup is refused. A left-out record is named in the manifest (`incomplete_tail`, optional, additive) and in the Maintenance result. Restore copies strictly (`allowingIncompleteTail: false`). | `backupRefusesDamagedRecordsRatherThanDroppingThem` (first record's payload, middle record's digest, middle record's length), `backupCopiesOnlyCompleteRecordsOfTheActiveSegment` (now checks `incomplete_tail`), `strictCopyRefusesAnIncompleteRecord` |
| 2 | A snapshot of another conversation was accepted and relabeled (High) | Yes | `ArchiveIndex.conversation` checks that the sequence is one of the conversation's snapshots before any query, and throws `QueryError.snapshotNotInConversation`. That error becomes `ExportError.snapshotNotInConversation`, and MCP turns it into a tool error. App, exports and MCP all go through this one check. | `aSnapshotOfAnotherConversationIsRejectedNotRelabeled` (foreign, missing, list-only, `Int64.max`, `Int64.max + 1`, `UInt64.max`), `anExportOfAnotherConversationsSnapshotIsRefused` |
| 3 | Re-authentication could change and return the wrong account (High) | Yes. Both variants: the old code updated the wrong account with three accounts, and **trapped** ("Index out of range") with two. Reproduced by running the new test against the old code. | `signInAgain` looks the record up by ID after every suspension and never keeps a position across `await`. | `reauthenticationFindsItsAccountAgainAfterSuspending` (2 and 3 accounts, with a controlled continuation, no timing) |
| 4 | A rebuild left out the journals of removed accounts (High) | Yes. Also, an unreadable registry turned into an empty list (`try?`), so a rebuild would reset the index and replay nothing. | `ArchiveService` replays every journal on disk (`JournalStore.journalAccounts()`, which throws when the folder exists but cannot be listed) plus the caller's accounts. It reads that list **before** `index.reset()`. The app passes the registry with `try`. The verify job's index check uses the same list. | `rebuildReplaysJournalsOfRemovedAccountsAndFailsBeforeResetting` |
| 5 | Partial or unproven pagination was reported as `completed` (Medium) | Yes | A page whose `partial` is not `false`, that has failed sources, or that ends without `hasMore` makes the job `partial`, with the reason "listing not proven complete (…)". The details are still fetched. A partial page never ends the listing early. A resumed job carries the gaps of its recorded pages, and a missing `hasMore` on resume is no longer labeled `hasMore=false`. The recorded evidence shows Arena always sends `hasMore`, `partial: false` and zero failed sources, so normal syncs are unaffected. | `listingThatIsNotProvenCompleteIsNotCompleted` (4 cases), `aPartialUnchangedPageDoesNotEndTheListingEarly`, `aResumedJobKeepsItsRecordedPagesIncompleteness`, `aResumedJobWhoseLastPageHadNoHasMoreIsNotCompleted` |
| 6 | A rejected sync left the account labeled signed in (Medium) | Yes. In addition, the app cleared the error for every returned manifest. | `SyncManifest.sessionState` (additive): `needsSignIn` for 401 or no session, `quarantined` for another principal, `blocked` for 403 or a challenge. `HistorySyncService` applies it through `AccountService.noteSessionState`, but only while the account still has the job's credential generation, is signed in and is not busy, so an old job never downgrades a newer sign-in. In the app, a failed manifest stays in the sidebar until that account syncs completely, the session is fixed, or the user dismisses it. | `aRejectedSyncUpdatesTheAccountsState` (needsSignIn, quarantined, blocked), `anOlderJobsRejectionNeverDowngradesANewerSignIn`, `identityOutcomesAtJobStart` (now checks `sessionState`, plus a mismatch case) |
| 7 | One large snapshot argument crashed the MCP process (Medium) | Yes | MCP accepts `1...Int64.max`. The index never converts a caller's sequence with a trapping conversion: membership is checked first, and `snapshotLocation` uses `Int64(exactly:)`. | `outOfRangeSnapshotsAreToolErrorsNotCrashes` runs the real stdio binary with `"0"`, `Int64.max`, `Int64.max + 1` and `UInt64.max`, as a string and as an integer. The process stays alive and every one is a tool error. |
| 8 | Removing an account hid a credential-deletion failure (Medium) | Yes (`try? await sessions.forget`) | A failed deletion throws `AccountError.sessionDeletionFailed` **before** the registry entry is removed. The account is kept, so the removal can be retried, and its state becomes `needsSignIn` (its in-memory session may be gone). The app says so. | `removalKeepsTheAccountWhenItsSavedSessionCannotBeDeleted` (failure, then a retry that succeeds) |
| 9 | Nested metadata could reach normalized exports and MCP (Medium) | Yes. Every structured payload went through `canonicalJSON` unfiltered. | `canonicalJSON` replaces the value of every `metadata` key (any letter case, any depth) with `[omitted: telemetry]`, as the masked raw export does, and drops `providerOptions` at any depth. The decoder is now **`arena-decoder/2`**, so existing indexes rebuild on the next projection. The exact raw export, an explicit opt-in, is unchanged. | `nestedMetadataNeverReachesTheProjection` (tool args and results, sources, structured reasoning, an unknown block; normalized, Markdown, masked raw, search; the exact raw export keeps the bytes) |
| 10 | The open Latest transcript stayed stale after a sync (Medium) | Yes | `ArchiveModel.reload()` (after a sync, rebuild or restore) also reloads the open conversation. Latest moves to the newest snapshot, and a chosen snapshot stays. The evidence panel is kept unless the displayed snapshot changed. An export uses the displayed snapshot (`ConversationDetail.snapshotSequence`), never whatever is latest when it runs. | App code (there is no app test target). Checked by build. The core behavior is covered by the tests for 11. |
| 11 | Historical exports picked up later titles and model claims (Medium) | Yes | An explicit snapshot is a **frozen view**: that record's title, update time and message count, and only the claims observed at or before it. Each claim carries `recordSequence`, which normalized JSON exports as `record_sequence`. Exports always render the frozen view of one sequence (`nil` = latest at render time), so a sequence always yields the same bytes. `snapshot: nil` remains the live view in the app. Where several names were observed for a model, the latest observed up to the snapshot wins (it was the earliest). | `anExplicitSnapshotIsFrozenAgainstLaterObservations`, `aHistoricalExportStaysFrozenAfterLaterSyncs` (all formats) |

## UI priorities

- **P1, durable sync state and recovery.**
  - A failed or partial sync stays in the sidebar status. It goes away when that account syncs
    completely, when Sign In or Verify fixes the session, or when the user dismisses it.
  - Each failure has its next step:
    - **Sign In…** (needs sign-in or identity mismatch) opens the Accounts page with that account's
      form;
    - **Verify** (blocked or unreachable);
    - **Sync Again** (partial).
  - The Sync History tooltip names each account's last result and when it ended.
  - The transcript's model-claims list shows each claim's record.
- **P2, the first action on an empty archive.**
  - The home screen offers **Add Account…**, which opens the Accounts page with the form.
  - After that it offers **Sync History** while nothing is archived, or **Sign In…** when the
    account needs it.
  - Checked in the Debug build against an empty, separate archive folder: the button opens the
    form. Nothing was entered.

## Follow-ups from the second-model review

- **Failed registry save during removal.** If the session was deleted but the registry could not be
  saved, the account is kept and now needs sign-in, so nothing syncs without a session.
- **Rebuild always replays everything.** `rebuild(accounts:)` is removed: it reset every account
  but replayed only some.
- **Verify never passes on a shorter list.** An unreadable account list makes the report unclean
  (`inventoryProblem`), and the journals on disk are still checked.
- **Verify on the empty-archive home screen** for a blocked or unreachable account.
- **Session errors clear on sign-in.** A sync refused because the account was not signed in is
  cleared by a successful sign-in or Verify, and its message says what to do.
- **Not changed:**
  - re-applying a journaled `sessionState` at launch, because the launch check with Arena is newer
    evidence;
  - rejecting numeric MCP snapshots, because integers decode exactly;
  - journal recovery, which is a separate task.

## Behavior and format changes to know

- **One index rebuild.** The first launch of a build with `arena-decoder/2` rebuilds the index from
  the journals, once. The journals are not touched. If an older build (`/1`) runs against the same
  archive afterwards, it rebuilds again.
- **Export bytes change, schema names unchanged.**
  - Normalized JSON claims have `record_sequence`.
  - Both JSON exports' `scope` has `facts_scope`.
  - The normalized `excluded` list names the any-depth masking.
  - Exports made before and after this change therefore differ. Re-exports with this build are
    deterministic per sequence.
- **Additive manifest fields.** The backup manifest's `incomplete_tail` and the sync manifest's
  `sessionState` (written in `job.finished`) are omitted when absent.
- **A sync can now end `partial`** where it used to say `completed`, but only for listings that do
  not prove themselves complete. An account whose sync was rejected now shows that state, and
  further syncs are refused until Sign In or Verify.

## Not done here (deliberately)

- **CI.** The review notes that there is no GitHub Actions workflow. A macOS workflow for
  `Scripts/test-offline.sh` needs a runner with this Xcode and Swift 6 toolchain, which cannot be
  checked from here. Left for the user to decide.
- **Maintenance action hierarchy** (cognitive load), an **optional reading scale**, and showing the
  dataset audit's LSH limit above 2,000 texts more prominently. These are design follow-ups.
- **Journal recovery has the same blind spot as finding 1.** On open, the writer quarantines
  everything after damage in the final segment, including complete, acknowledged records, and
  reuses their sequence numbers. The review did not flag this; it was found while fixing finding 1.
  It changes recovery, so it is a separate task.
