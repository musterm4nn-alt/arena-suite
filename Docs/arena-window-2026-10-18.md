# Embedded arena.ai (2026-10-18)

Decision: the user, 2026-10-18 ("make it so that i can use arena.ai directly in the app"; chose
the embedded window over open-in-browser after the conflict with ADR 0005/0001 was shown).
Recorded in `Docs/ADR/0006-embedded-arena-window.md`. Native generation (Track B) is unchanged and
still blocked (N-004).

The first build (commit `c48ed05`) opened a separate window per account. After trying it, the
user asked the same day for one window and for Arena Suite's colors to match arena.ai; see
"Second iteration" below. Criteria 1 and 5 below describe the current state.

## Acceptance criteria

1. **Opening.** Every account in the sidebar has an "arena.ai" row that shows the site beside the
   sidebar, in the one app window, for that account.
   - The first click opens the account's session; later clicks show the same page. There is one
     session per account, and no second window.
   - The title names the account's web profile. It does not claim which Arena account is signed in
     there.
2. **Profiles.**
   - Each session uses a persistent website data store keyed by the local account UUID, separate
     from the other accounts, Safari and the native Keychain session.
   - Clear Web Data (with confirmation) deletes that profile's data and reloads Arena's home page.
   - Removing an account ends its session and deletes its profile.
   - A deletion that could not finish is retried at the next launch.
   - Nothing else is ever deleted: no deletion is inferred from an account list (logic in
     `ApplicationActions.WebProfileLifecycle`, unit-tested).
3. **Navigation policy** (pure, unit-tested, in `ApplicationActions.WebSitePolicy`; Arena's
   instance comes from `ArenaAdapter`):
   - The main frame loads only `https` pages whose host is the site domain or one of its
     subdomains (`about:blank`/`about:srcdoc` too).
   - Other `http`/`https` and `mailto` destinations are offered in a banner and open only when the
     user clicks "Open in Browser". Any other scheme is dropped.
   - New-window requests for site pages load in the same page. Others are offered the same way.
     Nothing opens a second web view.
   - Lookalike hosts (`evilarena.ai`, `arena.ai.evil.com`, `arena.ai@evil.com`) are not the site.
4. **Browser basics.**
   - Back, forward, reload or stop, and home.
   - A read-only display of the current host.
   - A loading indicator, and a visible error when a page fails to load.
   - Page alert, confirm and prompt dialogs.
   - File upload through an open panel.
   - Downloads, from any frame, through a save panel. Cancelling the panel cancels the download.
     A replaced file is swapped only after the download finishes.
   - Camera and microphone are denied.
5. **Never** (ADR 0006): no scripts injected or evaluated, no message handlers, no cookie or
   storage reads, no custom scheme handlers, no web view the user did not open, no user-agent
   change. The boundary check allows `WebKit` only in `App/ArenaWebPane.swift` and rejects these
   APIs there; its deny-list self-tests.
6. **Archiving.**
   - The site's toolbar shows its account's Sync History button and progress, using the existing
     user-initiated sync (same traffic policy, same journal).
   - Nothing from the embedded site is journaled, indexed or exported.
7. **Docs.**
   - ADR 0006 records the decision.
   - Plan v3 §1, ADR 0005, AGENTS.md, the arena-suite skill, the handoff and the status say what
     changed.
   - The capability matrix keeps native `sendPrompt` as unsupported (blocked).
8. **Tests.**
   - Policy unit tests, and Arena's policy instance tested in the adapter tests.
   - The boundary self-test.
   - `Scripts/test-offline.sh` passes and the app builds.
   - A live check is left to the user (sign in, run a battle, sync), because it is the user's own
     use of Arena.

## What was built

