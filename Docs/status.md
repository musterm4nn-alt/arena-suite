# Current status

Single source of truth for where the project stands (plan v3 §17). Dated observation files in
`Docs/` are the evidence behind it; this page is replaced, not appended to.

Updated 2026-09-24.

| Phase | State | Notes |
|---|---|---|
| **0-A** Read-only feasibility | In progress — needs you | Done: native login, identity, same-build restore, one history page, one conversation detail (N-002/N-003, N-005/N-006, N-007). Open: A2–A8 in plan §4. A1 ran live on 2026-09-24 (see `Docs/native-detail-observation-2026-09-24.md`); the detail fixture (A8) is still pending. |
| **Gate R** Terms and account risk | **Done** | Decision recorded in `Docs/ADR/0005-product-scope.md` (read-only client accepted at user's own risk; plan §2 limits confirmed). Settled for v1 and Track B; re-open only on material terms change or Arena contact. |
| **1** Journal | **Done (offline)** | `CaptureJournal` module, format spec `Docs/journal-format-v1.md`, golden fixture checked by an independent Python reader, 21 unit tests, SIGKILL crash gate (9 boundaries) |
| 2 Accounts & sessions | Not started | Needs A4–A7 results for refresh/expiry and signing |
| 3 History sync | Not started | Needs A1–A3 |
| 4 Decoding & index | Not started | GRDB 7.11.1 pinned in `Tools/DependencyProbe` |
| 5 UI · 6 Exports · 7 Release | Not started | |
| Track B Generation | Blocked | reCAPTCHA v3 (N-004). Starts only under plan §1 conditions |

## What needs you next

1. **A6 (optional but recommended):** say whether you have an Apple Development signing identity.
   With one, Keychain restore survives rebuilds; without one, expect to sign in again after each rebuild.
2. **A7:** say whether you have a second Arena account you are willing to use for the isolation test.

## Verification commands

```sh
bash Scripts/test-offline.sh      # everything offline, including the crash gate
bash Scripts/build.sh Debug       # app shell
```
