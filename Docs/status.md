# Current status

Single source of truth for where the project stands (plan v3 §17). Dated observation files in
`Docs/` are the evidence behind it; this page is replaced, not appended to.

Updated 2026-10-18.

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
| arena.ai window (ADR 0006) | **Built, reviewed, live check pending** | A visible, user-driven arena.ai window, one web profile per account, with no scripts and no page or cookie reads; it archives through the normal sync. Native generation is unchanged. `Docs/arena-window-2026-10-18.md`, review `Docs/reviews/2026-10-18-arena-window.md` |
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
