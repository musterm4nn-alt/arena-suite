# Phase 0 execution plan and gate

## Scope and acceptance criteria

This session implements the **offline Phase 0 foundation**, following master-plan sections
18–19 and handoff steps 1–4. Section 18 puts durable journal format/codec/clock/ID architecture
in Phase 1. The small account/evidence types here serve the feasibility boundary; they do not
implement a registry, credential store, production transport, parser, or archive.

1. Build baseline: two local packages, Swift 6, ARM64 macOS 14 app target, Debug/Release;
   compile both packages and app; freeze each operation's account snapshot; unknown capabilities.
2. Evidence tooling: classify evidence, pin exporter research, define ledger and fixture format;
   reject corrupt/gapped/mislabeled fixtures; reassemble opaque bytes across arbitrary partitions;
   measure Foundation against known local HTTP and WebSocket server output.
3. Handoff: ADRs, capture boundary, explicit live checklist, exact dependency lock and license inventory;
   independent reviewer examines all added files; fix Critical/High and correctness-relevant Medium findings.

Initial inventory: planning/config files only, no Git repository, tests, source, credentials, or
authorized Arena fixture corpus. Initialized local Git on `main`. Original files preserved.
At the initial offline checkpoint no authenticated session had been exercised. On 2026-09-21
the user signed in through the research browser; sanitized observations are now recorded in
`browser-auth-observation-2026-09-21.md`. Subsequent N-002/N-003 user screenshots show native
login and identity recheck success for one account in the same process/session.

## Current gate status

**PENDING — initial native authentication substep demonstrated; complete native conversation
feasibility, full session lifecycle and isolation gates remain incomplete.**
Update N-005/N-006 (2026-09-24): one-account native history listing and same-build quit/relaunch
restoration succeeded. Full restoration/refresh/isolation and conversation gates remain incomplete.
N-004 now blocks the tested native generation path: HTTP 403 with
`{"error":"recaptcha validation failed"}` for the source-backed null-token request.
Offline foundation builds/tests pass; there is no basis yet to pass into Phase 1 implementation.
Foundation is a provisional candidate with measured limitations (`transport-results.md`).
The remaining gate requires a full direct-native conversation proof, restoration and two-account
isolation, not a documented browser-only blocker. Browser and narrowly scoped native login/identity
observations are now available; screenshot evidence is not a raw protocol fixture.
No capability is supported or unsupported merely because its implementation is absent.

## Exact next user action

Latest result: `native-history-restoration-2026-09-24.md` records successful automatic history
listing and subsequent verified relaunch restoration without another sign-in. Next: a bounded
native detail GET using an ID from the verified native list; generation remains on hold.

User decision after N-004: **hold generation and continue remaining Phase 0 checks**. Do not
advance to offline product milestones or change the canonical gate. H-001/H-002 browser history
research is recorded in `history-observation-2026-09-22.md`. N-005/N-006 subsequently passed the
native list and same-build restoration substeps. Native detail, refresh/expiration and two-account
checks remain pending.

The user subsequently authorized a single-slot Keychain restoration experiment and automatic
read-only checks. See `native-restoration-experiment.md`. It adds no browser transport or generation
retry, and does not pass restoration until a real save/relaunch/identity observation succeeds.

**Current result:** N-002 shows native login and identity HTTP 200; N-003 shows an identity recheck
with both ID claims unchanged. N-001's earlier HTTP 401 remains unexplained rather than erased.
Browser create/follow-up observations C-001/C-002 now have transformed response fixtures;
see `conversation-observation-2026-09-22.md`. The updated disposable proof adds **Test One Native
Prompt**, using the inspected client's null-token fallback. N-004 records rejection with HTTP 403
and `recaptcha validation failed`. Do not repeat this failed experiment or transfer browser tokens.
Further native work requires a verified legitimate native-compatible challenge/access contract.
Native refresh, cross-build restoration and two-account checks remain separate pending experiments.

The original browser-evidence procedure below remains the checklist for missing/repeated observations:

