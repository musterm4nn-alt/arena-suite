# Local vote notes (2026-10-20)

A note beside a vote that Arena recorded, saying what you think now: "A is better", "B is better",
"Tie" or "Both are bad". It stays in this archive and is **never sent to Arena**.

This is item 6 of the gap list (`Docs/arena-exporter-gaps-2026-10-19.md`). arena-exporter lets you
set a manual vote (A, B, both good, neither good, or clear). Arena Suite treats Arena's recorded vote
as evidence and its meaning as an assumption (ledger N-016), so it never changes that vote. The note
sits beside it.

The note is not a vote. Plan v3 §1 limits voting to Track B, by an explicit click on a battle just run
in the app. Nothing here sends anything, and nothing can be scripted: no MCP tool reads or writes a
note.

## What a note is

- It belongs to a **recorded vote that names its two messages** (`messageAId`, `messageBId`). It is
  keyed by the account, the conversation and that message pair, not by the vote's ID, so the note
  stays put if Arena re-issues the vote. A vote without both message IDs gets no note.
- Its choices use the vote's own frame: A is the vote's `messageA`, B its `messageB`. In the app the
  letters are those messages' lanes as the transcript shows them; when a lane isn't exposed, the
  vote's own A and B are used.
- The choices are prefer A, prefer B, tie, both bad (`VoteOutcome`), or none (the note is removed).
- The latest note for a pair wins. Every earlier one stays in the journal.
- Nothing is pre-selected: a vote starts with no note, and the menu never proposes one from Arena's
  vote, the models or anything else.

## The record (journal format)

A note is a `local.control` record (plan v3 §7: "local user state that must survive an index
rebuild") in the conversation's account journal:

- envelope: `kind` `local.control`, `account_id` the conversation's account, `job_id` null,
  `payload_representation` `local_control_json`, no transformations, empty metadata;
- payload: UTF-8 JSON with sorted keys, for example

  ```json
  {"choice":"prefer_b","conversation_id":"c1","format":"arena-suite.local-control","message_a":"a1","message_b":"b1","origin":"ui","type":"vote_note","version":1,"vote_id":"f1"}
  ```

  - `choice` is `prefer_a`, `prefer_b`, `tie`, `both_bad`, or `null` to remove the note.
  - `vote_id` names the recorded vote it was written beside (provenance, not part of the key).
  - `origin` is always `ui`.

## Acceptance criteria

1. **Record before interpret.** Setting or removing a note appends one `local.control` record and
   flushes it (`synchronize`) before the app reports success. Only then is the account projected.
   If the append succeeds but the flush fails, the app says the note may not survive a restart
   (`appendedButNotFlushed`), not that nothing was saved. The record holds IDs and the choice only:
   no message text, titles or model names.
2. **App-owned decoding.** `LocalControl` (ApplicationActions) decodes `local.control` records;
   ArchiveService uses it for that kind and the Arena decoder for the rest. ArenaAdapter knows
   nothing of notes. A `local.control` record whose payload representation, transformations,
   format, type or version this app doesn't know becomes a `local_control_unrecognized` warning. A
   known type with a body that isn't as specified becomes `local_control_malformed`. Neither is
   dropped silently, and the journal keeps the bytes. The warning detail is bounded and holds no IDs:
   a type or key name is repeated only if it is lowercase letters, `_` and `.`.
3. **Projection.** Migration `v2` adds a `vote_notes` table (account, conversation, message A,
   message B, choice, vote ID, record sequence, noted-at time from the envelope). `reset()` drops and
   recreates it like the others. Replays are idempotent; latest wins; `null` deletes. Once a local
   record is projected, the index stores the local decoder's version (`meta.local_control_version`,
   `local-control/1`). A different stored version rebuilds the index like an Arena decoder change
   (plan v3 §10), so records an earlier local decoder could not read are projected again. It is
   stored only then, so an archive without local records keeps its digest (criterion 4). A stored
   choice this build doesn't know is reported (`unreadableVoteNote`, the note menus turn off), never
   skipped as if there were no note.
4. **Older backups still check.** A table added after the first schema enters the content digest
   only when it holds rows. An archive without notes keeps the exact digest it had before this
   change: a test pins a fixed archive's digest computed with commit 544194b. Backups made before this
   change therefore still pass "Check backup". An archive with notes gets a digest that covers them.
5. **Survives rebuild, backup and restore.** A note is in the journal, so rebuild, backup check,
   restore and encrypted backup bring it back. The index check (live against replay) matches with
   notes present. Tests cover rebuild and backup round trips.
