# Review — embedded arena.ai window, ADR 0006 (2026-10-18)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5). The usual `muse-spark-1.3-contributor-free` is
  unavailable (see `Docs/reviews/2026-10-18-datasets.md`).
- **Scope:** the uncommitted diff adding the embedded window, against ADR 0006 and
  `Docs/arena-window-2026-10-18.md`.
- **Reviewer saw the real diff:** yes: `git diff`, full reads of the new files.
- **Reviewer ran tests:** no. Its sandbox denied `python3`, `swift` and `ls` this time. It checked
  the boundary conditions statically, and the author ran them (below).
- **Verdict:** "not ready for this milestone". There was one High finding, and three Medium
  findings that weakened the properties the ADR names as enforcement. Each finding held up and was
  fixed before commit.

## Findings and fixes

| # | Finding | Fix |
|---|---|---|
| H1 | The launch-time orphan sweep treated a **missing** registry file (which reads as an empty list, not an error) as "no accounts". It would have deleted every web profile, silently signing the user out everywhere. A `--archive-root` run could do the same in the other direction. | **The sweep is gone.** New `ApplicationActions.WebProfileLifecycle` deletes a profile only when the user removes its account, never by inference from an account list. A profile in use is deleted when its last window closes; a failed deletion is saved (the app's defaults, the same per-app scope as WebKit's profiles) and retried at the next launch. `registryLoaded` was removed. Tests: `removingAnAccountDeletesOnlyItsProfile`, `aProfileInUseIsDeletedWhenItsLastWindowCloses`, `aFailedDeletionIsRetriedAtTheNextLaunchOnly`, `nothingIsDeletedWithoutAnExplicitRemoval`. |
| M2 | When a download replaced an existing file, the original was deleted before WebKit wrote anything, so a failed download destroyed it. | A replacing download is now written to a sibling `<name>.arenasuite-download-<id>` file and swapped in with `FileManager.replaceItemAt` only after `downloadDidFinish`. On failure only that partial file is removed, and the original is never touched. |
| M3 | "Leaving the site needs a click" trusted `navigationType == .linkActivated`, which a scripted `element.click()` can produce. | **Fail-safe.** The policy has no click fast path any more: every off-site `http`/`https`/`mailto` destination is `askToOpen`, shown in a banner, and opened only by the user's "Open in Browser" click. The `openExternally` decision was removed. |
| M4 | The textual deny-list was evadable: bare `WKWebsiteDataStore()`, page or screen capture APIs, `NSClassFromString`/`perform(`, an aliased `WKWebView`, and files outside the scanned folders. | Added those patterns, plus `#selector`, `value(forKey`, `objc_msgSend`, `dlsym`, swizzling, `typealias`, `WKWebView.init`/`.self`/`.init(frame`, `NSImage(`, `ScreenCaptureKit`. Self-tested with 27 forbidden probes and 6 allowed forms. Every tracked Swift file must now be in a registered location, and none outside the window file and tools may import WebKit. ADR 0006 now says the check is textual and review remains part of enforcement. |
| ML5 | Downloads started from a subframe did nothing. | The `shouldPerformDownload` check runs before the main-frame guard, and any response WebKit cannot show becomes a download, always through the save panel. |
| L6 | The code mixed `MainActor.assumeIsolated` with implicit main-actor closures. | KVO now hops with `Task { @MainActor … }` and reads the web view from the page, so it cannot crash off the main thread. The alert completion uses the inferred main-actor closure like the panels do. |
| L7 | Actions were applied before the navigation decision was given. | The decision handler is called first, then the action. |
| L8 | The ADR's wording differed from the UI: title, banner, menu, clear confirmation. | The title is now "<site> · web profile of <account>". ADR 0006 now describes the banner, "Open Page in Browser", the Clear Web Data confirmation, download replacement and the deletion rules. |

## Test gaps raised

| Gap | Outcome |
|---|---|
| No tests for profile lifecycle | Added: four `WebProfileLifecycle` tests (logic moved out of the app into `ApplicationActions`). |
| IDN/punycode, subdomain plus trailing dot, userinfo with a lookalike host | Added to `WebSitePolicyTests`. |
| WebKit integration (scripted click, lookalike navigation, download replace or cancel, `clearWebData`) | Not automated: the app has no UI test target, and loading a page is the user's live check. The policy and lifecycle they rely on are unit-tested. Recorded as open. |

## Checks run by the author after the fixes

- `python3 Scripts/check-boundaries.py`
- `swift test --package-path Packages/ArenaSuiteCore --filter ApplicationActionsTests` (8 tests)
- `swift test --package-path Packages/ArenaProtocol --filter arenaWebsite`
- `bash Scripts/build.sh Debug`: no warnings.
- `bash Scripts/test-offline.sh`

## Unverified assumptions (from the review)

- `openWindow(id:value:)` brings an existing window for the same account forward. If it opened a
  second one, the in-use counting would keep that harmless.
- `allDataStoreIdentifiers` is no longer used.
- Sign-in and reCAPTCHA in the window are the user's live check.
