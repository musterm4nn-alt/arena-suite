# Review — Local vote notes (2026-10-20)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5).
- **Why required:** the change adds a journal record (`local.control`) and an index migration
  (AGENTS.md: journal format).
- **Scope:** the uncommitted vote-notes milestone against `544194b` (encrypted backup).
  Acceptance criteria: `Docs/vote-notes-2026-10-20.md`.

## Milestone review

- **Reviewer saw the real diff:** yes. It read `git diff HEAD` and the four new files, with plan
  §1, §7, §10 and §13, `JournalWriter`, `JournalRecovery`, `AccountService`, `Backup.swift` and the
  app views.
- **Reviewer ran tests:**
  - ArenaProtocol `--filter "VoteNote|Maintenance|Backup"`: 48 passed;
  - all of ArenaSuiteCore: passed.
  - Its permissions blocked `Scripts/check-boundaries.py`; it grepped the MCP and export sources
    instead. The author ran the script (below).
- **Verdict:** "Not ready for this milestone". It called the journal format, projection,
  digest/backup compatibility and maintenance reservation "generally sound", and plan §1
  "compliant": no transport, no route, nothing pre-selected, no MCP path. It asked for finding 1 to
  be fixed, and finding 2 to be fixed or deferred with a plan.

| # | Finding | Outcome |
|---|---|---|
| 1 (High) | `setNote` took the account and conversation from the selection. After you clicked another conversation, the old transcript stayed on screen (and its menu worked) until the new one loaded. A note on it went to the new selection's account and conversation with the old vote's messages. | **Fixed.** The menu passes the transcript it is in, and `setNote` takes the account, conversation and snapshot from it. `VoteNoteService.set` takes them explicitly and requires the vote, exactly as recorded, to be in that snapshot of that conversation in the index; otherwise it refuses (`voteNotInConversation`). New test `aNoteIsRefusedOutsideTheTranscriptItWasShownIn`: another account, conversation or snapshot, and an altered vote are refused with nothing written. It fails with the check removed. |
| 2 (Medium) | The projection version named only the Arena decoder. Local records read by another local decoder (an older or newer build) would not be projected again without a manual rebuild. | **Fixed.** Once a local record is projected, the index stores `meta.local_control_version` (`local-control/1`), and `project` rebuilds when it differs. It is stored only then. A version folded into the existing `decoder_version` would have changed every archive's digest and failed every older backup's check. New test `aDifferentLocalVersionRebuildsTheIndex` (fails without the check). Known limit: a build from before notes doesn't know this key. |
| 3 (Low) | If the flush failed after the append, the app said the note was not saved, though the record might survive. | **Fixed.** `appendLocal` throws `appendedButNotFlushed`; the app says the note may not survive a restart and isn't shown until the next update. Not tested: the store opens its own writers, so there is no seam to inject the failure. |
| 4 (Low) | Removing an account between the registry check and the append could add a note to the removed account's kept journal. | **Documented as a known limit** (criterion 6). Removal deletes nothing, the window is the instant of one write, and serializing removal with local writes needs a gate across two actors. |
| 5 (Low) | `VoteNoteService.set` trusted any `ArchivedFeedback`. | **Fixed with finding 1:** the vote must be in the named snapshot of the index. |
| 6 (Low) | The notes query silently skipped a stored choice it did not know. | **Fixed.** It throws `unreadableVoteNote`, so the app shows the notes as unavailable rather than as "no note". New test `anUnknownStoredChoiceIsReported`. |
| 7 (Low) | The decoder ignored `payload_representation` and `transformations`. | **Fixed.** Anything but `local_control_json` with no transformations is `local_control_unrecognized`. New test `anotherRepresentationOrATransformationIsNotReadAsANote`. |
| 8 (Low) | An ID-shaped `type` could be repeated in a warning. | **Fixed.** Type and key names are repeated only if they are lowercase letters, `_` and `.`; a UUID or a name with digits shows as `?`. The unrecognized-record test adds both. |

Test gaps it named, and what was done:

- exports, Insights and filters unchanged by a note: **added** `aNoteChangesNoExportInsightOrFilter`
  (all four export formats byte-identical, Insights and history facets equal);
- reprojection on a version change, unknown stored choice, representation: **added** (above);
- maintenance starting during a suspended write, removal racing a write, a failed flush: **not
  added**, recorded as untested in the milestone doc;
- the pinned digest is a regression pin, not a replay with the old code. The author computed it by
  running the test at `544194b` before any change, recorded in the milestone doc;
- model-level (App) tests: the app target has no test target. The fix for finding 1 is enforced in
  the service, which is tested.

## Re-review of the fix pass

- **Reviewer saw the real diff:** yes, with the two milestone docs.
- **Reviewer ran tests:**
  - ArenaProtocol `--filter "VoteNote|Maintenance|Backup|Export|Insights"`: 83 passed;
  - all of ArenaSuiteCore: 125 passed.
  - The boundary script was again denied to it; the author ran it.
- **Verdict:** "ready for this milestone". It found all eight earlier findings properly addressed,
  including the case of two accounts with identical IDs (the index key includes the account;
  `theNoteGoesToTheAccountPassedIn` uses identical IDs in both accounts). It confirmed that the
  conditional `local_control_version` keeps the digest of archives without local records, is the
  same for incremental projection, limited replay and rebuild, and can't loop.

| # | Finding | Outcome |
|---|---|---|
| L1 | A successful note left an earlier "not saved" banner on screen. | **Fixed.** A saved note clears the banner if it is still the last note failure; other messages are left alone. |
| L2 | The menu's help blamed an unreadable index for any unreadable notes, including a stored choice this build doesn't know. | **Fixed.** The model keeps why notes are unavailable; the help says "a note … has a value this version of the app cannot read. It is still in the archive" or that the index could not be read. Checked in the app with an unknown stored choice: the menu is off and no note is claimed. |
| L3 | `notesEnterTheDigestOnlyWhileThereAreAny` claimed more than production does: once a local record was projected, `meta.local_control_version` stays after the last note is removed. | **Renamed** to `anEmptyNotesTableIsLeftOutOfTheDigest`, with a comment stating that; the doc's claim (archives that never had a local record keep their digest) was already the narrower one. |
| L4 | A failed flush leaves the account's writer failed until the app is reopened, which also stops that account's syncs. Pre-existing writer behaviour, now reachable from a note. | **Message fixed** (it says to quit and reopen the app). Reopening a failed writer in `JournalStore` is recorded as a follow-up. |
| L5 | The index check and the backup manifest name only the Arena decoder's version. | **Follow-up** (changing the manifest is its own decision); recorded in the milestone doc. |
| L6 | A note written beside a vote in an older snapshot is not visible from the latest snapshot if that vote is gone. | **Documented** under "Not in this milestone". |

## Author checks after the fixes

- Each fix reverted on its own makes its test fail: the vote-in-transcript check, the local
  version check, the representation check, the narrower warning names, reporting an unknown
  choice, and again the account-in-the-app check.
- Suites: core 125, adapter 169, MCP 17, all passing. `Scripts/check-boundaries.py` passes (the MCP
  deny-list now names notes and `local.control`, with self-tests). The Debug app builds.
- In the app, on a synthetic archive copy:
  - setting "Tie" through the transcript-bound path shows "Your local note: Tie";
  - the index records `local-control/1`.
