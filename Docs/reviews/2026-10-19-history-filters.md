# Review — History filters (2026-10-19)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5).
- **Scope:** the uncommitted history-filters milestone against `f441969` (Insights). Acceptance
  criteria: `Docs/history-filters-2026-10-19.md`.
- **Runs:** the milestone, then a re-review of the first fix pass. A third run, to check the second
  fix pass, did not complete (below).
- **Reviewer saw the real diff:** yes, in every run. It read `git diff HEAD` and every new file in
  full.
- **Reviewer ran tests:**
  - The filter and Insights tests in ArenaSuiteCore (first run 15 passed, second run 19 passed);
    the whole ArenaSuiteCore suite (118 passed in the second run); ArenaSuiteMCP (17 passed).
  - `swift test --filter Insights` in ArenaProtocol (2 passed). The real-archive test was skipped:
    its runs had no archive path. The author ran it (below).
  - A Debug `xcodebuild` of the app into a temporary folder. It succeeded with no Swift warnings.
  - Its permissions refused `bash Scripts/…` and `python3`, so it checked the import boundaries by
    hand against `Scripts/check-boundaries.py`. The author ran both scripts (below).
- **Verdicts:**
  - First run: "ready for this milestone", with findings 1 and 2 to fix before committing and 3–5
    in the same pass. All nine are fixed.
  - Second run: all nine fixes confirmed. Still "ready for this milestone", with its findings 1 and
    2 to fix or defer before calling the work done, and the missing review record to be written.
    Both are fixed and this record is written.
  - Third run: none. The first attempt hung during startup (about 2 s of CPU time and no connection
    in 10 minutes) and was stopped; a short prompt then got an answer. The rerun was stopped
    unfinished when the user ended the session's work. The second fix pass (the six findings below)
    is checked by the author's tests and the Debug build only, not by a second model.

## First run: findings and what was done

| # | Finding | Outcome |
|---|---|---|
| 1 (Medium) | "Without a vote" also matched conversations known only from the history list. Their votes are unknown, not none. | **Fixed.** "No vote in its transcript" needs a snapshot whose latest holds no vote. List-only conversations match neither vote choice, and the menu counts them on their own line. On the real archive that is 6 of 60, all previously counted as "without". `eachDimensionNarrowsAloneAndTogether` and `optionsCountEachChoiceInTheList` fail without the fix. |
| 2 (Medium) | If the facets could not be read, the filters ran on empty facets and showed a confidently wrong list. | **Fixed.** Unreadable facets are `nil`: the vote and model filters are then off, their menus disabled, and the filter bar says so in orange. A conversation missing from facets that were read (a sync between the two reads) matches no vote or model choice. New test `unreadableOrMissingFacetsAreNotGuessed`. |
| 3 (Low) | Search could read "0+ matches", and never named its 1,000-hit window. | **Fixed.** `SearchSummary` (ApplicationActions) writes the lines: matches shown; matches hidden by the history filters (with no "0 matches" line when all are hidden); and, when the search stopped at 1,000 hits, that the counts cover only those. New test `searchSummaryNamesWhatItCounted`. |
| 4 (Low) | The Updated menu did not name what it measures. | **Fixed.** The picker's title is `HistoryFilter.periodScope`: "Last update as Arena reports it, in this Mac's time zone (a day is 24 hours)". The chip's help says the same. |
| 5 (Low) | `undated` was computed but never shown; the relative periods had no counts. | **Fixed.** `HistoryFilterOptions.recent` counts each relative period at the given time, and the Updated menu shows the undated count. |
| 6 (Low) | Mode order was not deterministic for `nil` and `""`; an empty mode showed as a blank line. | **Fixed.** `HistoryFilter.modeOrder` (count, then "not stated", then value) is shared with Insights. `HistoryFilter.label(mode:)` shows an empty mode as `“” (empty)`. New test `modeLabelsAndOrderAreStable`. |
| 7 (Low) | The doc said votes were matched by sequence and conversation ID; they are matched by sequence alone. | **Fixed.** The doc and the code comment say so and why it is sound: `snapshots` is keyed by (account, sequence) and written with a plain INSERT, so a record holds at most one snapshot. New test `aRecordHoldsAtMostOneSnapshotSoVotesMatchBySequence`. |
| 8 (Low) | Revealed names are shared across accounts by model ID without a ledger entry. | **Fixed.** Protocol ledger N-017: on the real index, 18 of 65 claimed model IDs appear in more than one account. No ID has two revealed names. That IDs are Arena-global is marked as an assumption. |
| 9 (Low) | A filter change left a hidden conversation open; Insights' links did not end a search. | **Fixed.** A filter change closes a selection it hides (checked by hand in the Debug build). `MainView.showHistory`, passed to Insights, closes the search, sets the filter, deselects and shows the archive. |

