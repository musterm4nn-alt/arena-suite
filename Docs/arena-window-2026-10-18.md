# Embedded arena.ai window (2026-10-18)

Decision: the user, 2026-10-18 ("make it so that i can use arena.ai directly in the app"; chose
the embedded window over open-in-browser after the conflict with ADR 0005/0001 was shown).
Recorded in `Docs/ADR/0006-embedded-arena-window.md`. Native generation (Track B) is unchanged and
still blocked (N-004).

## Acceptance criteria

1. **Opening.** Every account row in the sidebar has an "arena.ai" action that opens a window for
   that account.
   - Opening the same account again brings its window forward. There is one window per account.
   - The window title names the account's web profile. It does not claim which Arena account is
     signed in there.
2. **Profiles.**
   - Each window uses a persistent website data store keyed by the local account UUID, separate
     from the other accounts, Safari and the native Keychain session.
   - Clear Web Data (with confirmation) deletes that profile's data and reloads Arena's home page.
   - Removing an account deletes its profile. A profile still in use is deleted when its window
     closes.
   - A deletion that could not finish is retried at the next launch.
   - Nothing else is ever deleted: no deletion is inferred from an account list (logic in
     `ApplicationActions.WebProfileLifecycle`, unit-tested).
3. **Navigation policy** (pure, unit-tested, in `ApplicationActions.WebSitePolicy`; Arena's
   instance comes from `ArenaAdapter`):
   - The main frame loads only `https` pages whose host is the site domain or one of its
     subdomains (`about:blank`/`about:srcdoc` too).
   - Other `http`/`https` and `mailto` destinations are offered in a banner and open only when the
     user clicks "Open in Browser". Any other scheme is dropped.
   - New-window requests for site pages load in the same window. Others are offered the same way.
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
   storage reads, no custom scheme handlers, no hidden web views, no user-agent change. The
   boundary check allows `WebKit` only in `App/ArenaWebWindow.swift` and rejects these APIs
   there; its deny-list self-tests.
6. **Archiving.**
   - The window shows its account's Sync History button and progress, using the existing
     user-initiated sync (same traffic policy, same journal).
   - Nothing from the window is journaled, indexed or exported.
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
| Window, web view, profiles, toolbar, banners, panels, downloads | `App/ArenaWebWindow.swift` |
| One window per account (`WindowGroup(id: "arena-web", for: AccountID.self)`); "Open arena.ai" per account in the sidebar | `App/ArenaSuiteApp.swift`, `App/MainView.swift` |
| Profile deletion when an account is removed; pending deletions retried at launch (pending list in the app's defaults) | `AccountsModel.onAccountRemoved`, `ArenaWebProfiles`, `MainView` launch task |
| WebKit allowed only in the window file; every tracked Swift file is scanned; a self-tested deny-list and exactly one `WKWebView(` in that file | `Scripts/check-boundaries.py` |

## Evidence

- `swift test --package-path Packages/ArenaSuiteCore --filter ApplicationActionsTests` checks:
  - site pages, including subdomains, case and a trailing dot;
  - lookalike hosts (`evilexample.org`, `example.org.evil.com`, `example.org@evil.com`), plain
    HTTP, and `file:`, `javascript:`, `data:`, `ftp:` and custom schemes;
  - `about:blank`/`about:srcdoc`, `mailto:`, and hostless URLs;
  - IDN lookalikes and userinfo with a lookalike host;
  - that leaving the site is only ever offered.
- `WebProfileLifecycle` tests: only the removed account's profile is deleted; deletion waits for
  the last window; a failed deletion is retried at the next launch only; nothing is deleted
  without an explicit removal.
- `arenaWebsitePolicyIsTheObservedOrigin` (adapter tests): the home page is the native origin, and
  a challenge URL as a main frame is never loaded in place.
- The boundary self-test covers 27 forbidden probes, including the review's evasions, and 6 allowed
  forms.
- The app builds with no warnings, so every WebKit delegate method matched its SDK signature.
  `Scripts/test-offline.sh` passes.
- Not observed by the author: the window has not been opened against arena.ai. Loading the site is
  the user's own use of Arena, so the live check is theirs (see Limits).

## Limits

- **Live behaviour unverified:**
  - sign-in in the window (Google sign-in is expected to refuse an embedded browser; email and
    password are expected to work);
  - whether reCAPTCHA accepts prompts from the window;
  - whether any Arena flow needs a popup window. Popups never get a second web view: site pages
    load in place, everything else goes through the "Open in Browser" banner.
- **Signed-in account unknown to the app.** It cannot tell which Arena account is signed in to a
  window, because it never reads cookies or the page. Signing account B into account A's window
  only affects that window. Sync History still syncs account A's own native session.
- **Window traffic is not journaled.** A conversation is archived only when the history sync sees
  it.
- **Camera and microphone are denied.** Voice input on the site will not work.
- **Profile removal while the window is open.** WebKit releases a closed web view asynchronously.
  If the profile is still held, deletion is retried when the window closes and again at the next
  launch.
- **Profiles of accounts dropped by a backup restore are not deleted.** Only explicit removals
  delete, so restoring a backup without an account leaves that account's web profile in place.
  This is safe but uses space.
- **Independent review:** `Docs/reviews/2026-10-18-arena-window.md`.
