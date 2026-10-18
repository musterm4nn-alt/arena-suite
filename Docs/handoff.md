# Session handoff

Read this first in a new session, then `Docs/status.md`, `AGENTS.md` and
`Arena-Suite-Master-Plan-v3.md`. This file is replaced, not appended to.

Updated 2026-10-18, after the app-wide UI rework (approved by the user and pushed).

## Where things stand

- v1 is complete: plan phases 0-A through 7 are all implemented, independently reviewed, fixed and
  committed.
  - Per-phase records: `Docs/phase*-*.md`.
  - Reviews: `Docs/reviews/2026-09-24-*.md`.
  - Release notes and known limits: `Docs/release-notes-1.0.md`.
- Arena Suite 1.0.0 is installed at `~/Applications/Arena Suite.app` (signed Release, via
  `Scripts/package.sh`).
- Live archive: `~/Library/Application Support/Arena Suite/Archive`.
  - 3 accounts, all signed in; 57 conversations; journals of 30 / 31 / 49 records.
  - Verify is clean, and the live index equals a fresh replay.
- §14 read-only MCP is done and reviewed: `Packages/ArenaSuiteMCP`, `Docs/mcp-readonly-2026-09-25.md`.
- **Embedded arena.ai** (ADR 0006, user decision 2026-10-18, amended the same day for one window):
  `App/ArenaWebPane.swift`. Each account's "arena.ai" sidebar row shows the site beside the
  sidebar in the one app window.
  - Each account has one web profile and at most one session. The session keeps its page while
    the archive is shown, until Close Session.
  - The site's header bar has a Sync History button.
  - Profiles are deleted only for removed accounts (`WebProfileLifecycle`).
  - Off-site links only go through an "Open in Browser" banner.
  - The user confirmed sign-in and a battle in it (separate-window build).
  - The app's palette matches arena.ai's dark theme (`Theme`).
  - The sidebar collapses to an icon rail (`SidebarRail`, Control-Command-S), automatically when a
    site entry is clicked. `MainView` lays it out itself, without `NavigationSplitView`, because
    that view's sidebar could not switch reliably between full and rail.
- **App-wide UI rework** (`Docs/ui-rework-2026-10-18.md`): approved by the user on 2026-10-18 and
  pushed. Review: `Docs/reviews/2026-10-18-ui-rework.md`.
  - The window has no title bar or toolbar; each pane draws a 32 pt `HeaderBar` in the top band.
  - The sidebar holds the site entry, Search (⌘F), Sync History, the history by date and the
    account switcher.
  - Accounts and Maintenance are pages (`MainDestination.accounts` / `.maintenance`), not sheets.
  - Docs: `Docs/arena-window-2026-10-18.md`; reviews `Docs/reviews/2026-10-18-arena-window.md`,
    `Docs/reviews/2026-10-18-single-window.md` and `Docs/reviews/2026-10-18-sidebar-rail.md`.
- §14 datasets is done and reviewed: `DatasetService` (preview, validate, build) with recipes, evidence-tier labels,
  grouping before splits and a split audit. Spec and evidence: `Docs/datasets-2026-09-27.md`; review
  `Docs/reviews/2026-10-18-datasets.md`.
- Git remote: `origin` = private GitHub repo `musterm4nn-alt/arena-suite`. Push only when asked.

## Open items

