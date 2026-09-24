# Current status

Single source of truth for where the project stands (plan v3 §17). Dated observation files in
`Docs/` are the evidence behind it; this page is replaced, not appended to.

Updated 2026-09-24.

| Phase | State | Notes |
|---|---|---|
| **0-A** Read-only feasibility | **Passed, one check pending** | A1–A3 and A5–A8 done (N-007…N-010, `Docs/phase0a-observation-2026-09-24.md`). Pending: A4's ≥24 h session check (rerun `--phase0a` on or after 2026-09-25). Accepted limitation: `agentic` entries are archived list-only until a detail route is observed. |
| **Gate R** Terms and account risk | **Done** | `Docs/ADR/0005-product-scope.md`. Updated 2026-09-24: multiple isolated accounts allowed in v1. |
| **1** Journal | **Done (offline), reviewed** | `CaptureJournal`, spec `Docs/journal-format-v1.md`, golden fixture + independent Python reader, 28 unit tests, SIGKILL crash gate (9 boundaries). Independent review findings all fixed: `Docs/reviews/2026-09-24-phase1-phase0a.md` |
| **2** Accounts & sessions | **Done, reviewed** | Live: 3 accounts restored after relaunch and rebuild (N-011). Review findings fixed: `Docs/reviews/2026-09-24-phase2.md`. Keychain: legacy login Keychain kept by decision (ACL-protected, not device-bound) |
| **3** History sync | **Done, reviewed** | Live: 3 accounts synced (57 entries, 51 archived), kill -9 mid-sync resumed with no refetch, incremental re-sync fetched nothing (N-012). `Docs/phase3-history-sync-2026-09-24.md` |
| **4** Decoding & index | **Done, reviewed** | Real archive: 57 conversations / 628 messages / 3 422 blocks; rebuild digest identical; 0 unknown fields (N-013). `Docs/phase4-index-2026-09-24.md` |
| **5** Native UI | **Done, reviewed** | Browse, transcript with lanes, offline search, evidence inspector; Departure Mono. `Docs/phase5-ui-2026-09-24.md` |
| 6 Exports · 7 Release | Next | |
| Track B Generation | Blocked | reCAPTCHA v3 (N-004). Starts only under plan §1 conditions |

## What needs you next

1. **A4 (tomorrow or later):** `open -n DerivedData/NativeAuthProof.app --args --phase0a` once more after
   ≥ 24 h, so the report shows whether the saved session still verifies and whether cookies were re-issued.
2. Nothing else blocks Phase 2.

## Signing

Research builds are signed with the identity in the git-ignored `Config/Signing.local.env`. Keychain
items created by a signed build survive rebuilds without prompts (N-009).

## Verification commands

```sh
bash Scripts/test-offline.sh      # everything offline, including the crash gate
bash Scripts/build.sh Debug       # app shell
```
