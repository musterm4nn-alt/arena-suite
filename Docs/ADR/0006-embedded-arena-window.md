# ADR 0006 — Embedded arena.ai window

Status: **accepted** (user decision 2026-10-18).

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
   `WKWebView` window. Everything that happens there comes from the user's own clicks and typing.
   The native archiver is unchanged and is not replaced by the window.
2. **Never:**
   - injected, evaluated or user scripts, or script message handlers;
   - reading page content, cookies or web storage, including into the archive, logs or diagnostics;
   - moving any session material between the window and native code, in either direction;
   - hidden, off-screen or background web views;
   - automated clicks, typing, form filling, polling or reloading;
   - solving, farming or bypassing any challenge;
   - a spoofed user agent (WebKit's default is used as-is).
3. **One web profile per archiver account.** Each account gets its own persistent website data
   store (`WKWebsiteDataStore(forIdentifier: <local account UUID>)`), separate from Safari, the
   other accounts and the archiver's Keychain session.
   - The user signs in inside the window.
   - The app does not verify which Arena account is signed in there, because it never reads the
     page or cookies. The window title is "<site> · web profile of <account name>", which labels
     the profile and does not claim a verified identity.
   - Clear Web Data in the window (after a confirmation) deletes the profile's cookies and storage.
   - A profile is deleted only when the user removes its account. The app never infers deletions
     from an account list, which may be missing, unreadable or from another archive root. A
     profile still open is deleted when its window closes. A deletion WebKit could not finish is
     kept in the app's defaults (same per-app scope as the profiles) and retried at the next
     launch.
4. **Navigation stays on Arena.**
   - Main-frame navigation is allowed only to `https` pages on Arena's site domain, which only
     `ArenaAdapter` knows.
   - Other `http`/`https` and `mailto` destinations never open automatically. The window shows a
     banner with the destination, and only the user's click on "Open in Browser" hands it to the
     default browser or mail client. WebKit cannot tell a real click from a scripted one, so no
     navigation type is trusted for this. All other schemes are dropped.
   - Subframes and subresources (reCAPTCHA, challenge frames, assets) load as the page requests,
     as in any browser.
   - New-window requests load in the same window when they target Arena, and are offered through
     the banner otherwise. They never get a second web view.
   - The toolbar's "Open Page in Browser" opens the current page in the default browser, as a
     user click.
   - Camera and microphone requests are denied. Downloads, in any frame, and file uploads happen
     only through a save or open panel the user confirms. A download that replaces an existing
     file is written beside it first, and the original is replaced only after the download
     finishes.
5. **Capture boundary.**
   - Traffic in the window is outside the journal: no exact bytes, no timing, no stream records.
   - A conversation made there reaches the archive only through the user-initiated native history
     sync, which journals the server's history responses exactly. The window offers that account's
     Sync History button.
   - Native `sendPrompt`/`createConversation` remain `unsupported (blocked: reCAPTCHA v3, N-004)`,
     and Track B is unchanged.
6. **Voting and reveal in the window** are the user's own clicks on Arena's site. Arena Suite never
   automates, suggests, pre-selects or batches them, and MCP has no access to the window.

## Consequences

- **Supersedes:**
  - ADR 0005's bullet "No browser runtime, browser-token transfer or challenge bypass in any
    version" now reads: no browser runtime other than this window, and never browser-token
    transfer or challenge bypass.
  - ADR 0001's "do not replace the design with a WebView" still holds for the native path. The
    window is an addition, not a replacement.
  - Plan v3 §1, "Explicitly out of v1: any browser runtime", is amended by a dated note.
- **Where the window's session lives.** Its arena.ai cookies live in WebKit's on-disk website data
  for this app (`~/Library/WebKit/<bundle id>/`), as Safari's do. They are not in the Keychain,
  the archive, backups or diagnostics.
- **Enforcement.** `Scripts/check-boundaries.py` allows `WebKit` only in `App/ArenaWebWindow.swift`.
  - Every tracked Swift file outside tools is checked for a WebKit import.
  - In the window file, it rejects script, cookie, storage, scheme-handler, user-agent,
    page/screen-capture and dynamic-dispatch APIs, aliases, and any second `WKWebView`
    constructor. The deny-list self-tests.
  - The check is textual, so code review remains part of the enforcement.
- **Unverified until the user tries it (NEEDS LIVE CHECK):**
  - whether arena.ai's sign-in works in the window (Google sign-in often refuses embedded
    browsers; email and password are expected to work);
  - whether reCAPTCHA accepts prompts sent from the window.

  If either fails, the window shows Arena's own response and nothing is retried or worked around.