0. **Live check of the single-window build** (the user's own use of Arena). Sign-in and a battle
   already worked in the separate-window build. Still to check:
   - opening the site row (the sidebar should collapse to the rail);
   - the site's header bar over a real page (seen only with `--preview-site-header`);
   - switching to the archive and back while a battle generates;
   - Close Session;
   - whether Sync History archives that conversation.

   Record the results in `Docs/arena-window-2026-10-18.md`.
1. **A4, the 24-hour session check.** It is overdue (the last run was 2026-09-24). Ask the user to
   run:
   `open -n ~/Documents/arena-suite-opus/DerivedData/NativeAuthProof.app --args --phase0a`
   Then record in the Phase 0-A docs, `Docs/status.md` and the protocol ledger whether the saved
   session still verifies and whether cookies were re-issued.
2. **Plan §14 items.** The user gave the go decision on 2026-09-25 ("get started on the §14 items").
   Order: MCP (done), datasets (done), maintenance (next). Track B stays blocked (§1 condition 1).
   - read-only MCP (search, get conversation, export through ApplicationActions; no network
     actions, voting or reveal);
   - training/attribution datasets;
   - Track B generation (blocked by reCAPTCHA v3, N-004);
   - maintenance (selective purge with journal rewrite, reparse promotion/rollback, tiered
     verification).

3. **Known test gaps** (from the Phase 7 review; they are covered by reading only, not by tests):
   - a fault-injection test that changes accounts in the middle of a backup;
   - cancelling a backup mid-copy.

## User decisions that stay settled

- **Gate R (terms)** was decided by the user (`Docs/ADR/0005-product-scope.md`). Do not reopen it
  or add ToS caveats.
- **Multiple accounts in v1:** each is isolated, with its own session, Keychain item and journal.
- **Keychain:** keep the legacy login Keychain behavior (ACL-protected, not device-bound).
- **Font:** Departure Mono (departuremono.com), 11 pt body and 22 pt headings.
- **Voting/reveal:** Track B only, as manual user-clicked actions. Never automated, never exposed
  through MCP.
- **Signing:** use the Apple Development identity. It lives only in the git-ignored
  `Config/Signing.local.env` and `Config/Signing.local.xcconfig`.

## Hard constraints

- No CAPTCHA or anti-abuse bypass and no browser-token transfer.
- No WebView or browser runtime in the product, except the visible, user-driven embedded arena.ai
  (ADR 0006).
  - It has no injected scripts, no page, cookie or storage reads, no web view the user did not
    open and no user-agent change, and it stays outside the journal.
  - A session the user opened may keep its page while the archive is shown (like a background
    tab). The app never acts on it then.
  - `Scripts/check-boundaries.py` enforces the code rules.
- **Traffic policy:** sync is user-initiated, one request in flight per account, at least 1 s
  spacing. Stop on 403 or a challenge page; honor `Retry-After` once.
- **Never commit** credentials, cookies, passwords, the team ID, the email address or the signing
  hash. Before every commit, scan the staged diff against the git-ignored pattern file (never
  write these values into tracked files):
  `git diff --cached | grep -nIFf Config/secret-scan.local` — the output must be empty.
- **Screenshots:** capture only the Arena Suite window (`swift Tools/Dev/window_shot.swift
  "Arena Suite" out.png`, or `ArenaSuite` for Debug builds). Never capture the full screen, and
  never commit screenshots.
- **Telemetry:** Arena `metadata` stays out of the index, views and default exports. Exact raw
  bodies are shown or exported only after an explicit, confirmed action.
- Tests and tools that read the real archive must print counts, digests and paths only, never
  content.

## Working process (user instructions)

- Work phase by phase (`AGENTS.md`). State the acceptance criteria, implement, test, commit.
- **Reviews go to a different LLM than the author**, via opencode, run in the background:
  ```sh
  opencode run --standalone --model 'opencode/muse-spark-1.3-contributor-free#xhigh' --agent reviewer "<scope + focus>" > $TMPDIR/review.txt 2>&1
  ```
  - Always pass `--standalone`: without it, `opencode run` hung once.
  - The alternative reviewer model is deepseek v4.1 flash. On 2026-10-18 opencode reported
    `muse-spark-1.3-contributor-free` unavailable, and the datasets review used
    `opencode/deepseek-v4.1-flash-free#high` (that variant has no `xhigh`).
  - The agent definition is `.opencode/agents/reviewer.md`.
- After a review, fix every finding that holds up, write `Docs/reviews/<date>-<phase>.md`, and
  commit "Address independent review of …".
- **Then continue to the next phase without asking.** Exception: §14 items need the user's go
  decision first.
- Commit messages end with a `Co-Authored-By` line for the model that did the work.

## Commands

```sh
bash Scripts/test-offline.sh        # boundaries, core + adapter tests, golden journal, crash gate, harnesses
bash Scripts/build.sh Debug         # app → DerivedData/Build/Products/Debug/ArenaSuite.app
bash Scripts/package.sh             # signed Release → ~/Applications/Arena Suite.app (refuses while running)
# Opt-in:
ARENA_SUITE_REAL_ARCHIVE="$HOME/Library/Application Support/Arena Suite/Archive" \
  swift test --package-path Packages/ArenaProtocol --filter realArchive    # rebuild, exports, verify+backup on real data
ARENA_SUITE_REAL_ARCHIVE="$HOME/Library/Application Support/Arena Suite/Archive" \
  swift test --package-path Packages/ArenaProtocol --filter realArchiveDataset   # dataset counts only
ARENA_SUITE_SCALE_TEST=1 swift test --package-path Packages/ArenaProtocol --filter scale   # 10× synthetic history
ARENA_SUITE_KEYCHAIN_TESTS=1 swift test --package-path Packages/ArenaProtocol --filter Session       # real Keychain test
python3 Tools/FixtureHarness/audit_archive_journals.py                     # live journal audit (counts only)
```

Debug-only app flags:
- `--archive-root <path>`
- `--sync-on-launch`
- `--preview-conversation "<title prefix>"`, optionally with `--preview-export`
- `--preview-search <text>`
- `--preview-maintenance` (opens the Maintenance page and runs Verify)
- `--validate-dataset` (opens Maintenance and runs Validate Dataset)
- `--preview-accounts` (opens the Accounts page)
- `--preview-site-closed`, `--preview-site-header` (the first account's site pane without opening
  its session; the second draws the open page's header with no web view)

To test a clean install with the Release binary, point it at an empty home folder with
`CFFIXED_USER_HOME=<empty dir>`. Setting `HOME` does not redirect Application Support.

## Code map

- **`Packages/ArenaSuiteCore`:**
  - `SuiteDomain`: IDs, accounts, the archive vocabulary.
  - `CaptureJournal`: the ASJ1 journal (writer, reader, verifier, recovery, `JournalCopy`).
  - `ArchiveIndex`: GRDB/FTS5, `contentDigest`, `digestAndCheckpoints`, `datasetSource` (one frozen
    read for dataset builds).
  - `ApplicationActions`: `AccountService`, `HistorySyncService` (holds the maintenance
    exclusion), `JournalStore`, `ArchiveService` (projection, replay, `checkAgainstJournal`),
    `ExportService`, `TranscriptLayout`, `VerificationService`, `BackupService`,
    `DiagnosticsService`, `PrivateFile`, `DatasetRecipe`, `DatasetGrouping` (normalization,
    MinHash/LSH, union-find, label terms), `DatasetService`.
- **`Packages/ArenaProtocol`:**
  - `FoundationTransport`: per-account `URLSession`.
  - `ArenaAdapter`: sessions/Keychain, history routes and sync, `ArenaArchiveDecoder`. This is the
    only module that knows Arena routes.
  - Most integration tests live in `Tests/AdapterTests`.
- **`App/`:** SwiftUI. `ArenaWebPane.swift` is the only file that may import WebKit (ADR 0006).
  `Theme.swift` holds the font, the arena.ai-matched palette and the shared controls (`HeaderBar`,
  icon, row and pill styles). `MainView.swift` lays out the window; `SidebarView.swift` and
  `ArchivePane.swift` hold the sidebar and the archive.
  - `AppComposition.swift` is the only file allowed to import `ArenaAdapter`.
  - Also: the Accounts, Archive and Maintenance models and views, and `Theme`.
  - The Xcode project is hand-written. When adding a file, add both a `PBXFileReference` and a
    `PBXBuildFile` entry to `ArenaSuite.xcodeproj/project.pbxproj`.
- **Tools:** `Tools/NativeAuthProof` (Phase 0 research app, never linked), `Tools/CrashHarness`,
  `Tools/FixtureHarness`, `Tools/Dev/window_shot.swift`.
- **`Packages/ArenaSuiteMCP`:** `ArchiveMCP` (tools, JSON-RPC, `LineFramer`) and the
  `arena-suite-mcp` executable. It links ArenaSuiteCore only, opens the index with
  `ArchiveIndex(readingExistingAt:)` and `ArchiveService(readOnly:)`, and reads the registry with
  `loadWithoutTightening`. Build and install: `bash Scripts/build-mcp.sh`.
- **Boundaries:** `Scripts/check-boundaries.py` enforces the import rules, plus a self-tested deny-list
  of write and network APIs for the MCP module.

## Gotchas learned

- On this macOS, `JSONSerialization` keeps the first of duplicate keys.
- Arena list pages are ordered newest first by `updatedAt`. Timestamps are PostgreSQL text
  (`2026-09-24 10:00:00.123456+00`), parsed by `SourceInstant`.
- The legacy login Keychain ignores `kSecAttrAccessible`.
- `FileManager.removeItem` is recursive. Never remove a parent folder that is "probably empty";
  use `rmdir`.
- `JournalStore.root(for:)` is nonisolated. Projection has no suspension points inside the actor,
  so a rebuild cannot interleave with it.
