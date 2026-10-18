# Review — sidebar rail (2026-10-18)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5).
- **Scope:** the uncommitted change against `7d8dafc`:
  - `App/MainView.swift`: the explicit layout replacing `NavigationSplitView`, `SidebarRail`,
    `SidebarToggle`, `openSite(_:)` and the toolbar-placed search field;
  - the status, handoff and milestone docs.

  Acceptance criteria: `Docs/arena-window-2026-10-18.md`, "Third iteration".
- **Reviewer saw the real diff:** yes. It ran `git diff HEAD` on the app file and the docs.
- **Reviewer ran tests:** partly. `swift test --package-path Packages/ArenaSuiteCore` passed
  91/91. It could not compile the app target (package resolution needs the network in its sandbox),
  and its sandbox denied the boundary script. The author ran those commands (below).
- **Verdict:** "not ready for this milestone". The review found the state logic, the boundary rules
  and ADR 0006 compliance sound. It asked for:
  - two placements to be verified (F1, F2);
  - the rail's missing sync and error surface (F3);
  - a status correction (F5).

  All four are closed below.

## Findings and fixes

| # | Finding | Fix |
|---|---|---|
| F1 (High, conditional) | The search field moved to a `.toolbar` placement without a split view; it might not render. | **Observed.** Debug build, real archive: the "Search archive" field shows at the right of the toolbar, beside the rail and the full sidebar. |
| F2 (High, conditional) | The site's `.navigation` toolbar group, title and subtitle were unverified outside a navigation container. | **Observed, without loading the site.** A standalone SwiftUI app with the same structure (an `HStack` of a 64 pt column, a border and the content; the site content carrying the same `.navigation` and `.primaryAction` groups, `navigationTitle` and `navigationSubtitle`) shows Back, Forward, Reload and Home after the traffic lights, then the title and subtitle, then the actions at the trailing edge. In its archive mode the toolbar-placed search field also shows. The real site pane is still the user's live check. |
| F3 (Medium) | A remembered rail hides the full sidebar's sync status, error line and Sync History buttons. | Three additions to the rail. A red warning icon shows whenever the sidebar's message is set; its tooltip is the message, and clicking it expands the sidebar. Each account's initial has a context menu with Sync History or Stop Sync, as in the sidebar. The initial's tooltip and accessibility label carry the sync progress, else the last sync result, else the account state. |
| F4 (Medium) | No unit tests for the rail state. | **Deferred.** It is two booleans in the app target (`archiveRail` in defaults, `siteRail` reset by `openSite`), and the app has no UI test target (open since the first review). Covered by review and the manual checks below. |
| F5 (Medium) | `Docs/status.md` claimed the site collapses the sidebar, which the author had not observed. | Now: checked in the archive; collapsing on opening the site awaits the user's live check. |
| F6 (Low) | The inspector now sits inside an `HSplitView` pane. | **Observed fine** in the Debug build. Known side effect: the list's width resets after a visit to the site, because the archive's split view is rebuilt. Noted in the milestone doc. |
| F7 (Low) | Fixed sidebar width; a divider before the first account in the rail. | **Kept.** The fixed width is a documented limit. The divider separates the accounts from the "All accounts" icon. |
| F8 (Low) | The site pane's own Open button (when its session is closed) called `profiles.open` directly, so it did not collapse the sidebar. | `ArenaWebPane` takes an `open` closure, and `MainView` passes `openSite`. Every user Open now goes through the one path. |

## Manual checks (author, Debug build, 2026-10-18)

- Full sidebar at 240 pt, and Control-Command-S switching to the 64 pt rail and back, with the
  window staying at 1200 pt. Window captures, not kept.
- The rail's icons keep the palette's text color after the tint parameter was added.
- F2: the standalone check above (built with `swiftc` in the scratchpad, not part of the repo).

## Unverified (carried forward)

- The site pane with the rail, in the real app. Opening it loads arena.ai, which is the user's own
  use. The user's live check covers:
  - the automatic collapse;
  - the site toolbar;
  - Sync History from there.
- The rail's warning icon was not seen with a real message, because none was set during the checks.

## Checks run by the author after the fixes

- `python3 Scripts/check-boundaries.py`
- `bash Scripts/build.sh Debug`: no warnings.
- `bash Scripts/test-offline.sh`
