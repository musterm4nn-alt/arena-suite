# Review — embedded arena.ai in one window, and the matching palette (2026-10-18)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5).
- **Scope:** the uncommitted change against `c48ed05`:
  - the second window scene removed, and the site shown in the main window (`MainDestination`);
  - per-account sessions in `App/ArenaWebPane.swift` (renamed from `ArenaWebWindow.swift`);
  - the palette in `App/Theme.swift` and its use in the archive views and sheets;
  - the ADR 0006 amendment and the docs listed in the review prompt.

  Acceptance criteria: `Docs/arena-window-2026-10-18.md`, "Second iteration".
- **Reviewer saw the real diff:** yes. It ran `git diff HEAD -M` and read the new files in full.
- **Reviewer ran tests:** partly. It ran `swift test --package-path Packages/ArenaSuiteCore` (all
  suites, including the 8 `ApplicationActionsTests`), which passed. Its sandbox denied
  `python3 Scripts/check-boundaries.py`, `bash Scripts/build.sh Debug` and
  `Scripts/test-offline.sh`; it checked the boundary rules by reading (one `WKWebView(`, the
  WebKit import rule, no `isHidden`/`alphaValue`, no forbidden APIs, no `openWindow`). The author
  ran those commands (below).
- **Verdict:** "not ready for this milestone", because of documentation integrity and one string.
  - No concurrency, ownership, account-isolation, journal or boundary defect was found in the
    session model, re-parenting, teardown or deletion ordering.
  - The blockers were F1 (help text) and F2 (this record did not exist yet). Both are fixed below.

## Findings and fixes

| # | Finding | Fix |
|---|---|---|
| F1 (Medium) | The Sync History help said it archives "chats from this page". The app never checks which Arena account is signed in on the page, so it may be a different one. | Now: "Archive this account's Arena history with its own Arena Suite sign-in (the account signed in on this page is not checked)". |
| F2 (Medium) | Status and handoff cited this review before it existed. | This file. |
| F3 (Low) | The lifecycle test still spoke of windows. | Renamed to `aProfileInUseIsDeletedWhenItIsLastClosed`, with comments in session terms. Behaviour unchanged, and the 8 tests pass. The earlier review record keeps the old name as history. |
| F4 (Low/Medium) | The "not shown ⇒ declined" rule has no executable test. | **Deferred.** The rule reads AppKit state (`webView.window`, `isVisible`, `isMiniaturized`). A pure predicate in `ApplicationActions` would test a one-line boolean, not the wiring that could regress. The app has no UI test target (open since the first review). Covered by review and the boundary check's single-file rule. |
| F5 (Low) | The evidence for keyboard navigation and quit-with-sheet was not stated as measured. | **Checked by the author, Debug build, 2026-10-18:** the observed results are below, and the milestone doc says these are manual checks. |
| F6 (Low) | "Not shown" was approximated by `webView.window != nil`. A minimized window would still present a dialog. | Dialogs, uploads and downloads now need a visible, non-minimized window. ADR 0006 states the measured boundary. A dismantle that SwiftUI has not run yet in the same run-loop turn is a theoretical gap, accepted. |
| F7 (Low) | Background site traffic sits outside plan v3 §2, which did not say so. | Plan v3 §2 and ADR 0006 decision 5 now say it. The policy governs the app's native requests. The embedded page's requests, including a background session's, are the site's own, and the app does not originate, rate-limit, observe or record them. |
| Nit (pre-existing) | `download(_:didFailWithError:)` matches "cancelled" by code without the domain. | Left as is: a non-URL-domain −999 only skips a notice. |

### F5: manual checks (author, Debug build, 2026-10-18)

- **Keyboard navigation:** a conversation row was pressed through accessibility (it selected
  "Minimal personal website design"), then ↑ was sent with a frontmost-app guard. The selection
  and transcript moved to "Stylized hello html design" (window captures before and after).
- **Quit with a sheet open:**
  - Done kept as a confirmation toolbar item: the AppleScript quit succeeded.
  - An in-sheet Done button, tried first: the app refused with "User canceled", so that variant
    was dropped.

## Unverified (carried forward)

- The single-window build has not loaded arena.ai. That live check is the user's:
  - open the site row;
  - switch to the archive and back during a battle;
  - Close Session;
  - Sync History.
- **Accessibility labels of the custom conversation rows.** System Events reports no
  `AXTitle`/`AXDescription` for any SwiftUI button in this window, including the unchanged
  "Manage Accounts…", so the probe cannot read them. The selected row does report
  `AXSelected=true`.
- Whether `WKWebsiteDataStore.remove(forIdentifier:)` fails cleanly while a store is still held.
  The retry at the next launch covers it.

## Checks run by the author after the fixes

- `python3 Scripts/check-boundaries.py`
- `bash Scripts/build.sh Debug`: no warnings.
- `swift test --package-path Packages/ArenaSuiteCore --filter ApplicationActionsTests` (8 tests)
- `bash Scripts/test-offline.sh`
