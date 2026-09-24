# Offline foundation verification record

Initial checks ran 2026-09-20; continuation checks ran 2026-09-21. Environment is recorded
in `Config/toolchain.json`. These results are scoped to this host, not all supported macOS versions.

| Check | Result |
|---|---|
| Core package Swift Testing | 2 passed: immutable operation snapshot/rotation and pending engine status |
| Adapter package Swift Testing | 1 passed: all initial capabilities unknown without validation time |
| Python fixture tests | 3 passed, including all split points and 200 seeded partitions |
| Portable fixture validation | 1 synthetic fixture passed; zero authorized Arena fixtures available |
| Production import boundary check | Passed for 5 current production Swift files |
| Local HTTP/WebSocket transport experiment | Passed; measured limits in `transport-results.md` |
| Xcode Debug and Release builds | Passed, ARM64, macOS 14 deployment target |
| Release process launch smoke | Remained alive for 3 seconds; probe terminated its own process afterward |
| Release bundle signature verification | `codesign --verify --deep --strict` passed (local ad-hoc signing) |
| Release binary/bundle metadata | `lipo -archs`: arm64; `LSMinimumSystemVersion`: 14.0 |
| Locked dependency build/SQLite diagnostic probe | Passed with `--force-resolved-versions`; GRDB 7.11.1 + MCP 0.12.1 |

The launch smoke checks process startup only, not window appearance, accessibility, close-last-window,
or graceful shutdown behavior. At this offline checkpoint no authenticated Arena tests, macOS 14 runtime tests, parser tests,
durability tests, or MCP conformance tests are claimed.

Build diagnostics: harmless App Intents metadata extraction warning because the shell has no
AppIntents dependency; initial traditional-header-map warning was fixed by
`ALWAYS_SEARCH_USER_PATHS=NO`. Xcode reported disabling hardened runtime for the ad-hoc Debug build;
requested settings alone are not treated as proof of distribution-signing guarantees.

## Documentation cross-check on continuation

Context7 was unavailable at initial tool discovery and became available on 2026-09-21.
Queries against `/groue/grdb.swift/v7.11.1` confirmed the in-memory `DatabaseQueue()` API and
README requirements (macOS 10.15+, Swift 6.1+, Xcode 16.3+).
`/modelcontextprotocol/swift-sdk` confirmed the `MCP` product name but returned documentation
for 0.11.0+ from main, not a version-specific 0.12.1 contract. The pinned 0.12.1 Package.swift
was therefore checked directly: Swift tools 6.1, macOS 13.0 minimum. Actual local builds remain
the compatibility evidence. The dependency probe does not require raising the app's macOS 14 floor.

## Independent review

Initial reviewer invocation failed before producing findings (`ENOTFOUND chatgpt.com`).
Review on continuation found no Critical/High findings and two Medium findings:

1. Canonical plan and `AGENTS.md` were present but untracked in the new repository. Both existing
   files are now staged unchanged, so an initial checkout retains its architecture/instructions.
2. Missing WebSocket limit experiment. Added a 1 KiB configured limit, successful 512-byte
   fragmented message and rejected 2048-byte fragmented message, both in 64-byte frames.
   The first run established `NSPOSIXErrorDomain/EMSGSIZE`, rather than the initially anticipated
   URL error. The assertion now checks that measured domain/code; the targeted transport run passes.

Follow-up reviewer verdict: **offline foundation ready for this milestone**, with no remaining
Critical, High, or Medium correctness findings. **Full Phase 0 not ready**: live evidence and the
native proof are still outstanding. The reviewer inspected source/docs and relied on the reported
successful test/index checks; reviewer shell permissions prevented independent reruns.
Nonblocking test gaps noted by the reviewer: more fixture metadata/multistream negative cases,
explicit byte/header caps before broadening harness inputs, and import-guard mutation tests.

## Native-auth research preparation — 2026-09-21

After authorized browser observations B-001/B-002 and source inspection S-001, added the
disposable `Tools/NativeAuthProof` executable. This is a separate Phase 0 experiment, not the
Phase 4 account system or production recorded transport. No native live result existed at that checkpoint.

- `swift test --package-path Tools/NativeAuthProof`: 6 Swift tests passed, including parameterized
  status failures (5 cases), malformed identity shapes (4 cases), identity mismatch quarantine,
  successful-login-status insufficiency and concurrent sign-in exclusion.
- Full `bash Scripts/test-offline.sh`: passed, including the unchanged core/adapter tests,
  fixture checks, and loopback tests using the **actual native proof executor** for separate
  cookie ownership and refusal of credential-bearing redirects.
