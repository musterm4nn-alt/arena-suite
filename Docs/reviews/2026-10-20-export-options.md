# Review — Export options (2026-10-20)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5).
- **Scope:** the uncommitted export-options milestone against `6da813d` (history filters).
  Acceptance criteria: `Docs/export-options-2026-10-20.md`.
- **Runs:** three:
  - the milestone;
  - a re-review of the first fix pass;
  - a check of the second fix pass (below).
- **Reviewer saw the real diff:** yes. It read `git diff HEAD` for every modified file and every
  new file in full.
- **Reviewer ran tests (first run):**
  - the export tests in ArenaProtocol (21 passed; the real-archive test was skipped, as its runs
    have no archive path);
  - ArenaSuiteMCP (17 passed).
  - It did not run `Scripts/test-offline.sh`, the boundary check, the app build or a probe of
    Foundation's escaping, which its permissions blocked. The author ran them (below).
- **Verdict (first run):** "Ready for this milestone". There were no Critical or High findings. It
  asked for findings 1–4 to be fixed, and the escaping, copy-path and golden-byte tests to be
  added, before committing. All are done except an app test for the copy path (below).

## First run: findings and what was done

| # | Finding | Outcome |
|---|---|---|
| 1 (Medium) | A last answer whose prompt is missing from the snapshot was exported without it, while the export said its prompts were included. | **Fixed.** `lastAnswer(of:)` returns a `LastAnswer` that names every message a listed message replies to and the snapshot does not hold (`parents_not_in_snapshot` in `selection`, and a Markdown line). Their role is unknown, so the export names them and does not refuse. New test `aPromptMissingFromTheSnapshotIsNamedNotClaimed`, which fails with the fix reverted. |
| 2 (Medium) | Export did nothing, silently, when the detail on screen was not yet the selection's. | **Fixed.** `ArchiveModel.beginExport()` records a refusal ("The conversation is still loading…"). The Export button and the popover's actions are enabled only by `canExport`: the detail shown is the selection's, and no export is running. A second export while one runs is refused the same way. |
| 3 (Medium) | A stale "Copied…" notice could survive a failed copy, so the user might paste the wrong conversation. | **Fixed.** `lastExport` and `lastCopy` are replaced by one `exportOutcome` (saved, copied or refused). It is cleared at the start of every attempt and when the conversation or snapshot shown changes. Refusals show in the notice, not only the sidebar. `copy(_:scope:with:)` reports a pasteboard write that returns false as a refusal. Checked in the Debug build (milestone doc, Results). |
| 4 (Medium) | The exact-raw link ignored the visible "Last answer" scope and stayed enabled. | **Fixed.** The link reads "Whole conversation as Raw JSON with exact bodies (includes Arena telemetry)…" and passes `.wholeConversation` explicitly. The confirmation says Raw JSON holds the whole conversation of the snapshot shown. The link is disabled unless `canExport`. |
| 5 (Low) | Ordinals in a last-answer export were renumbered from 0 without saying so. | **Fixed.** Messages keep their position in the whole snapshot, and `selection.ordinal_basis` says so. The assertion in `theLastAnswerHoldsTheLastMessagesTheirPromptAndOnlyTheirVotes` fails with the fix reverted. |
| 6 (Low) | A NULL or malformed stored `last_message_ids` was read as "Arena listed none". | **Fixed.** `ConversationDetail.lastMessageIDs` is `[String]?`: nil when the stored value is not a JSON array of strings. Export refuses with `lastMessagesUnreadable`, and the app suggests rebuilding the index. New test `anUnreadableStoredListIsNotAnEmptyOne` (`not-json` and NULL). |
| 7 (Low) | One refusal text covered both "empty list" and "a listed message is not in the snapshot". | **Fixed.** These are now separate errors with separate texts: `noLastAnswer` (empty or not in the response) and `lastMessageNotInSnapshot`. `noLastAnswerIsGuessed` checks each. |
| 8 (Low) | Claims with a subject kind this version does not know were kept without saying so. | **Fixed by declaring it.** They are kept, not guessed about, and `selection.model_claim_basis` says so. New test `claimsOfUnknownSubjectsAreKeptNotGuessed`. |
| 9 (Low) | The milestone doc claimed 7 new tests; there were 6. | **Fixed.** The Results section now gives the current count: 12 test functions, 14 cases. |

Test gaps raised, and what was done:

- **JSONL line integrity: added.** A probe confirmed that Foundation writes U+0085, U+2028 and
  U+2029 raw. JSONL now escapes them (`ExportService.lineSafe`). New test
  `jsonlEscapesCharactersThatSomeReadersTreatAsLineEnds` fails with the escaping reverted.
- **Whole-conversation regression: added.** `wholeConversationExportsAreUnchanged` pins Normalized
  JSON and Markdown to hashes taken from `6da813d`, with the record digest and account ID masked.
- **Frozen last-answer export: added.** `aFrozenSnapshotsLastAnswerUsesItsOwnList`.
- **Corrupt index value: added.** See finding 6.
- **Not covered: app state.**
  - The app has no test target. The copy path, `beginExport`, the notice and the exact-raw link's
    state are build-checked and exercised by hand in the Debug build.
  - The copy path renders through `ExportService.render`, which the tests cover.
- **Not covered: cross-process determinism.** It is not exercised for JSONL, which uses sorted
  keys like the dataset files.

## Re-review of the first fix pass

