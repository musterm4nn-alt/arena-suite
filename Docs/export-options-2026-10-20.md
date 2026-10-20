# Export options (2026-10-20)

Three export options that arena-exporter has and Arena Suite lacked:

- a **"Last answer, with its prompt"** scope;
- **copy to the clipboard**;
- **JSONL** for one conversation.

This is item 8 of the user's gap analysis (`Docs/arena-exporter-gaps-2026-10-19.md`). That analysis
lists it first under "Closing the gaps", as local work on data the archive already has.

Plan v3 §12 names three formats (Raw JSON, Normalized JSON, Markdown). JSONL and the scope extend it
at the user's request. Nothing else in §12 changes:

- exports read one frozen snapshot;
- files are written to a staging file and then linked into place, never overwriting anything;
- the same input gives the same bytes;
- telemetry stays masked by default.

Nothing is sent to Arena. The MCP server is unchanged: it names its formats explicitly, so it
offers neither JSONL nor the scope.

## What each option means (named in the app)

- **Last answer, with its prompt.**
  - **Basis:** the messages Arena lists as the conversation's last in that snapshot (the recorded
    `lastMessageIds`), plus the `user` messages they reply to.
  - **Votes:** only those whose referenced messages are all in that set.
  - **Claims:**
    - those about those messages or votes;
    - claims about the whole conversation (such as revealed names);
    - claims whose subject kind this version does not know. These are kept rather than guessed
      about.
  - **Order and naming:** messages keep the snapshot's order and their ordinal in the whole
    snapshot. The export says how it was chosen:
    - Normalized JSON and JSONL carry a `selection` object with the basis for messages, votes,
      claims and ordinals, Arena's list as recorded, `parents_not_in_snapshot` and
      `parents_with_unknown_role`.
    - Markdown has a line under the title and does not number the turns.
  - **A reply whose parent is missing or has no role.** A listed message may reply to a message
    whose role is unknown: either the snapshot does not hold it, or it holds it with no stated role.
    The export does not include it and does not guess whether it is a prompt. It names the ID in
    `parents_not_in_snapshot` or `parents_with_unknown_role`, and in a Markdown line. Such a parent
    is never dropped silently. A parent with a stated role other than `user` is not a prompt and is
    not included.
  - **Nothing is inferred.** Each case is refused with its own reason:
    - Arena's list is empty, or was not in the response (`noLastAnswer`);
    - the list names a message the snapshot does not hold (`lastMessageNotInSnapshot`);
    - the index cannot read the stored list (`lastMessagesUnreadable`). Rebuilding the index
      restores it from the journal.
  - **A prompt with no answer:** where Arena lists the prompt itself as last (seen for flagged
    prompts that got no answer), the last answer is that prompt alone.
  - **Not for Raw JSON:** Raw JSON is one recorded response body, so it is always the whole
    conversation. The app says so and disables the buttons.
- **JSONL** (`.jsonl`). One canonical JSON object per line: sorted keys, no line break inside a
  record.
  - U+0085, U+2028 and U+2029 are written as `\u` escapes. Some line readers end a line at them;
    the parsed value is unchanged.
  - The lines are:
    - a `header` with `schema: arena-suite.jsonl/1` and Normalized JSON's `scope`, `conversation`,
      `excluded` and, for a last answer, `selection`;
    - one `message` line per message, in snapshot order;
    - one `model_claim` line and one `feedback` line per item, in Normalized JSON's order;
    - a `footer` with the counts.

  Each record equals the corresponding Normalized JSON entity.
- **Copy.** Renders the chosen format and scope to the clipboard. No file is written.
  - Exact raw bodies are never offered on the clipboard; they stay a separately confirmed file
    export.
  - A notice says what was copied and its size, but only if the clipboard accepted it.
  - If it did not, the clipboard gets back the plain text it held, and the notice says whether it
    did. Other kinds of content are not kept.
- **The notice** shows the outcome of the latest save or copy: what was written, what was copied,
  or why nothing was.
  - Each attempt replaces it.
  - Changing the conversation or snapshot shown clears it. That includes a sync that brings a new
    latest snapshot while Latest is shown.
  - An attempt that finishes after the conversation or snapshot shown has changed copies nothing
    and shows no refusal. The exception is a written file: its notice is still shown, because it
    gives the file name. That name holds the title (up to 60 characters), the first 8 characters
    of the conversation ID and the snapshot (`r<sequence>`).
  - Exporting is offered only while the conversation and snapshot shown are the ones chosen, not
    while a chosen snapshot, or Latest, is still loading. A second attempt while one runs is
    ignored; the controls are disabled meanwhile.

## Evidence for the basis (2026-10-20, live index, counts only)