- `bash Scripts/build-auth-proof.sh`: ARM64 proof application built and ad-hoc signed;
  strict bundle signature verification passed.
- Browser research metadata excludes secrets and reports the initial monitor failure, retained
  request limit, identity-check script correction and browser-only continuity boundary.

Native-auth slice independent review: **ready for the authorized manual experiment**, with no
Critical/High/Medium correctness findings. The reviewer inspected code/docs but could not run
shell checks due to reviewer permissions. Full Phase 0 remains pending.
Nonblocking follow-ups: actual-executor fresh-session emptiness; POST 307/308 redirect cases;
independent mismatch tests for each identity claim; underlying-error sanitization regression;
manual password-clear/control/reset checks. Current tests do not claim these additional cases.

## First native rejection and diagnostic revision

N-001 records the user's screenshot of sign-in HTTP 401; its cause is unknown. No raw auth body
was preserved, and neither native identity nor authentication success was established.

The revised proof shows that the password field clears after a submission copy is taken, and
offers selected error fields in a hidden-by-default, local-only presentation. Request construction
is unchanged. `swift test --package-path Tools/NativeAuthProof`: **10 tests passed**, including
exact password copy/JSON preservation, value-free ordinary errors and redacted descriptions,
malformed/type-mismatched error shapes and inspection/presentation limits. The 64 KiB inspection
limit does not bound HTTP download allocation. `bash Scripts/build-auth-proof.sh` and signature
verification passed. No live request was made by these checks.

Reviewer verdict: **ready for one controlled diagnostic attempt**, no Critical/High/Medium
findings. Reviewer did not independently rerun tests. Additional exact size boundaries, stale
presentation reset and actual SwiftUI hide/reset checks remain nonblocking test gaps.

## Manual native authentication result — N-002/N-003

Subsequent user-supplied screenshots report successful native sign-in and identity HTTP 200,
then a second identity HTTP 200 with both ID claims unchanged. This passes the **initial
single-session native login/identity substep**, not the entire Phase 0 gate. N-001's 401 remains
unexplained. Screenshots are evidence of the UI result, not raw response fixtures. Actual private
emails/IDs are excluded from the research record. See `browser-auth-observation-2026-09-21.md`.

This update changes documentation only; the native executable/request recipe is unchanged.
No additional login was submitted by the agent. Native conversation, restore/refresh and actual
two-account tests remain pending; native/browser principal equality has not been established.

## 2026-09-22 — disposable generation probe (live acceptance pending)

- `bash Scripts/test-offline.sh`: passed; 2 core tests, 1 capability test, 15 native research
  tests (including parameterized rejection cases), loopback transport probes, 3 portable fixtures,
  and 3 fixture-validator tests.
- `bash Scripts/build-auth-proof.sh`: passed; `codesign --verify --strict` passed.
- Loopback native capture checks: callback reassembly/offsets/ticks, decoded gzip, interrupted
  prefix, explicit byte limit, fresh cookie jar, and POST 307/308 redirect refusal.
- Initial truncated-response test returned interruption with zero callbacks when no content type
  was supplied. The streaming fixture now explicitly supplies `text/event-stream` and allows
  prefix delivery before premature EOF. Foundation callback delivery is the measured boundary;
  bytes sent by the server but never delivered to the delegate cannot be claimed as captured.
- Browser C-001/C-002 create and follow-up observations and transformed fixtures are documented
  in `conversation-observation-2026-09-22.md`. No native generation has yet been submitted.
- Independent incremental review completed (`ses_f36b2c36affeM2a7VORas1pipc`): no Critical,
  High, or Medium findings; approved handoff for one manually initiated native experiment only.
  Reviewer could not independently rerun tests due to execution permissions.
- Two Low findings explicitly deferred for this no-cancel proof UI: caller cancellation does
  not propagate to the URLSession task, and generation preflight errors use a generic uncertain
  outcome message despite correct identity quarantine. Do not inherit these behaviors in the
  production transport. No Phase 0 completion or Phase 1 advancement is approved.

## N-004 — live native generation rejection

User screenshots show HTTP 403, complete transport, one callback and 39 retained bytes;
local preview shows `{"error":"recaptcha validation failed"}`. This is manual UI evidence,
not a raw exported fixture. The source-backed native null-token attempt failed; no retry was
performed by the agent. Initial native authentication success remains valid in its narrow scope.
Phase 0 is blocked/incomplete pending a legitimate native-compatible access contract.

## Read-only history probe — remaining Phase 0

User elected to hold generation and continue the remaining Phase 0 checks. H-001/H-002 record
browser-only list/detail evidence; native list acceptance is pending. The updated proof disables
generation and adds one identity-checked, read-only history list GET.

