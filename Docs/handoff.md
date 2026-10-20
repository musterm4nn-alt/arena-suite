# Session handoff

Read this first in a new session, then `Docs/status.md`, `AGENTS.md` and
`Arena-Suite-Master-Plan-v3.md`. This file is replaced, not appended to.

Updated 2026-10-20, after unfinished conversations and Refresh, and the site's account tabs. Both are committed locally, as is the ledger commit before them (N-019/N-020); none of the three is pushed. The vote notes were pushed. The app icon, the Insights page and the history filters were pushed at the user's request on 2026-10-19.

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
- **Full-review fixes** (`Docs/review-fixes-2026-10-18.md`): the 11 defects of the user-supplied
  review of `c731c85` are fixed with regression tests, plus its two UI priorities. A second model
  reviewed it ("ready", `Docs/reviews/2026-10-18-full-review-fixes.md`) and its findings are fixed.
  Pushed as `add9b4b` at the user's request.
  - `ArchiveService.rebuild(accounts:)` is gone: a rebuild always replays every journal.
  - `VerificationService`'s account closure throws; a failure sets `inventoryProblem`.
  - The decoder is `arena-decoder/2`: the first launch of the new build rebuilds the index once.
  - An explicit snapshot is a frozen view (`ConversationDetail.isFrozen`); `snapshot: nil` is live.
    Exports always render the frozen view of one sequence.
  - Sync failures set the account's state through `SyncManifest.sessionState` (guarded by the
    credential generation).