- 54 latest snapshots, all with a recorded `lastMessageIds` (49 with two IDs, 5 with one).
- Every listed ID is a message of the same snapshot.
- In 52 snapshots the listed IDs are exactly the responses after the last prompt.
- In the other 2, Arena lists the last prompt itself (status `flagged`), which has no response.
- No response after the last prompt is ever left out of the list.

## Acceptance criteria

1. **Index:** `ConversationDetail.lastMessageIDs` holds the recorded `lastMessageIds` of the shown
   snapshot. A frozen snapshot keeps its own list.
2. **Export service** (`ExportService`, ApplicationActions):
   - `ExportFormat.jsonl` and `ExportScope.lastAnswer`, with `ExportService.lastAnswer(of:)` pure
     and tested;
   - the last-answer refusals (`noLastAnswer`, `lastMessageNotInSnapshot`,
     `lastMessagesUnreadable`, `scopeNotAvailable`) write nothing;
   - last-answer files are named `… last answer.<ext>`;
   - whole-conversation exports are byte-identical to before this change.
3. **App:** the Export button (⇧⌘E) opens a popover:
   - a scope, a format with a one-line description, and Copy, Save to Downloads and Save to
     Folder…;
   - the exact-raw-bodies export, still behind its confirmation;
   - the chosen scope and format are remembered between launches;
   - copying shows a notice; refusals show their reason.
4. **Checks:**
   - tests for the scope, JSONL, the refusals and determinism, plus the existing export tests,
     which now also run for JSONL;
   - `Scripts/test-offline.sh` and the boundary check;
   - the Debug build checked on the synthetic archive;
   - a second-model review.

## What was built

- **Index:** `ArchiveIndex.conversation` reads `snapshots.last_message_ids` (already stored)
  into `ConversationDetail.lastMessageIDs`. That field is nil when the stored value is NULL or not
  a JSON array of strings.
- **ApplicationActions:**
  - `ExportFormat.jsonl` (`supportsLastAnswer`), `ExportScope`, `ExportOptions.scope`;
  - `ExportError.noLastAnswer`, `.lastMessageNotInSnapshot`, `.lastMessagesUnreadable` and
    `.scopeNotAvailable`;
  - `ExportService.lastAnswer(of:)`, which returns a `LastAnswer`: the excerpt, its snapshot
    ordinals, Arena's list, the parents not in the snapshot and the parents with no stated role;
  - `normalizedParts`, shared by Normalized JSON and JSONL;
  - `jsonl(detail:evidence:lastAnswer:)` and `lineSafe`.
- **App:**
  - `ExportPopover` in `ArchivePane.swift`, which replaces the Export menu;
  - `ArchiveModel.copy(_:scope:with:)`, which renders, hands the text to the pasteboard writer and
    records the outcome;
  - `ArchiveModel.exportOutcome` (saved, copied or refused), which replaces `lastExport`;
  - `canExport`, `stillShown`, and readable refusal messages;
  - Debug flag `--preview-export-popover` (with `--preview-conversation`). The scope and format
    can be preset with `-exportScope last-answer -exportFormat jsonl`.

## Results (2026-10-20)

- **Tests:**
  - `ExportOptionsTests` has 13 new test functions (15 cases).
  - The existing determinism, frozen-snapshot and wrong-snapshot export tests now also cover
    JSONL.
  - All 28 export tests pass.
- **Before/after:** `wholeConversationExportsAreUnchanged` pins whole-conversation Normalized JSON
  and Markdown. It masks the record digest and the account ID, then compares SHA-256 hashes taken
  from `HEAD` (`6da813d`) on the same fixture, in a temporary checkout; two runs there gave the same
  hashes. Raw JSON is unchanged in code (`rawJSON` is not touched). Its output carries the record's
  own ID, capture time and digest, which differ on every run.
- **Fixes fail when reverted:** these tests fail when their fix is reverted:
  - escaping: the JSONL test;
  - ordinals: the last-answer test;
  - the missing-parent list: the missing-prompt test;
  - the unknown-role list: the unknown-role test.
- **Debug build, synthetic archive:**
  - the popover shows the scope, the format, the description, and the exact-raw link, relabelled
    for the whole conversation;
  - with a damaged list (a last message not in the snapshot), Copy left the clipboard unchanged.
    The notice gave the reason and replaced the earlier "Exported…" notice;
  - selecting another conversation cleared that notice;
  - "Last answer" with JSONL then copied 12 lines (header, 3 messages, 6 claims, 1 vote, footer),
    and the notice read "Copied the last answer as JSONL · 4,110 bytes";
  - after the second fix pass, a Markdown last answer still copied, with the notice "Copied the
    last answer as Markdown · 659 bytes";
  - not exercised by hand: a sync replacing the shown snapshot, and an attempt finishing after a
    switch. Both are build-checked only; the app has no test target.
  - Raw JSON with "Last answer" shows the reason in orange and disables the buttons.
- **Review:** `Docs/reviews/2026-10-20-export-options.md`.