- `bash Scripts/test-offline.sh`: passed, including 18 native research tests, core/capability
  tests, loopback transport probes, three portable fixtures and fixture-validator tests.
- `bash Scripts/build-auth-proof.sh`, strict code-signature verification and `git diff --check`: passed.
- Independent history-only review (`ses_f36a2cc29ffeGuCYxK4KBAIMeU`): ready for this scoped
  milestone, no blocking findings. Its Low retention-wording finding is fixed: the summary now
  says captured bytes may be incomplete, with a capture-limit regression case. Reviewer could
  not independently rerun tests due to shell permissions. Native history acceptance remains pending.

## Research-proof hardening and publication checkpoint

The separate `code-review-2026-09-22.md` report was discovered before the first GitHub publication.
M1 (repeat login misdiagnosis) and M3 (default identity descriptions) are fixed with regressions.
M2 is fixed for the native executor: race-ordered task cancellation preserves delivered prefixes;
generation/history check cancellation after identity preflight. The old synthetic-only `observe`
helper retains its bounded timeout and remains outside production use. That portion of M2 is deferred.
Report Low findings remain follow-ups; an empty capture unit can describe an observed-but-unretained
callback, and no complete redirect evidence, stable persistent clock encoding, or product ownership
semantics are claimed by this proof.

Full offline suite passed with 20 native research tests and real loopback cancellation-prefix and
pre-start-cancellation checks. Reviewer `ses_f369d57a4ffeUUkhFZMVx95HZc` approved the increment
with no blocking findings (source inspection; independent shell execution unavailable). Its
nonblocking test follow-ups are deterministic callback handshaking, server counts for pre-cancel,
and cancellation race stress. Cancellation is local interruption, never confirmed remote stop.

## H-001 portable list projection

Added the reviewed, explicitly transformed `history-list.fixture.json`, retaining only minimal
entry structure and observed page-status fields. Full offline script passed: 21 native research
tests, four portable fixtures and existing transport/manifest checks. Reviewer
`ses_f3697f0caffe7dVTzh4jsCJzSU` approved the scoped increment with no blocking findings.
Native history remains pending. Initial commit `d1b94b5` is local; pushing to the configured
GitHub origin was denied by the tool permission layer, so no publication success is claimed.

## Native restoration experiment — implementation verification

The user authorized one-slot macOS Keychain session cookies and automatic read-only history
checks. Implementation is described in `native-restoration-experiment.md`; password persistence
and generation remain excluded.

- Full offline suite passed: 27 native research tests, core/capability tests, loopback transport
  and cancellation checks, four portable fixture manifests and three fixture-validator tests.
- Proof app build and strict code-signature verification passed; `git diff --check` passed.
- Tests use an in-memory session store and synthetic cookie material. Real Keychain save,
  restored `/api/me`, native history and actual relaunch acceptance are still pending.
- The initial restoration-review invocation hit its usage limit. Replacement reviewer
  `ses_f2e6ef33bffeBB0vvJOx350DI6` approved publication of the bounded experiment on 2026-09-24
  with no blocking findings. Independent shell tests/diff inspection were unavailable; source
  was inspected directly. Live save/relaunch/forget, injected storage failures, cancellation
  transitions and diagnostic-sentinel tests remain follow-ups before a restoration-success claim.
- The explicitly requested GitHub push was retried on 2026-09-24 and again denied by the tool
  permission layer. Commits remain local until that permission is granted or the user pushes them.

## N-005/N-006 — live history and same-build restoration

On 2026-09-24 the user signed in once, then the agent read the automatic native history summary:
HTTP 200, complete, 4811 bytes, 14 entries, hasMore=false, partial=false, zero failed sources.
After normal app quit and an empty matching-process check, relaunch produced a different run ID
and the same summary without another manual login. See `native-history-restoration-2026-09-24.md`.
Reviewer `ses_f2da7e449ffefa1eB5MAMD3JEP` approved this documentation-only checkpoint; its Low
superseded-status finding was corrected. No code changed and no tests were rerun for these notes.
Earlier three commits have now been pushed successfully to origin/main; push permission was resolved.

## Native detail probe — implementation checks

Added a bounded identity-checked list/detail experiment using H-002's observed route and an ID
from the fresh native list. The automatic flow reports relationship counts/match flags only.
Full offline suite passed with 31 native research tests, existing loopback probes, four fixture
manifests and three fixture-validator tests. Proof build, strict signing check and diff whitespace
check passed. Independent review and live detail acceptance remain pending at this checkpoint.
