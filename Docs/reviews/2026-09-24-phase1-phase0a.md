# Review — Phase 1 journal and Phase 0-A proof (2026-09-24)

Reviewer: opencode `reviewer` agent, model `opencode/muse-spark-1.3-contributor-free#xhigh`,
session `ses_f2d42a3baffeldnx5ZMq4DXrmP`. Scope: `git diff 100f17f..99c158d` (reviewed as `51a3243` before the history rewrite noted below).
The reviewer saw the actual diff and ran both Swift test suites itself; its permissions blocked the
crash gate and the Python golden checker (both run in `Scripts/test-offline.sh`, passing).

Verdict: **not ready** → all findings addressed below; full offline suite passes afterwards.

| Severity | Finding | Resolution |
|---|---|---|
| High | Fixture `[string:<length>]` markers leak lengths of private/telemetry strings | Sanitizer v2 withholds all lengths (`[string]`); fixture regenerated; test asserts no `[string:` and checks the fixture's SHA-256 |
| High | `0700`/`0600` only applied when creating, not to existing paths | `enforcePrivatePermissions()` on every open (refuses symlinks, fails closed); test pre-creates `0755`/`0644` |
| Medium | `quarantine/*.tmp` never cleaned, invisible to verifier | Recovery removes and reports them; verifier flags them; test |
| Medium | Directory syncs never used `F_FULLFSYNC` | `synchronizeDirectory(full:)` threaded through seal, segment create, close |
| Medium | No concurrent-append test | `concurrentAppendsStayContinuous` (8 tasks × 50) |
| Medium | Faults during seal / manifest write / segment-create dir sync untested | Three fault-injection tests; writer fails closed, reopen recovers and verifies clean |
| Low | Forward compatibility with unknown envelope keys untested | Test with a hand-built future record: verifies clean, bytes preserved |
| Low | Apple team ID in docs | Removed from docs; identity stays in git-ignored `Config/Signing.local.env` |
| Low | `limit` bound 1…100 could read as an observed server limit | Comment: client guard only; observed values 5 and 20 |
| Low | Fixture hashes not self-checked | Covered by the High fix's test |
| — | Spec/code drift in quarantine file naming | Spec corrected |

History: on 2026-09-24, at the user's request, the length-free fixture (and the team-ID-free doc line) were
folded into the Phase 0-A commit before any push. Old → new hashes: `51a3243` → `99c158d`,
`9009421` → `c4a496b`, `b878007` → `fa8509f`, `b6d2983` → `57c7e22`. No reachable commit contains the
length-bearing fixture.
