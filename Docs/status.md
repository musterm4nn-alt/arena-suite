# Current status

Single source of truth for where the project stands (plan v3 §17). Dated observation files in
`Docs/` are the evidence behind it; this page is replaced, not appended to.

Updated 2026-10-19.

| Phase | State | Notes |
|---|---|---|
| **0-A** Read-only feasibility | **Passed, one check pending** | A1–A3 and A5–A8 done (N-007…N-010, `Docs/phase0a-observation-2026-09-24.md`). Pending: A4's ≥24 h session check (rerun `--phase0a` on or after 2026-09-25). Accepted limitation: `agentic` entries are archived list-only until a detail route is observed. |
| **Gate R** Terms and account risk | **Done** | `Docs/ADR/0005-product-scope.md`. Updated 2026-09-24: multiple isolated accounts allowed in v1. |
| **1** Journal | **Done (offline), reviewed** | `CaptureJournal`, spec `Docs/journal-format-v1.md`, golden fixture + independent Python reader, 28 unit tests, SIGKILL crash gate (9 boundaries). Independent review findings all fixed: `Docs/reviews/2026-09-24-phase1-phase0a.md` |
| **2** Accounts & sessions | **Done, reviewed** | Live: 3 accounts restored after relaunch and rebuild (N-011). Review findings fixed: `Docs/reviews/2026-09-24-phase2.md`. Keychain: legacy login Keychain kept by decision (ACL-protected, not device-bound) |
| **3** History sync | **Done, reviewed** | Live: 3 accounts synced (57 entries, 51 archived), kill -9 mid-sync resumed with no refetch, incremental re-sync fetched nothing (N-012). `Docs/phase3-history-sync-2026-09-24.md` |
| **4** Decoding & index | **Done, reviewed** | Real archive: 57 conversations / 628 messages / 3 422 blocks; rebuild digest identical; 0 unknown fields (N-013). `Docs/phase4-index-2026-09-24.md` |
| **5** Native UI | **Done, reviewed** | Browse, transcript with lanes, offline search, evidence inspector; Departure Mono. `Docs/phase5-ui-2026-09-24.md` |
| **6** Exports | **Done, reviewed** | Raw/Normalized/Markdown; 306 real exports deterministic and telemetry-free (N-014). `Docs/phase6-exports-2026-09-24.md` |
| **7** Hardening & release | **Done, reviewed** | Verify job, backup/restore (equal archive on real data), content-free diagnostics, packaging to `~/Applications`, 10× scale test. `Docs/phase7-release-2026-09-24.md`, `Docs/release-notes-1.0.md`, review `Docs/reviews/2026-09-24-phase7.md` |
| §14 Read-only MCP | **Done, reviewed** | `arena-suite-mcp` (stdio): list, search, get, export through ApplicationActions over a read-only index; no network, no writes, telemetry masked. Live: 3 accounts / 57 conversations, all formats byte-equal to app exports. `Docs/mcp-readonly-2026-09-25.md`, review `Docs/reviews/2026-09-25-mcp.md` |
| §14 Datasets | **Done, reviewed** | Recipe-driven builds from the journal: message-scoped labels with evidence tiers (never identities), every exclusion reason, grouping before splits, independent split audit, deterministic private output. Real archive: 22 samples by default, 41 with requested selections, audits clean (N-015). `Docs/datasets-2026-09-27.md`, review `Docs/reviews/2026-10-18-datasets.md` |
| §14 Maintenance | Next | Go decision 2026-09-25 |
| Embedded arena.ai (ADR 0006) | **Built, reviewed; live sign-in and battle confirmed by the user** | arena.ai inside the one app window, user-driven, one web profile and at most one session per account, with no scripts and no page or cookie reads; it archives through the normal sync. The app's colors match arena.ai's dark theme, and the sidebar collapses to an icon rail as arena.ai's does (checked in the archive; collapsing on opening the site awaits the user's live check). Native generation is unchanged. Still to check live: the single-window build, and that Sync History archives a conversation made there. `Docs/arena-window-2026-10-18.md`, reviews `Docs/reviews/2026-10-18-arena-window.md`, `Docs/reviews/2026-10-18-single-window.md`, `Docs/reviews/2026-10-18-sidebar-rail.md` |
| App-wide UI rework | **Done, reviewed, approved by the user (2026-10-18)** | Layout modeled on the site: no system toolbar, header bars in the window's top band; the history in the sidebar grouped by date; an account switcher at the bottom; the transcript as a centered column with prompt bubbles and response cards; Accounts and Maintenance as pages. `Docs/ui-rework-2026-10-18.md`, review `Docs/reviews/2026-10-18-ui-rework.md` |
| Full-review fixes (2026-10-18) | **Done, reviewed (opencode: ready), pushed (`add9b4b`)** | All 11 defects from the user-supplied full review of `c731c85` confirmed and fixed with regression tests: backups refuse damaged journals, snapshot ownership and frozen historical views, re-auth by ID, rebuild replays every journal on disk, unproven listings are `partial`, sync auth outcomes reach the account, bounded MCP sequences, Keychain deletion failure kept visible, nested telemetry masked (decoder `arena-decoder/2`: one index rebuild), stale Latest refreshed. UI: durable sync failures with Sign In/Verify/Sync Again, and an Add Account first step. `Docs/review-fixes-2026-10-18.md`, `Docs/reviews/2026-10-18-full-review-fixes.md` |
| App icon (2026-10-19) | **Done, chosen by the user; pushed** | A miniature of the transcript in the app's palette (prompt bubble over the A and B cards, Departure Mono letters), an Icon Composer document with glass layers. The user rejected a coloured arch first. `App/Resources/AppIcon.icon`, generator `Tools/Dev/make_app_icon.py` |
| Insights (2026-10-19) | **Done, reviewed (opencode: ready, findings fixed); pushed** | A read-only page summarizing the user's own archive from the latest snapshot of each conversation: totals, activity by month, modes and kinds, accounts, "your votes" by outcome, and each model's record in those votes. Models are claims, not identity; records are the user's votes, not Arena's ranking; conflicting or missing claims are excluded and counted by reason. Only votes between two responses are decoded (the real archive has no other kind). Vote meanings are an assumption (N-016). `Docs/insights-2026-10-19.md`, review `Docs/reviews/2026-10-19-insights.md` |
| History filters (2026-10-19) | **Done, reviewed twice (opencode: ready; findings fixed, the last fix pass not re-reviewed); pushed** | Filters for the sidebar history and search: mode (including "not stated"), votes between two responses (with a vote, or no vote in the transcript; conversations known only from the list match neither), a claimed model, and update time as Arena reports it (past 7 or 30 days, past 12 months, a year). Menu counts are what each choice shows under the other filters. Active filters show as removable chips with "N of M shown". If the facets cannot be read, the vote and model filters are off and the bar says so. Insights' mode bars and model rows open the filtered history. Plan §11's mode and date filters. Shared model names across accounts: ledger N-017. `Docs/history-filters-2026-10-19.md`, review `Docs/reviews/2026-10-19-history-filters.md` |
| Track B Generation | Blocked | reCAPTCHA v3 (N-004). Starts only under plan §1 conditions |

## What needs you next

1. **A4 (overdue):** `open -n DerivedData/NativeAuthProof.app --args --phase0a` once more after
   ≥ 24 h, so the report shows whether the saved session still verifies and whether cookies were re-issued.
2. §14 is under way (go decision 2026-09-25). Track B stays blocked: plan §1 condition 1 is not met.
3. To use the MCP server: `bash Scripts/build-mcp.sh`, then register `~/.local/bin/arena-suite-mcp` with your MCP client.

## Signing

Research builds are signed with the identity in the git-ignored `Config/Signing.local.env`. Keychain
items created by a signed build survive rebuilds without prompts (N-009).

## Verification commands

```sh
bash Scripts/test-offline.sh      # everything offline, including the crash gate
bash Scripts/build.sh Debug       # app shell
bash Scripts/package.sh           # Release build, install/upgrade ~/Applications/Arena Suite.app
```