- **Reviewer saw the real diff:** yes. It read `git diff HEAD` and the new files in full.
- **Reviewer ran tests:**
  - ArenaProtocol `--filter Export`: 27 passed;
  - all of ArenaSuiteCore: passed, 0 failures.
  - It did not build the app or run the offline script, the boundary check or MCP.
- **Findings 1–9:** it confirmed the fixes for the export bytes, refusals, JSONL line integrity,
  `[String]?` handling and the MCP boundary.
- **Verdict:** "Not ready for this milestone", because its finding 1 below was incomplete.
  Findings 2–4 could follow later; all are fixed.

| # | Finding | Outcome |
|---|---|---|
| 1 (Medium) | The notice could outlive the snapshot it described. A sync replacing Latest did not clear it, and an attempt finishing after a switch put its outcome under the new conversation. For a copy, the clipboard then held another conversation. | **Fixed.** `refreshDetail` clears the notice when the shown snapshot changes. `export` and `copy` check `stillShown` after rendering. A copy whose conversation or snapshot is no longer shown writes nothing and records nothing. A refusal is recorded only while the same snapshot is shown. A written file's notice is still shown, because it names the file (title, conversation ID, snapshot). Build-checked; the app has no test target. |
| 2 (Low) | The clipboard was cleared before the write was known to succeed. | **Fixed.** The pasteboard writer keeps the previous plain text and puts it back if `setString` fails. Other kinds of content are not kept; the code comment and the milestone doc say so. |
| 3 (Low) | A parent present in the snapshot but with no stated role was left out silently. | **Fixed.** It is named in `parents_with_unknown_role` and in a Markdown line, and not included. A parent with a stated role other than `user` is not a prompt and is not included. New test `aParentWithoutAStatedRoleIsNamedNotGuessed`, which fails with the fix reverted. |
| 4 (Low) | `ConversationDetail` defaulted `lastMessageIDs` to `[]`, so "not supplied" looked like "Arena listed none". | **Fixed.** The default is nil ("not known"). |

Test gap raised: export was not shown to write nothing for every last-answer refusal. **Added:**
`noLastAnswerIsGuessed` now exports in every refusal case and checks the folder stays empty.

## Check of the second fix pass

- **Reviewer saw the real diff:** yes.
- **Reviewer ran tests:** ArenaProtocol `--filter Export`, 28 passed. Its permissions refused the
  app build, so it did not compile `App/`. The author did, after the fixes below.
- **Finding 1 of the re-review:** fixed in code. It judged the saved-file exception "sound enough
  for data integrity", because the file name identifies the source. The paths are build-checked
  only.
- **Verdict:** "Ready for this milestone". The remaining findings are Low; all are fixed.

| # | Finding | Outcome |
|---|---|---|
| 1 (Low) | The doc said a saved notice names the conversation ID; the file name holds only its first 8 characters and a title cut to 60. | **Fixed in the doc.** It now says what the file name holds. |
| 2 (Low) | A second attempt while an export ran recorded "An export is already running", which could outlive that export. | **Fixed.** A second attempt is ignored and records nothing; the controls are disabled while an export runs. |
| 3 (Low) | While a chosen snapshot loaded, export and copy used the previous snapshot still on screen. | **Fixed.** `displayedSnapshot` requires the detail shown to be the chosen snapshot, or, for Latest, not a frozen one. Until then the controls are disabled and an attempt is refused as still loading. |
| 4 (Low) | The unreadable-list refusal was not export-tested, and the "nothing written" check passed vacuously when the folder did not exist. | **Fixed.** `Harness.expectRefusedWithoutWriting` creates the folder first. It then checks that every format refuses in both render and export and that the folder stays empty. It runs for `noLastAnswer`, `lastMessageNotInSnapshot` and `lastMessagesUnreadable` (`not-json` and NULL). |
| 5 (Low) | A failed restore of the previous clipboard text was not reported. | **Fixed.** The writer returns `ClipboardWrite.refused(previousTextRestored:)`. The notice says whether the clipboard holds its previous text again. |

Unverified assumption raised: what `lastMessageIds` means. **Recorded** as protocol ledger N-018:
the observed counts are `verified_observation`, and the meaning is marked `assumption`.

Gaps that remain: the app has no test target. The notice lifecycle (sync replacing Latest, an
attempt finishing after a switch), the chosen-snapshot guard and the clipboard writer are
build-checked. Of these, only the copy paths were exercised by hand. Raw JSON's whole-conversation
bytes are not pinned by a golden hash; its code is unchanged.

## Checks run by the author after the fixes

- `swift test --package-path Packages/ArenaProtocol --filter Export`: 28 passed, after each fix
  pass.
- Each fix's test fails when that fix is reverted: escaping, ordinals, the missing-parent list and
  the unknown-role list.
- `swift test --package-path Packages/ArenaSuiteCore`: passed.
- `bash Scripts/build.sh Debug`: no Swift warnings, after each fix pass. Checked in the Debug build
  against a synthetic archive (see the milestone doc, Results). After the last pass, a
  whole-conversation copy of Normalized JSON gave 3 messages and no `selection`. Its notice
  replaced the earlier "Exported…" one.
- `swift build --package-path Packages/ArenaSuiteMCP`: builds.
- `bash Scripts/test-offline.sh`: exit 0, after each fix pass.
- `python3 Scripts/check-boundaries.py`: passed.
