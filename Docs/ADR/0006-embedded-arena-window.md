# ADR 0006 — Embedded arena.ai

Status: **accepted** (user decision 2026-10-18). **Amended 2026-10-18** (user request, same day):
arena.ai is shown inside the one Arena Suite window instead of a separate window. See
"Amendment: one window" below.

## Context

The user wants to use arena.ai from inside Arena Suite: prompts, battles, voting and reveal.

Native generation is still blocked. Every new prompt must carry a reCAPTCHA v3 token, and a native
request without one was rejected with 403 "recaptcha validation failed" (N-004). Plan v3 §1 allows
Track B only through a legitimate non-browser path. It explicitly rules out copied browser tokens,
reCAPTCHA in a hidden WebView, and solving or replaying challenges. None of that changes here.

ADR 0005 said "No browser runtime … in any version", and ADR 0001 said not to replace the native
design with a WebView. The user was shown both statements and chose (2026-10-18) to allow one
narrowly defined browser runtime: a visible window showing the real arena.ai site, driven only by
the user.

## Decision

1. **One browser runtime, visible and user-driven.** Arena Suite may show arena.ai in a visible
   `WKWebView` in its main window (originally a separate window, see the amendment). Everything
   that happens there comes from the user's own clicks and typing. The native archiver is
   unchanged and is not replaced by it.
2. **Never:**
   - injected, evaluated or user scripts, or script message handlers;
   - reading page content, cookies or web storage, including into the archive, logs or diagnostics;
   - moving any session material between the embedded site and native code, in either direction;
   - web views the user did not open: nothing loads the site at launch, on a schedule or on the
     app's own initiative. *Amended:* a session the user opened keeps its page while the archive
     is shown, like a background browser tab (see the amendment). This text originally read
     "hidden, off-screen or background web views";
   - automated clicks, typing, form filling, polling or reloading;
   - solving, farming or bypassing any challenge;
   - a spoofed user agent (WebKit's default is used as-is).
3. **One web profile per archiver account.** Each account gets its own persistent website data
   store (`WKWebsiteDataStore(forIdentifier: <local account UUID>)`), separate from Safari, the
   other accounts and the archiver's Keychain session.
   - The user signs in on the site inside the app.
   - The app does not verify which Arena account is signed in there, because it never reads the
     page or cookies. The title is "<site> · web profile of <account name>", which labels the
     profile and does not claim a verified identity.
   - Clear Web Data (after a confirmation) deletes the profile's cookies and storage.
   - A profile is deleted only when the user removes its account. The app never infers deletions
     from an account list, which may be missing, unreadable or from another archive root.
     Removing an account ends its open session first. A deletion WebKit could not finish is kept
     in the app's defaults (same per-app scope as the profiles) and retried at the next launch.
4. **Navigation stays on Arena.**
   - Main-frame navigation is allowed only to `https` pages on Arena's site domain, which only
     `ArenaAdapter` knows.
   - Other `http`/`https` and `mailto` destinations never open automatically. The page shows a
     banner with the destination, and only the user's click on "Open in Browser" hands it to the
     default browser or mail client. WebKit cannot tell a real click from a scripted one, so no
     navigation type is trusted for this. All other schemes are dropped.
   - Subframes and subresources (reCAPTCHA, challenge frames, assets) load as the page requests,
     as in any browser.
   - New-window requests load in the same page when they target Arena, and are offered through
     the banner otherwise. They never get a second web view.
   - The toolbar's "Open Page in Browser" opens the current page in the default browser, as a
     user click.
   - Camera and microphone requests are denied. Downloads, in any frame, and file uploads happen
     only through a save or open panel the user confirms. A download that replaces an existing
     file is written beside it first, and the original is replaced only after the download
     finishes.
5. **Capture boundary.**
   - Traffic on the embedded site is outside the journal: no exact bytes, no timing, no stream
     records.
   - It is also outside plan v3 §2's traffic policy, which governs the app's native requests. The
     page's requests, including those of a session kept in the background, are the site's own;
     the app does not originate, rate-limit, observe or record them.
   - A conversation made there reaches the archive only through the user-initiated native history
     sync, which journals the server's history responses exactly. The site's toolbar offers that
     account's Sync History button.
   - Native `sendPrompt`/`createConversation` remain `unsupported (blocked: reCAPTCHA v3, N-004)`,
     and Track B is unchanged.
6. **Voting and reveal on the embedded site** are the user's own clicks on Arena's site. Arena
   Suite never automates, suggests, pre-selects or batches them, and MCP has no access to it.

## Amendment: one window (2026-10-18)

The user asked that Arena Suite always be one window ("not pop out a second one for arena.ai").

- The sidebar lists the site under each account. Clicking it shows the site beside the sidebar,
  in that account's web profile; clicking "All accounts" or an account shows the archive again.
  There is no second window scene any more.
- **Sessions.** The first click opens the account's session: one web view, created then and
  never at launch. It keeps its page while the archive or another account is shown, so a battle
  still generating is not lost. The sidebar marks it "open".
  - While its page is not shown, the app never acts on it. Page dialogs, file uploads and
    downloads it asks for are declined (nothing is presented off-screen), and the page shows a
    notice about it when it is shown again. "Shown" is measured as the web view being in a
    visible, non-minimized window, which is the case only while its pane is displayed.
  - The toolbar's "Close <site> Session" ends it: the page stops and the web view is released.
    The sign-in stays in the profile.
  - Removing the account ends its session, then deletes the profile.
- Still exactly one web view per open session, and none is hidden with `isHidden`/`alphaValue` or
  drawn off-screen: a session not shown is simply not in any view hierarchy, like a background
  tab.

## Consequences

- **Supersedes:**
  - ADR 0005's bullet "No browser runtime, browser-token transfer or challenge bypass in any
    version" now reads: no browser runtime other than this embedded site, and never
    browser-token transfer or challenge bypass.
  - ADR 0001's "do not replace the design with a WebView" still holds for the native path. The
    embedded site is an addition, not a replacement.
  - Plan v3 §1, "Explicitly out of v1: any browser runtime", is amended by a dated note.
- **Where the embedded site's session lives.** Its arena.ai cookies live in WebKit's on-disk website data
  for this app (`~/Library/WebKit/<bundle id>/`), as Safari's do. They are not in the Keychain,
  the archive, backups or diagnostics.
- **Enforcement.** `Scripts/check-boundaries.py` allows `WebKit` only in `App/ArenaWebPane.swift`
  (named `ArenaWebWindow.swift` before the amendment).
  - Every tracked Swift file outside tools is checked for a WebKit import.
  - In that file, it rejects script, cookie, storage, scheme-handler, user-agent,
    page/screen-capture and dynamic-dispatch APIs, aliases, and any second `WKWebView`
    constructor. The deny-list self-tests.
  - The check is textual, so code review remains part of the enforcement.
- **Live check (the user, 2026-10-18, separate-window build):** signing in on the embedded site
  worked, and a battle prompt was accepted and generating, so reCAPTCHA accepted a prompt sent
  from the embedded web view. Still unchecked: whether that conversation was archived by Sync
  History, and which sign-in methods work (Google sign-in often refuses embedded browsers). If
  something fails, the page shows Arena's own response and nothing is retried or worked around.