| Piece | Where |
|---|---|
| Navigation policy (pure, site-agnostic): `load`, `askToOpen` (leaving the site is always offered, never automatic), `ignore` | `ApplicationActions/WebSitePolicy.swift` |
| Profile deletion lifecycle: only explicit removals, deferred while in use, pending removals persisted and retried | `ApplicationActions/WebProfileLifecycle.swift` |
| Arena's instance: the observed origin and cookie domain | `ArenaAdapter/Website/ArenaWebsite.swift` |
| Sessions (one web view each), pane, profiles, toolbar, banners, panels, downloads | `App/ArenaWebPane.swift` |
| One window: the sidebar switches between the archive and each account's site (`MainDestination`) | `App/MainView.swift`; the second `WindowGroup` was removed from `App/ArenaSuiteApp.swift` |
| Profile deletion when an account is removed (its session ends first); pending deletions retried at launch (pending list in the app's defaults) | `AccountsModel.onAccountRemoved`, `ArenaWebProfiles.accountRemoved`, `MainView` launch task |
| WebKit allowed only in the pane file; every tracked Swift file is scanned; a self-tested deny-list and exactly one `WKWebView(` in that file | `Scripts/check-boundaries.py` |

## Evidence

- `swift test --package-path Packages/ArenaSuiteCore --filter ApplicationActionsTests` checks:
  - site pages, including subdomains, case and a trailing dot;
  - lookalike hosts (`evilexample.org`, `example.org.evil.com`, `example.org@evil.com`), plain
    HTTP, and `file:`, `javascript:`, `data:`, `ftp:` and custom schemes;
  - `about:blank`/`about:srcdoc`, `mailto:`, and hostless URLs;
  - IDN lookalikes and userinfo with a lookalike host;
  - that leaving the site is only ever offered.
- `WebProfileLifecycle` tests: only the removed account's profile is deleted; deletion waits until
  the profile is no longer in use (now: its session closed); a failed deletion is retried at the next launch only; nothing is deleted
  without an explicit removal.
- `arenaWebsitePolicyIsTheObservedOrigin` (adapter tests): the home page is the native origin, and
  a challenge URL as a main frame is never loaded in place.
- The boundary self-test covers 27 forbidden probes, including the review's evasions, and 6 allowed
  forms.
- The app builds with no warnings, so every WebKit delegate method matched its SDK signature.
  `Scripts/test-offline.sh` passes.
- **Live check by the user (2026-10-18, separate-window build):** signed in on the embedded site
  and started a battle, which was accepted and generating. So sign-in works for that account and
  reCAPTCHA accepted a prompt sent from the embedded web view. Not yet checked: whether Sync
  History archived that conversation.
- The author has not loaded arena.ai in the app; loading the site is the user's own use of Arena.

## Limits

- **Live behaviour not yet checked:**
  - which sign-in methods work (Google sign-in is expected to refuse an embedded browser);
  - whether any Arena flow needs a popup window. Popups never get a second web view: site pages
    load in place, everything else goes through the "Open in Browser" banner;
  - the single-window build itself (see "Second iteration").
- **Signed-in account unknown to the app.** It cannot tell which Arena account is signed in to a
  web profile, because it never reads cookies or the page. Signing account B into account A's
  profile only affects that profile. Sync History still syncs account A's own native session.
- **Embedded-site traffic is not journaled.** A conversation is archived only when the history
  sync sees it.
- **Camera and microphone are denied.** Voice input on the site will not work.
- **Profile removal.** Removing an account ends its session first, but WebKit releases a web view
  asynchronously. If the profile is still held, deletion is retried at the next launch.
- **Profiles of accounts dropped by a backup restore are not deleted.** Only explicit removals
  delete, so restoring a backup without an account leaves that account's web profile in place.
  This is safe but uses space.
- **Independent review:** `Docs/reviews/2026-10-18-arena-window.md`.

## Second iteration: one window and matching colors (2026-10-18)

Request (after the live check): "Arena Suite should by default always be one window, not pop out
a second one for arena.ai, and secondly, the colour palette of arena.ai and arena suite don't
harmonize".

### Acceptance criteria

1. **One window.**
   - No second window scene.
   - Each account's "arena.ai" sidebar row shows the site beside the sidebar.
   - "All accounts" or an account row shows the archive again.
   - Launch always shows the archive and loads nothing from the site.
2. **Sessions survive switching.**
   - The first click opens the account's session (one web view).
   - Showing the archive or another account keeps that page, like a background tab. The sidebar
     marks it "open".
   - While not shown, the page cannot present dialogs, uploads or downloads: they are declined,
     with a notice.
   - "Close arena.ai Session" ends it, and removing the account ends it before its profile is
     deleted.
   - ADR 0006 is amended to say so.
3. **Palette.**
   - The archive uses arena.ai's warm neutral dark colors, sampled from the user's screenshot:
     - background `#252523`;
     - selected rows `#1b1a19`;
     - prompt bubble `#403c3a`;
     - borders `#403d39`;
     - text `#f3f0ec`.
   - Backgrounds are opaque instead of wallpaper-tinted, and there is no system blue in the app's
     own controls.
   - Selections are drawn as arena.ai's darker rounded rows.
   - Prompts are filled bubbles and responses are outlined panes, as on the site.
4. **Unchanged:**
   - every ADR 0006 boundary (the boundary check, with the file renamed);
   - the conversation list's keyboard navigation (up/down arrows);
   - quitting with a sheet open.

### What changed

| Change | Where |
|---|---|
| `ArenaWebProfiles` (observable) owns the sessions: `open`, `close`, `accountRemoved` | `App/ArenaWebPane.swift` |
| `ArenaWebSession`: the one `WKWebView`, its delegate and `ArenaWebPage` | `App/ArenaWebPane.swift` |
| `ArenaWebHost` moves the session's web view into the pane, and out of it when the pane goes away | `App/ArenaWebPane.swift` |
| Page dialogs, uploads and downloads need a visible window, otherwise they are declined with a notice | `App/ArenaWebPane.swift` |
| `MainDestination` (`archive` or `site(account)`); the sidebar is drawn in the palette, with a site row per account | `App/MainView.swift` |
| Palette tokens; `arenaPalette`, `arenaSelection`, `arenaSheet`; `ArenaPillStyle` replaces blue link buttons | `App/Theme.swift` |
| Conversation list drawn with its own selection (List selection always uses the system accent, which is Blue on this Mac) | `App/MainView.swift` |
| File renamed `ArenaWebWindow.swift` → `ArenaWebPane.swift` (project and boundary check updated) | `ArenaSuite.xcodeproj`, `Scripts/check-boundaries.py` |

### Evidence

- `bash Scripts/build.sh Debug`: no warnings. `python3 Scripts/check-boundaries.py` passes,
  including the exactly-one-`WKWebView(` rule. `Scripts/test-offline.sh` passes.
- Debug build against the real archive, checked from captures of the Arena Suite window only (not
  kept):
  - the background measures exactly `#252523`;
  - the selected conversation is the dark rounded row;
  - prompt bubbles and outlined response panes match the site;
  - Maintenance uses pill buttons, and the sheet's Done is a pill.
- Manual checks in that Debug build (not automated; the app has no UI test target):
  - **Arrow keys.** A row was pressed through accessibility, then ↑ was sent. The selection and
    transcript moved to the row above.
  - **Quit with a sheet open.** An in-sheet Done button made the app refuse an AppleScript quit
    ("User canceled"). With Done kept as a confirmation toolbar item (pill-styled), quit works,
    as before.
- The site in the main window was not loaded by the author. That live check (open the site row,
  switch to the archive and back during a battle, Close Session) is the user's.

- Independent review: `Docs/reviews/2026-10-18-single-window.md`. It found no code defect in the
  session model or boundaries. Its fixes are applied:
  - the help text no longer claims the page's chats are archived;
  - "shown" now requires a visible, non-minimized window;
  - the traffic-policy scope is stated in plan v3 §2 and the ADR.

### Limits

- **Light palette is a guess.** Only arena.ai's dark theme was sampled. The light colors are
  matching warm neutrals.
- **System chrome.** The sheet footer strip (behind Done), column dividers, the search field and
  toolbar buttons are drawn by macOS in its own colors. List selection was replaced only in the
  conversation list. The Accounts sheet's list keeps its own row style.
- **Background sessions use memory.** Each opened account keeps a web content process until Close
  Session or quit.
- **A dialog in a background page is declined.** For example, a site confirmation while the
  archive is shown answers "cancel". The page notes it when shown again.

## Third iteration: sidebar rail (2026-10-18)

Request: "in arena.ai, when you hide the sidebar, it [collapses to an icon rail] … i want the arena
suite sidebar to also do something like this, and it should happen automatically when you click
on the button to start arena.ai".

### Acceptance criteria

1. **Rail.** The sidebar collapses to a narrow icon rail instead of disappearing:
   - a toggle;
   - the archive;
   - per account, its initial (that account's archive) and a globe (its site, with a dot while its
     session is open);
   - Manage Accounts and Maintenance.

   Every icon has a tooltip and an accessibility label, and the selected one is marked as on the
   site.
2. **Toggle.** The sidebar's own button, or Control-Command-S, switches between full and rail. The
   system sidebar toggle, which would hide the sidebar completely, is gone.
3. **Automatic.** Every click on a site entry, in the full sidebar or the rail, shows the site with
   the sidebar collapsed to the rail. The user can expand it again there.
4. **The archive keeps its own choice.** It is remembered in the app's defaults
   (`sidebarRailInArchive`), so going back from the site restores it. The default is the full
   sidebar.
5. **Unchanged:**
   - the site still loads only from the user's click (`openSite` → `ArenaWebProfiles.open`);
   - the window keeps its size when switching;
   - the list stays resizable;
   - the inspector, search and arrow keys still work.

### What changed

| Change | Where |
|---|---|
| `NavigationSplitView` replaced by an explicit layout: `HStack` of sidebar (240 pt) or rail (64 pt), a border, then the archive (`HSplitView` of list and transcript, with the inspector) or the site | `App/MainView.swift` |
| `SidebarRail`, `SidebarToggle`; `openSite(_:)` opens the session, sets the rail and shows the site | `App/MainView.swift` |
| Search field placed in the toolbar (it was a sidebar placement of the split view) | `App/MainView.swift` |
| The rail keeps the sidebar's sync surface: a warning icon for the sidebar's message (clicking it expands the sidebar), a Sync History / Stop Sync menu on each initial, and the sync state in the initial's tooltip | `App/MainView.swift` |
| The site pane's own Open button (shown when its session is closed) goes through `openSite`, so it collapses the sidebar too | `App/ArenaWebPane.swift`, `App/MainView.swift` |

Why not `NavigationSplitView`: tried first, and its sidebar would not switch reliably.
- Shrinking it to 64 pt worked, but growing it back ignored the minimum width and stopped at
  140 pt.
- At launch it restored that saved 140 pt width.
- Hiding the sidebar and showing it again grew the window by the sidebar's width each time.

The test runs left a saved split-view width and a wider window frame in the app's defaults, shared
by the Debug and installed builds. Both were reset: the split-view entry was deleted and the window
width set back to 1200 pt.

### Evidence

- `bash Scripts/build.sh Debug`: no warnings. `python3 Scripts/check-boundaries.py` passes.
- Debug build against the real archive, from window captures (not kept):
  - full sidebar at 240 pt, unclipped;
  - Control-Command-S collapses to the rail, and again restores the full sidebar;
  - the window stays at 1200 pt throughout;
  - list, transcript and inspector fit beside either;
  - the search field shows in the toolbar.
- The site pane's toolbar outside a navigation container, checked without loading the site: a
  standalone SwiftUI app with the same layout shows the Back/Forward/Reload/Home group after the
  traffic lights, then the title and subtitle, then the actions.
- Independent review: `Docs/reviews/2026-10-18-sidebar-rail.md`.
- Not observed by the author: the site with the rail. Opening the site row loads arena.ai, which is
  the user's own use, so the automatic collapse there is part of the user's live check.

### Limits

- **Fixed sidebar width.** The full sidebar is 240 pt and cannot be resized, unlike before.
- **The sidebar now starts below the toolbar.** It no longer runs full height under the title bar,
  because that was a `NavigationSplitView` feature.
- **The rail shows accounts as initials.** Two accounts with the same initial are told apart only
  by tooltip and order.
- **The list's width resets after a visit to the site**, because the archive's split view is
  rebuilt when it comes back.
