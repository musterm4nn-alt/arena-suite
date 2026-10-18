# Review — fixes for the full repository review (2026-10-18)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5). A first run hung during startup (no CPU time and no
  connection for 14 minutes) and was stopped; this is the second run.
- **Scope:** the uncommitted changes against `c731c85` that fix the external review's 11 findings
  and its two UI priorities. Acceptance criteria: `Docs/review-fixes-2026-10-18.md`.
- **Reviewer saw the real diff:** yes. It read `git diff HEAD` (33 files) and the working-tree
  sources it cites.
- **Reviewer ran tests:**
  - `swift test` for ArenaSuiteCore, ArenaProtocol and ArenaSuiteMCP, all passing. The real-archive
    tests were skipped because that machine has no archive.
  - An `xcodebuild` of the app, which succeeded.
  - It did not run `Scripts/test-offline.sh`; the author did (below).
- **Verdict:** "ready for this milestone".
  - All eleven fixes are in the code, and each has a test that fails on `c731c85`.
  - Nothing in the diff loses acknowledged records or inflates a fidelity claim.

## Findings and what was done

| # | Finding | Outcome |
|---|---|---|
| 1 (High) | Journal recovery quarantines complete, acknowledged records after damage in the final segment, then reuses their sequence numbers. Backup now refuses the same shape, so backup and recovery disagree. | **Not changed here (pre-existing).** The change's own doc disclosed it, and the reviewer agreed it belongs in a separate task. It is a recovery change and needs its own review. It is now recorded with the reviewer's proposed fix and test: recovery should refuse, not quarantine, when `firstCompleteRecord` finds a complete record after the damage. It should be fixed before anything claims "delete the index, replay, identical hashes" for a journal that went through recovery. |
| 2 (Medium) | `remove()`: the session is deleted, then the registry save fails. The account stays listed as signed in, so a sync would send a request without a session. | **Fixed.** That failure also sets `needsSignIn` (the same as a failed session deletion). Test `removalWhoseRegistrySaveFailsLeavesTheAccountUnableToSync` checks that the account is kept, needs sign-in, and that `context(for:)` refuses it. It failed against the unfixed code (no error thrown). |
| 3 (Medium) | `SyncManifest.sessionState` is journaled but not re-applied after a relaunch. | **Not changed, by design.** At launch `restoreAll` checks every saved session with Arena again (`ArenaSessions.restore` → `session.check`), which is newer evidence than the last job's. Re-applying the old state would override that check, for example keeping a session `blocked` that Arena now accepts. The gap the reviewer describes needs the process to die between writing `job.finished` and the next line of the same function. The next launch's check then decides the state. The reason text stays in the journal's `job.finished` record. |
| 4 (Low/Medium) | `rebuild(accounts:)` resets the whole index but replays only the given accounts. | **Fixed.** `rebuild(accounts:)` is removed. A rebuild always replays the full inventory (every journal on disk plus the registry). Its only caller, the real-archive test, uses `rebuild()`. |
| 5 (Low) | MCP accepts a numeric `snapshot`, which might lose precision. | **Not a defect here.** `JSONValue` decodes integers as `Int64` first. A check showed `JSONDecoder` reading `9007199254740993` and `Int64.max` exactly. A client that already rounded the number cannot be detected by any server. The schema keeps declaring a string. |
| 6 (Low) | The empty-archive first step has no branch for blocked or unreachable accounts. | **Fixed.** It offers **Verify**, with a sentence on why, as the sidebar does. App code: build-checked. |
| 7 (Low) | `VerificationService` still read its account list with `try?`. | **Fixed.** The closure throws. The app passes the registry and `journalAccounts()` with `try`. If the list cannot be read, the report has `inventoryProblem` and is never clean, and the journals found on disk are still checked. The problem is shown in Maintenance and in diagnostics (`inventory_problem`). Test `verifyJobIsNotCleanWhenTheAccountListCannotBeRead`. |

Found by the author while the review ran:
- A sync refused before it started (account not signed in) kept its error after a successful sign-in,
  and the message only said "The action could not be completed."
- **Fixed.** `AccountsModel` tracks which shown errors concern the session (a returned
  `sessionState` or a thrown `notSignedIn`). A successful sign-in or Verify clears those.
- The message now says to sign in or verify, then sync again.
- App code: build-checked.

## Unverified assumptions raised

- **Absent `partial` counts as not proven complete.** Every recorded list page carries
  `partial: false` (`Docs/verification-results.md`), so this is a conservative reading. It is not a
  regression, but it stays an assumption.
- **Telemetry is recognized by the key name `metadata` only** (and `providerOptions`). A renamed
  subtree would reach the projection. This matches the keys the ledger records.
- **Verify does not flag a stale decoder version.** It compares checkpoints, not projection
  versions. The next projection rebuilds anyway.

## Test gaps raised

- **No app test target.** `ArchiveModel.refreshDetail`, export of the displayed snapshot and the
  recovery buttons are only compile-checked. The empty-archive Add Account path was also checked by
  hand in the Debug build.
- **The recovery blind spot has no test** (finding 1).
- **Possible silent drop at the journal's end (`JournalCopy`).** One shape can still be dropped
  without an error: a corrupted length field that points past the end of the file, with no complete
  record after it. That shape is indistinguishable from an append cut off by a crash, so the copy
  treats it as one. It is named in the manifest (`incomplete_tail`), never dropped silently. No test
  fuzzes every header byte.
- **No end-to-end backup → restore test with a named incomplete tail.**
- **No export-at-latest test with a claim recorded after the displayed snapshot.**

## Checks run by the author after the fixes

- `swift test --package-path Packages/ArenaSuiteCore --filter removal` (both removal tests), and
  the new removal test against the unfixed code: it fails.
- `swift test --package-path Packages/ArenaProtocol --filter "verifyJob|rebuildReplays|backup"`
- `bash Scripts/build.sh Debug`: no warnings.
- `bash Scripts/test-offline.sh`: exit 0, no failures. That covers every Swift test run, the golden journal, the crash harness, NativeAuthProof and the Python harnesses.
