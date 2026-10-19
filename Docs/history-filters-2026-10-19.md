# History filters (2026-10-19)

Filters for the sidebar's history and for search: by mode, by whether the conversation has a vote,
by a claimed model and by when it was last updated. Plan v3 §11 asks for "account/mode/date
filters" on search; the account filter exists (the account switcher), mode and date do not. The
vote and model filters follow from the Insights page, which can open the history filtered to what a
bar or a model row counts.

The user asked on 2026-10-19 to "design, develop, implement new features and improvements". This
is the second such feature, after Insights (`Docs/insights-2026-10-19.md`).

It reads the index only. It sends nothing to Arena and writes nothing.

## What each filter means (named in the app)

- **Mode:** the conversation's recorded mode; "not stated" when it has none. Several modes can be
  chosen; a conversation matches any of them. A recorded empty mode is shown as `“” (empty)`, never
  as a blank line or as "not stated".
- **Votes** (votes between two responses, latest snapshot):
  - "With a vote": the latest snapshot holds at least one.
  - "No vote in its transcript": the conversation has a snapshot, and its latest holds none.
  - A conversation known only from the history list has no transcript, so whether it has a vote is
    not in the archive. It matches neither choice; the menu counts these on their own line.
- **Model:** a model ID that the latest snapshot claims, from any source (the message's own
  `modelId`, the vote's model claims, the revealed set). The menu shows the revealed name where there
  is one. This is "claimed", never verified identity.
- **Updated:** the time Arena reports for the conversation's last update, read in this Mac's
  calendar and time zone; the menu says so. Past 7 and past 30 days are periods of 24 hours; past
  12 months and a year are calendar periods. Each choice shows its count. Conversations without a
  parsable update time match only "any time"; the menu counts them.
- **When the facets cannot be read:** the vote and model filters are off, their menus are disabled,
  and the filter bar says so. They are never guessed from an empty read. A conversation missing from
  facets that were read (a sync landed between the list read and the facet read) matches no vote or
  model choice.
- Filters combine with each other and with the account switcher: a conversation is shown when it
  matches all of them.
- **Counts in the menu:** each dimension is counted under the other active filters, so a count is
  what choosing that option shows. For a mode it is choosing that mode alone; several chosen modes
  show their sum.
- A recorded mode that would read like a placeholder is quoted: an empty one as `“” (empty)`, one
  literally recorded as "not stated" as `“not stated” (recorded)`.

## Acceptance criteria

1. **One read.** `ArchiveIndex.historyFacetSource(account:)` reads, in one read transaction, each
   conversation's vote count and claimed model IDs from its latest snapshot, and the revealed names.
   Claims are matched by sequence and conversation ID. Votes are matched by sequence alone (the
   `feedback` table has no conversation column), which is sound because a record holds at most one
   snapshot: `snapshots` is keyed by (account, sequence) and written with a plain INSERT. A test
   holds this. The list is a separate read; the "missing facet" rule covers a sync between them.
2. **Pure filtering.** `HistoryFilter` lives in ApplicationActions. Applying it is deterministic for
   a given clock and calendar. Tests cover:
   - each dimension alone and combined;
   - "not stated" modes;
   - list-only conversations (no snapshot), which match neither vote choice;
   - facets that could not be read, and a conversation missing from them;
   - undated conversations;
   - period edges in a fixed time zone;
   - a model claimed only in an earlier snapshot does not match.
3. **Search follows the filters.** Hits are limited to conversations the filters show. The summary
   names what it counted: matches shown, matches hidden by the filters, and, when the search stopped
   at the index's 1,000-hit cap, that the counts cover only those hits.
4. **The app.**
   - A filter control above the history in the sidebar offers the four filters, with counts taken
     under the other active filters.
   - Active filters show as removable chips and a "shown of total" count.
   - Clearing restores the full history.
   - Selecting a conversation and keyboard navigation work within the filtered list. A selected
     conversation that a new filter hides is closed.
   - The Insights page's mode bars and model rows open the history filtered to them, closing any
     search.
   - Filters reset to none at launch; they are not saved.
5. **Checks.**
   - `Scripts/test-offline.sh` and the boundary check pass.
   - The Debug app builds without warnings and is checked against a synthetic archive.
   - A second model reviews the change.

## What was built

- **Index:** `ArchiveIndex.historyFacetSource(account:)`. One read: per conversation, the vote count
  and the claimed model IDs of its latest snapshot (matched by sequence and conversation ID), and
  every named claim. The claim-row mapping is shared with `insightsSource`.
- **ApplicationActions:**
  - `HistoryFilter`: modes, votes, model, period; `matches` and `apply` are pure. It also holds the
    labels the app shows (`Votes.label`, `Period.label`, `label(mode:)`, `periodScope`) and the mode
    order (count, then "not stated", then value) that Insights shares.
  - `HistoryFacets`: per-conversation facets and the revealed names.
  - `HistoryFilterOptions`: the menu's choices, with counts under the active filter, including the
    relative periods, the list-only conversations and the undated ones. The app recounts on every
    filter change and reload.
  - `SearchSummary`: the lines above search results.
  - `RevealedNames`: the latest revealed name per model ID, now shared with Insights.
  - `ArchiveService.historyFacets(account:)`.
- **App:**
  - `ArchiveModel.filter`, `visibleConversations`, `visibleHits` and `filterOptions`. The facets
    are read with the list on every reload.
  - The sidebar's `HistoryFilterBar`: a filter menu, chips that remove one filter each, "N of M
    shown" and Clear. It is shown above the history, and above search results while a filter is
    on. `FlowLayout` wraps the chips.
  - The history list, keyboard navigation and search use the filtered list. "No conversations
    match the filters" offers Clear Filters.
  - Search reads up to the index's cap of 1,000 hits, so the filters apply to more than the 200 it
    shows. `SearchSummary` says how many matches the filters hid and when the search stopped at
    its cap.
  - Insights: a mode bar opens the history filtered to that mode; a model row opens it filtered
    to conversations with a vote whose latest snapshot claims that model. The row's numbers count
    votes and the list shows conversations, so they can differ (one conversation can hold several
    votes); the row's help says so.
  - Debug flag `--preview-filter "<mode>"`.
- "Not stated" stays `nil` end to end: Insights' mode tallies are now `ModeTally(mode: String?)`, so
  a recorded mode literally named "not stated" could never be confused with a missing one.

## Results (2026-10-19)

- **Tests:** 10 new tests in `HistoryFilterTests`. The real-archive test now also checks the
  filters.
- **Real archive** (counts only):
  - 4 modes; 25 conversations with a vote, 29 with no vote in their transcript, and 6 known only
    from the list (60 in all); 65 claimed models; one year; none undated.
  - The 6 list-only conversations are exactly the conversations without a snapshot, and every
    conversation with a snapshot has readable facets.
  - Every model with an Insights record can be filtered to.
  - "With a vote" and "No vote in its transcript" show exactly their counts.
  - 18 of the 65 model IDs are claimed in more than one account, with no conflicting revealed
    names (protocol ledger N-017).
- **Debug build, synthetic archive:**
  - A mode and vote filter shows 55 of 120, with chips.
  - The menu shows modes, votes, model and updated choices with counts.
  - Clicking a model row in Insights shows its 30 conversations, matching its 30 votes.
  - With a filter on, search shows "165 matches" and "195 more hidden by the history filters".
  - The Updated menu names its scope and counts each period.
  - With "battle" and "With a vote" on, the menu reads battle (55) and With a vote (55), matching
    "55 of 120 shown".
  - Clicking a mode bar in Insights while searching closes the search and shows that mode's 29.
  - A selected conversation is closed when a new filter hides it, and kept when it stays shown.

## Review

A second model reviewed the milestone and then the first fix pass. A check of the second fix pass
did not complete. The findings and what was done about each are in
`Docs/reviews/2026-10-19-history-filters.md`.