Test gaps raised: the facet-missing rule (now tested), the tautological sum in the real-archive test
(replaced: list-only conversations equal those without a snapshot; with and without a vote add up to
those with one), labels outside the view (now in ApplicationActions and tested), and two snapshots in
one record (now tested). Not covered: the app has no test target, so `visibleHits`, keyboard
navigation, deselection and the Insights links are build-checked and exercised by hand only.

## Second run: findings and what was done

| # | Finding | Outcome |
|---|---|---|
| 1 (Medium) | Menu counts were taken over the whole list, so with another filter on, a count was not what choosing it showed. | **Fixed.** `HistoryFilterOptions.build` takes the active filter and counts each dimension under the other active ones (a mode: choosing it alone). The app recounts on every filter change. New test `menuCountsAreWhatChoosingShowsUnderTheOtherFilters`, which fails when counts are taken over the whole list. |
| 2 (Medium) | An Insights model row counts votes, but clicking it shows conversations. | **Fixed by wording.** The row's help says the numbers count votes and the click shows conversations with a vote whose latest snapshot claims the model, and that one conversation can hold several votes. The doc says the same. |
| 3 (Low) | The doc cited this review record before it existed. | **Fixed.** This file. |
| 4 (Low) | `label(mode:)` read the same for no mode and a mode recorded as "not stated"; Insights keyed bars by label. | **Fixed.** Such a recorded value is quoted (`“not stated” (recorded)`), and Insights' bars take an explicit ID keyed by the raw mode. Assertion added. |
| 5 (Low) | The vote facet counts every `feedback` row, which assumes they are all pairwise votes. | **Documented, not changed.** The decoder projects only `pairwiseFeedbacks` into `feedback` (`ArchivedFeedback` has no other producer), and Insights counts the same rows. The comment on `historyFacetSource` says so. |
| 6 (Low) | Rows with an unparseable account ID drop out of the facets silently. | **Not changed.** `ArchiveIndex.conversations` drops the same rows, so the list and the facets agree; such a conversation is in neither. |

## Unverified assumptions

- Model IDs are Arena-global (N-017, an assumption backed by counts).
- The list and the facets are two reads. A sync between them is covered by the missing-facet rule.
- What Arena's `updatedAt` denotes is not established; the menu says "as Arena reports it".

## Checks run by the author after the fixes

- `swift test --package-path Packages/ArenaSuiteCore --filter "HistoryFilter|…|Insights"`: 20 passed.
- The tests for first-run finding 1 and second-run finding 1 fail when their fix is reverted.
- The real-archive test, counts only: 25 with a vote, 29 with no vote in their transcript, 6 known
  only from the list (60 in all); 65 claimed models.
- `bash Scripts/build.sh Debug`: no warnings. Checked in the Debug build against a synthetic archive
  (see the milestone doc's Results).
- `bash Scripts/test-offline.sh`: exit 0.
- `python3 Scripts/check-boundaries.py`: passed.