6. **Writes are gated.** `HistorySyncService.appendLocal` writes through the account's shared
   journal writer. It is refused (`busy`) while maintenance (verify, backup, restore, rebuild) runs.
   A write in progress also holds maintenance off, because it is reserved before its first
   suspension. A sync of the same account may run alongside: the writer serializes appends, and job
   tracking ignores records without a job ID. Notes are refused for an account that is not in the app
   (a removed account's journal is kept as evidence, not extended). Known limit: removing an account
   at the very moment its note is being written isn't serialized with the write, so that one note can
   still land in the removed account's kept journal. Removal deletes nothing, so nothing is lost.
7. **Account context.** The note goes to the account and conversation of the transcript the vote
   was shown in, taken from that transcript when you click, never from the selection (which may
   already name another conversation that is still loading). `VoteNoteService.set` also requires the
   vote, exactly as recorded, to be in that snapshot of that account's conversation in the index.
   Otherwise it refuses (`voteNotInConversation`), so no note can land in another account or
   conversation.
8. **Never sent, never automated.** The note service has no transport. MCP has no tool for notes, and
   `Scripts/check-boundaries.py` forbids the MCP sources from naming them or `local.control`.
   Insights, filters and exports count Arena's recorded votes only, as before.
9. **In the app.** Beside each recorded vote in a turn there is a "Note" menu: "A is better", "B is
   better", "Tie", "Both are bad" and, when a note exists, "Remove note". When a note is set, the
   vote line shows it, labelled as a local note. The help and accessibility text say it is never
   sent to Arena. A refused write shows why, and the open conversation is not left showing a note
   that wasn't saved.

## Not in this milestone

- Notes in exports, Insights and history filters. They show Arena's votes only and say so; adding
  notes there is a separate decision.
- Notes on turns without a recorded vote, and on votes not tied to a single turn.
- A history of a pair's notes in the app (the journal keeps it; the evidence inspector doesn't show
  local records yet).
- A note written beside a vote in an older snapshot shows only there: if the latest snapshot no
  longer has that vote, the latest view shows neither the note nor its menu. The note stays in the
  index and the journal.
- Follow-ups from the re-review:
  - name the local decoder's version in the index check and the backup manifest (provenance);
  - let `JournalStore` reopen a writer that failed, so one failed flush doesn't stop that
    account's syncs and notes until the app is reopened. The message says to reopen it for now.
    This is pre-existing writer behaviour, now also reachable from a note.

## Results (2026-10-20)

- **Tests:**
  - `Packages/ArenaProtocol/Tests/AdapterTests/VoteNoteTests.swift` (18):
    - the exact record and flush;
    - latest wins, and removal;
    - the account passed in;
    - rebuild and index check;
    - backup check and restore;
    - the maintenance gate;
    - an account not in the app;
    - only local records through `appendLocal`;
    - a vote without two messages;
    - a write while that account syncs (job still ends cleanly, no unterminated job);
    - unrecognized and malformed records (warnings, no IDs in details, bytes kept);
    - a record for another account;
    - extra keys counted;
    - after the first review: a vote shown in one transcript cannot be noted under another account,
      conversation or snapshot, nor an altered vote; a different stored local version rebuilds the
      index and the note reappears; another payload representation or a transformation is not read
      as a note; exports (all four formats), Insights and history facets are unchanged by a note.
  - `Packages/ArenaSuiteCore/Tests/ArchiveIndexTests/VoteNoteIndexTests.swift` (6):
    - the pinned digest of a fixed archive without notes, before and after `reset()`;
    - an empty notes table left out of the digest;
    - keys;
    - upgrading an index that only had migration v1. Read-only openers refuse it until the app
      has migrated it;
    - an unknown stored choice is reported (the note menus turn off and say why: a note this
      version can't read, as opposed to an index that can't be read).
- **Checked by reverting each guard; the named tests then fail:**
  - always hashing the notes table: the three pinned-digest tests;
  - the maintenance gate;
  - routing `local.control` to the app's decoder;
  - the account-in-the-app check;
  - the flush;
  - the envelope-account check;
  - after the first review: the vote-in-transcript check; the local version check; the
    representation check; the narrower warning names; reporting an unknown stored choice.
- **Untested:**
  - maintenance starting while a note write is suspended (the reservation is taken before the first
    suspension; the test doesn't drive that interleaving);
  - a failed flush after a successful append (the store opens its own writers, so there is no seam
    to inject the failure);
  - account removal racing a write (known limit, criterion 6).
- **Suites and checks:** core 125 tests; adapter 169, including these; MCP 17;
  `Scripts/check-boundaries.py`; Debug build.
- **In the app, on a synthetic archive copy (never the real archive):**
  - choosing "B is better" shows "Your local note: B is better" beside the vote;
  - the journal gained one `local.control` record;
  - the note survived a relaunch;
  - the menu checks the current choice;
  - "Remove Note" removed it, with a second record whose choice is `null`;
  - for an account not in the app, the sidebar says "The note was not saved: this conversation's
    account is no longer in the app", and nothing was written;
  - after the review fixes, setting "Tie" through the new transcript-bound path works, and the index
    records `local-control/1`.
- **Review:** `Docs/reviews/2026-10-20-vote-notes.md`.