In your ordinary browser, open Arena through your usual trusted entry point. Open Network
developer tools, enable Preserve Log, then perform your normal sign-in or session restoration.
Observe the actual request sequence and the operation that establishes the current account's
server identity. Stop if a challenge requires interaction; complete it normally, never bypass it.
Do not log out an important existing session solely for this experiment.

Provide a **sanitized metadata report** using `protocol-ledger.md`'s template: actual origins,
methods, redacted routes/query parameter names, status/redirect sequence, credential/header
names and mechanisms (no values), supported callback/handoff if observed, identity field
location with a consistent pseudonym, observation time, browser version, and fixture/reference IDs.
Do not paste passwords, OTPs, cookies, bearer tokens, CSRF values, signed URLs, raw HARs, or
authentication response bodies into chat or Git. Keep sensitive inspection local.

This report determines whether a legitimate native auth/session proof can be implemented.
The agent then adds only that observed native flow, with ephemeral credential input/Keychain
handling and declared auth omissions. Browser evidence alone does not pass the native gate.
Do not extract browser cookies through unsupported mechanisms or indiscriminately replay a POST.

## Live acceptance checklist (initial native login/identity substeps observed; full gate pending)

For every row record browser fixture IDs, native fixture IDs, account pseudonym, app/adapter/
transport build, mode, UTC validation time, result, exact discrepancies, and follow-up. `Not exposed`
requires an observed absence, not an empty cell. Every understood flow needs a representative fixture.

| Step | Authorized action and evidence | Native acceptance |
|---|---|---|
| Authentication | Ordinary login; observe mechanism, callback, CSRF, origins, challenge and credential lifetimes | Legitimate native establishment without browser runtime for generation; no cert/ATS exceptions |
| Identity | Observe server principal after login and refresh | Accept profile only after scoped identity verification; mismatch quarantined |
| Refresh | Ordinary session refresh/rotation, including reauth failure when naturally encountered | One refresh per account; generation fixed for existing work; failure affects only that account |
| Create/send | One harmless distinctive prompt in one available mode | Native new conversation + prompt submission using only verified request contract |
| Stream | Preserve exposed body/message bytes and callback boundaries; compare IDs, lanes, content, tools/reasoning | Known observation representation and correlation; unknown data retained; no invented token boundaries |
| Completion | Compare protocol end signal, physical close, and retrieved final conversation | Logical lane/turn completion distinguished from transport closure |
| Stop | A separate ordinary prompt; press official Stop once; inspect subsequent history | Distinguish confirmed remote stop from local cancellation/unconfirmed outcome |
| History | List and retrieve the created conversation through observed paths; inspect cursors | Native list/detail match scoped IDs/relationships/content; pagination partiality explicit |
| Continue | Follow up in the same conversation/branch | Verified parent/branch/turn/lane mapping, not a new chat misrepresented as continuation |
| Relaunch | Quit native proof, restart, restore/refresh, fetch and continue prior conversation | No browser-owned state needed after restart; no blind retry of unknown-outcome send |
| Two accounts | Independently sign in A/B; keep A work active while choosing B; use bounded normal requests | Separate cookie jars/refresh/generations; late results keep A; switching does not cancel A; mismatch quarantined |
| Files | If available, upload benign file and download exposed original/workspace | Compare bytes/hash, scoped resource IDs, credential redirects, expiry/range behavior; missing originals explicit |
| Modes/labels | One fixture per actually available mode; inspect selections/catalog and existing reveals | No model identity inference; any vote/reveal with public effects requires a separate deliberate user action |
| Comparison | Retrieve same native conversation in Arena | Compare lane/message IDs, contents, exposed reasoning/tools/files, not just rendered text |

If browser-bound challenge per generation, nontransferable state, unavailable registration,
or browser-only runtime blocks native use: record the precise observation and stop/go decision.
No WebView generation fallback or public-inference-API substitution is permitted.

## Remaining offline/runtime limits

macOS 14 runtime checks require a separate supported host; the deployment target alone proves
no runtime compatibility. Cookie persistence/Keychain, credential rotation, redirect allowlists,
disk backpressure, durability, semantic parsers, MCP conformance, and full archive tests remain
at their plan phases. Local redirects currently use refusal, not a proposed Arena policy.
