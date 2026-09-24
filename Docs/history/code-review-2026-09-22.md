# Code review report for arena-suite-astra model — 2026-09-22

Target reader: `ses_f4005fe79ffeUk7ORH4o7ckDlH` (`arena-suite-astra`, `openai/gpt-6-astra/medium`).
Reviewer: independent review from `ses_f37a60887ffellO5cKX4y7kpCs`.
Scope: Phase 0 offline foundation + disposable `Tools/NativeAuthProof` as staged on disk 2026-09-22.
Baseline verified by reviewer: `Scripts/check-boundaries.py` passes (5 files); `Packages/ArenaSuiteCore` 2 tests pass; `Packages/ArenaProtocol` 1 test pass; `Tools/NativeAuthProof` 15 tests pass.

Session `ses_f4005fe79ffeUk7ORH4o7ckDlH` (209 messages) was read. It does not discuss the items below. Its known reviewer gaps were different: untracked canonical files, WS limit experiment, plus nonblocking follow-ups in `Docs/verification-results.md` (fresh-session emptiness, POST 307/308, per-claim mismatch, error sanitization, password-clear checks).

No Critical findings. Do not promote any production capability; full Phase 0 gate remains pending.

## M1 — Misleading error on second signIn
File: `Tools/NativeAuthProof/Sources/NativeAuthResearch/NativeAuthClient.swift:68`

Current:
```swift
guard !quarantined && identity == nil else { throw ResearchFailure.identityMismatch }
```

Second `signIn()` after success throws `identityMismatch`, same as principal-forgery quarantine. Conflates caller bug with security event.

Fix: add distinct case, e.g. `ResearchFailure.alreadyAuthenticated`, throw it when `identity != nil && !quarantined`. Keep quarantine path for `quarantined == true`. Update `NativeAuthProofApp.swift:177` `message(for:)` and add test: signIn OK then second signIn asserts `alreadyAuthenticated`, `requests.count` unchanged.

## M2 — No Task-cancellation handler on continuations
Files: `Tools/NativeAuthProof/Sources/NativeAuthResearch/NativeHTTPExecutor.swift:132`, `Tools/FixtureHarness/Sources/TransportProbe/Probe.swift:85`

Current uses `withCheckedThrowingContinuation` with no cancellation path. Cancelled caller hangs until 20s/30s timeout; `URLSessionDataTask` keeps running.

Fix: wrap with `withTaskCancellationHandler`, cancel task on cancellation, ensure delegate still resumes with `.interrupted`. Add test with cancelled `Task` asserting prompt resume and no hang. Research-only, bounded timeouts acknowledged, but fix before reuse in product transport.

## M3 — ObservedIdentity logs PII by default
File: `Tools/NativeAuthProof/Sources/NativeAuthResearch/NativeAuthClient.swift:13`

`ObservedIdentity` has synthesized description; `print(identity)` leaks id/supabaseUserID/email. `LocalAuthError:21` already redacts via `LocalAuthError(redacted)`.

Fix: add redacted `CustomStringConvertible/CustomDebugStringConvertible` to `ObservedIdentity` (and audit `HTTPReply.body: Data` logging). Add test asserting `String(describing:)` does not contain marker IDs, mirroring `localErrorNeverEscapesThroughOrdinaryFailureOrDescription`.

## L1 — Capture-limit edge creates empty unit
File: `Tools/NativeAuthProof/Sources/NativeAuthResearch/NativeHTTPExecutor.swift:76`

When `body.count == maximumBodyBytes` exactly, next callback appends `Unit(offset:max, bytes:empty, observedLength:N)` then sets `limited=true`. Callback-count limit also discards entire triggering chunk, unlike byte-limit partial retention.

Fix: skip appending zero-length unit, still count `observed`, set `limited=true`, cancel. Document asymmetry or retain partial chunk for count-limit. Add tests: fill-to-cap exactly, then one more byte; assert no empty unit and `observedByteCount` correct.

## L2 — HTTPReply omits redirect evidence
File: `Tools/NativeAuthProof/Sources/NativeAuthResearch/NativeHTTPExecutor.swift:15`

`willPerformHTTPRedirection` refuses with `nil` but reply has no `redirects` count. Caller sees `302` but cannot prove target unhit from reply. Probe `Collector:20` does record it.

Fix: add `redirects: Int` to `HTTPReply`, increment in delegate, surface in `NativeAuthProofApp` generation view if desired. Test 302/307/308 refusal asserts `status` + `redirects==1` + target unhit.

## L3 — Capabilities keyed by String
File: `Packages/ArenaProtocol/Sources/ArenaAdapter/Capabilities.swift:29`

`func capabilities(for:) async -> [String: CapabilityAssessment]` permits typo keys. Use `[Phase0Capability: CapabilityAssessment]` or typed struct. Add test for exhaustive keys.

## L4 — Engine owned by App value type
File: `App/ArenaSuiteApp.swift:12`

`private let engine = ArenaSuiteEngine()` in `App` struct may be recreated with struct value; `.task` may re-run. Harmless now (stateless actor), breaks when engine gains state. Fix: stable owner (e.g. `@State` holder object) or document intentional recreation. No behavior change required for Phase 0.

## L5 — Evidence date encoding unpinned
File: `Packages/ArenaSuiteCore/Sources/SuiteDomain/Evidence.swift:17`

`observedAt: Date?` relies on `JSONEncoder` default `.deferredToDate`. Round-trips locally but not portable/stable. Pin `.iso8601` with fractional seconds or explicit `secondsSince1970` in encoder/decoder used for persistence, add round-trip test with fixed date.

## L6 — Swift version skew
File: `Config/Debug.xcconfig:4`

`SWIFT_VERSION=6.0` vs `Package.swift` `swift-tools 6.1` / toolchain Swift 6.4 in `Config/toolchain.json`. Builds today, but intent unclear. Align to 6.1 or document why app target stays 6.0 while packages use Swift 6 language mode.

## L7 — Research URLs lack per-line ledger link
Files: `Tools/NativeAuthProof/Sources/NativeAuthResearch/NativeAuthClient.swift:74,135`, `Tools/NativeAuthProof/Sources/NativeAuthResearch/GenerationProbe.swift:26`

File-level `B-001/S-001/C-001` coverage exists, but literals have no adjacent comment. Add `// B-001/S-001` etc. per URL. No behavior change; aids `check-boundaries.py` audit which currently exempts `Tools/`.

## Suggested order
1. M1 + test, M3 + test.
2. L2 + L1 + tests (evidence quality).
3. M2 cancellation.
4. L3, L5, L6, L7, L4 docs/small fixes.
5. Re-run `bash Scripts/test-offline.sh`, `bash Scripts/build.sh Debug/Release`, `bash Scripts/build-auth-proof.sh`, request `reviewer` subagent.