- **New features (user request 2026-10-19: "design, develop, implement new features and
  improvements").** Each is a milestone with a doc, tests and a second-model review. Pushing needs
  the user's OK; the icon, Insights and the history filters were pushed on 2026-10-19.
  - **App icon:** done, chosen by the user (see the code map).
  - **Insights** (`Docs/insights-2026-10-19.md`): a sidebar and rail entry opening a read-only
    summary of the archive. `ArchiveIndex.insightsSource` (one read), `ArchiveInsights.build`
    (pure), `InsightsService`, `App/InsightsView.swift`. The vote vocabulary lives in the adapter
    (`ArenaArchiveDecoder.voteVocabulary`, N-016) and reaches the service through composition.
  - **History filters** (`Docs/history-filters-2026-10-19.md`, review
    `Docs/reviews/2026-10-19-history-filters.md`): mode, votes, claimed model and update time, for
    the sidebar history and search.
    - Code: `HistoryFilter`, `HistoryFacets`, `HistoryFilterOptions` and `SearchSummary` in
      ApplicationActions; `ArchiveIndex.historyFacetSource`; `HistoryFilterBar` in
      `SidebarView.swift`. Insights' links go through `MainView.showHistory`.
    - Semantics to keep: list-only conversations match neither vote choice; unreadable facets turn
      the vote and model filters off (never guessed); menu counts are taken under the other active
      filters. Filters are not saved.
  - **Export options** (`Docs/export-options-2026-10-20.md`): "Last answer, with its prompt"
    (`ExportService.lastAnswer(of:)`, from Arena's recorded `lastMessageIds`), copy to the
    clipboard, and JSONL. `ExportPopover` in `ArchivePane.swift` (⇧⌘E). MCP is unchanged.
    Review: `Docs/reviews/2026-10-20-export-options.md`.
    - Semantics to keep:
      - a listed message's parent that the snapshot lacks is named (`parents_not_in_snapshot`),
        never dropped silently;
      - an empty, dangling or unreadable list is refused, each with its own error;
      - ordinals stay whole-snapshot positions;
      - claims of unknown subject kinds are kept;
      - JSONL escapes U+0085, U+2028 and U+2029;
      - the app's notice (`exportOutcome`) concerns the snapshot shown. It is cleared when that
        changes; a late copy or refusal is dropped, and a saved file's notice names its file;
      - export is offered only once the chosen snapshot (or Latest) is the one on screen.
    - `wholeConversationExportsAreUnchanged` pins whole-conversation Normalized JSON and Markdown.
      Update its hashes only for a deliberate format change.
  - **Encrypted backup** (`Docs/encrypted-backup-2026-10-20.md`, review
    `Docs/reviews/2026-10-20-encrypted-backup.md`): the plain backup folder sealed into one Apple
    Encrypted Archive (`.aea`, scrypt + AES-CTR + HMAC-SHA256 via Apple's AppleArchive framework),
    keyed by a passphrase the user chooses and that is never stored. The user chose the passphrase
    on 2026-10-20. macOS's `aea` and `aa` open it without the app (the doc has the commands).
    - Code: `EncryptedBackup.swift` (an extension of `BackupService`); the Maintenance row
      "Encrypted Backup…" and `PassphraseSheet` in `MaintenanceView.swift`. Check Backup and
      Restore accept a folder or an `.aea` file.
    - Semantics to keep:
      - the passphrase is NFC-normalized, 20 characters to 256 UTF-8 bytes (AEA's own limits);
      - plaintext outside the archive exists only in the user's private temporary directory: the
        plain copy (`arena-suite-plain-backup-*`) and the replay folder every backup check uses
        (`arena-suite-replay-*`). They are removed on success, failure and cancellation; a crash
        can leave them until the next backup (or check or restore, for replay folders) sweeps
        them, once older than an hour;
      - restore sets an existing empty account list aside in one rename before checking it
        (`BackupService.install`), so an account added meanwhile is never removed. A crash
        between the renames leaves `.previous-accounts-*`. `recoverSetAsideAccounts` runs at
        launch (`AppComposition.makeServices`) and before a restore: with no `accounts`, it puts
        one back (one holding accounts first), removes empty ones, and keeps anything else.
        Maintenance names what is kept (`keptAccountLists`), and `canRestore` is false while
        any remains;
      - the recovery recipe in the doc normalizes the passphrase to NFC with Perl.
        `macOSToolsOpenAnEncryptedBackup` reads the block from the doc and runs it, so editing
        the block changes the test;
      - the file appears only when complete (staging, full sync, `RENAME_EXCL`);
      - `wrongPassphraseOrDamaged` means decryption could not start; once it starts the passphrase
        is right, and a later decoding failure is `encryptedContentDamaged` unless the file cannot
        be read again to its end, or writing on this Mac failed (both `io`);
      - only directories and regular files with safe relative paths are written, each new and
        owner-only.
    - The boundary check allows `AppleArchive` and `System` in ApplicationActions (Apple system
      frameworks, not dependencies).
  - **Local vote notes** (`Docs/vote-notes-2026-10-20.md`, review `Docs/reviews/2026-10-20-vote-notes.md`):
    item 6 of the gap analysis. A note beside a vote Arena recorded ("A is better", "B is better",
    "Tie", "Both are bad", or removed), kept only in this archive and never sent to Arena. It is not
    a vote: no transport, nothing pre-selected, no MCP path (the boundary script's MCP deny-list
    names notes and `local.control`).
    - Format: the first `local.control` record (plan §7), type `vote_note` version 1, payload
      `local_control_json` with IDs and the choice only. `LocalControl` (ApplicationActions)
      writes and decodes it; ArenaAdapter never sees it. Unknown or malformed local records become
      warnings that never repeat IDs.
    - Write path: `VoteNoteService.set` checks that the vote, exactly as recorded, is in the named
      snapshot of that account's conversation. `HistorySyncService.appendLocal` refuses during
      maintenance, holds maintenance off while it writes, refuses accounts not in the app, and
      flushes. The account is then projected. The app takes the account, conversation and snapshot
      from the transcript the menu is in, never from the selection.
    - Index: migration `v2` adds `vote_notes`; tables added after v1 enter the content digest only
      when they hold rows, and `meta.local_control_version` is stored only once a local record is
      projected. Both keep the digest of archives without notes, so backups made before still pass
      their check (`archiveWithoutNotesKeepsItsDigest` pins a digest computed at `544194b`). A
      different stored local version rebuilds the index.
    - Not in exports, Insights or filters (a test pins that). Known limit: removing an account at
      the instant its note is written can add that note to the removed account's kept journal.
  - **Unfinished conversations and Refresh** (2026-10-20, `Docs/sync-refresh-2026-10-20.md`):
    found while observing attachments. A battle synced mid-generation kept `pending` responses and
    missed the later vote, because the history list didn't change (N-020). Sync now fetches again
    a conversation whose latest snapshot is unfinished (at most 3 unfinished snapshots in a row
    per `updatedAt`; unlisted ones by ID, their type and `updatedAt` marked `last_listed`). A
    user-clicked Refresh in the transcript header runs a `conversation_refresh` job: identity, then
    one detail. The `pending` vocabulary is `ArenaArchiveDecoder.unfinishedStatuses`. Entries
    listed without `updatedAt` keep the always-fetch rule (none in the live archive). Review:
    `Docs/reviews/2026-10-20-sync-refresh.md` (three runs; the third found it ready). Not yet run
    against Arena: after installing, the user's next Sync History fetches their 3 unfinished
    conversations again (counted in the live archive on 2026-10-20).
  - **Site account tabs and the rail's border** (2026-10-20, from the user's notes;
    `Docs/arena-window-2026-10-18.md`, fourth iteration): one tab per account in the app after the
    site's navigation buttons (the app can't tell which profiles are signed in); a click goes
    through `openSite`, as the sidebar does; tabs scroll when they don't fit. With the rail, the
    sidebar's border starts below the window buttons. Review: `Docs/reviews/2026-10-20-site-tabs.md`
    (two runs; the second found it ready). A tab click wasn't tried by the author (it loads the site).
  - **Attachments, observed** (N-019): links are S3 presigned R2 URLs signed when Arena serves the
    detail, valid 3600 s. One fresh link downloaded natively without cookies (200, type and length
    as declared). Downloading must follow a detail fetch within the hour; whether an object keeps its
    path across fetches and whether the `ETag` is its MD5 are not yet observed. The probe scripts
    were scratch-only.
  - **Next, from the user's gap analysis** (`Docs/arena-exporter-gaps-2026-10-19.md`, "Closing the
    gaps", in order):
    1. attachment downloads (plan §9.4), on top of the refresh: download right after each detail
       fetch, content-addressed under `objects/sha256/`, with expired/denied/unavailable states;
    2. Agent detail (observe a native detail route in `Tools/NativeAuthProof` first).

    Import of arena-exporter folders (the second half of item 7) is not to be built: the user
    chose "Skip import" on 2026-10-20. GitHub backup stays a separate decision: it sends private
    conversations off the Mac.

    Items 3–5 of the analysis (failed requests, stream evidence, requested model) need the page
    read live, which ADR 0006 rules out. Still pending from the earlier announcement: bulk export
    of the filtered history and a clearer Maintenance page.
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
   - cancelling a backup mid-copy;
   - `ArchiveModel`'s refresh after projection (there is no app test target).
4. **Journal recovery and mid-segment damage.** On open, recovery quarantines everything after
   any damage in the final segment, including complete, acknowledged records, and reuses their
   sequence numbers. It should refuse that case, as backups now do. Offered to the user as a
   separate task (2026-10-18). The second-model review rated it High: fix it before claiming
   "replay gives identical hashes" for a journal that went through recovery. Its proposed fix and
   test are in `Docs/reviews/2026-10-18-full-review-fixes.md`.
5. **From the full review, not done:** a CI workflow (needs a macOS runner with this toolchain),
   the Maintenance action hierarchy, and showing the dataset audit's LSH limit more prominently.

## User decisions that stay settled

- **Gate R (terms)** was decided by the user (`Docs/ADR/0005-product-scope.md`). Do not reopen it
  or add ToS caveats.
- **Multiple accounts in v1:** each is isolated, with its own session, Keychain item and journal.
- **Keychain:** keep the legacy login Keychain behavior (ACL-protected, not device-bound).
- **Font:** Departure Mono (departuremono.com), 11 pt body and 22 pt headings.
- **Voting/reveal:** Track B only, as manual user-clicked actions. Never automated, never exposed
  through MCP.
- **arena-exporter import:** not built (user, 2026-10-20). Its files are that extension's
  reading of the page, not Arena's responses.
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
ARENA_SUITE_REAL_ARCHIVE="$HOME/Library/Application Support/Arena Suite/Archive" \
  swift test --package-path Packages/ArenaProtocol --filter realArchiveInsights  # insights counts only
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
- `--preview-passphrase [<file>.aea]` with `--preview-maintenance` (opens the new-backup passphrase
  sheet, which writes into the temporary directory if submitted; with a file, the sheet that
  checks it)
- `--validate-dataset` (opens Maintenance and runs Validate Dataset)
- `--preview-accounts` (opens the Accounts page)
- `--preview-insights` (opens the Insights page)
- `--preview-filter "<mode>"` (filters the history to that mode and to conversations with a vote)
- `--preview-export-popover` with `--preview-conversation` (opens the export popover; preset its
  choices with `-exportScope last-answer -exportFormat jsonl`)
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
  `ArchivePane.swift` hold the sidebar and the archive; `InsightsView.swift` the Insights page
  (charts drawn with SwiftUI shapes: the app does not link Charts). `ArchiveModel.revision`
  changes on every reload, so pages built from the index reload after a sync, rebuild or restore.
  - `AppComposition.swift` is the only file allowed to import `ArenaAdapter`.
  - Also: the Accounts, Archive and Maintenance models and views, and `Theme`.
  - The Xcode project is hand-written. When adding a file, add both a `PBXFileReference` and a
    `PBXBuildFile` entry to `ArenaSuite.xcodeproj/project.pbxproj`.
- **Tools:** `Tools/NativeAuthProof` (Phase 0 research app, never linked), `Tools/CrashHarness`,
  `Tools/FixtureHarness`, `Tools/Dev/window_shot.swift`.
- **App icon:** `App/Resources/AppIcon.icon`, an Icon Composer document (SVG layers, glass) that
  actool compiles into `Assets.car` plus an `.icns` for macOS 14–25. It is a miniature of the
  transcript in the app's palette: your prompt bubble above the A and B response cards, with the
  lane letters set in Departure Mono. The user chose this direction on 2026-10-19 over a coloured
  arch, which "didn't suit the theme". Regenerate it with
  `python3 Tools/Dev/make_app_icon.py App/Resources/AppIcon.icon` (it uses
  `Tools/Dev/glyph_paths.swift`), and preview it with Icon Composer's `ictool` (usage in the
  script).
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
- Never keep an array index across an `await` in an actor: other calls run during the suspension
  (`AccountService.signInAgain` updated the wrong account until 2026-10-18).
- A returned `SyncManifest` can be a failure (`needsSignIn`, `blocked`, `partial`, …); only thrown
  errors used to reach the UI.
- `JournalStore.root(for:)` is nonisolated. Projection has no suspension points inside the actor,
  so a rebuild cannot interleave with it.
