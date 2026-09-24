# Endpoint/protocol ledger v1

**Limited browser observations and a manual native auth/identity success exist; the full native
contract remains NEEDS PROTOCOL VERIFICATION.**
Ledger entries are evidence, not executable endpoint recipes. Never dispatch using a research lead.

## Authorized browser research B-001/B-002 and source evidence S-001

See [browser-auth-observation-2026-09-21.md](browser-auth-observation-2026-09-21.md).
Observed email login, identity and history request metadata now supplements R-001. Browser
reload preserved both identity claims. These are sanitized structural observations, not raw
fixtures or native proofs; initial monitor failure and incomplete login coverage are explicit.
The disposable `Tools/NativeAuthProof` executable tests this narrow observed auth/identity path
with user-entered credentials. N-001 records an initial 401, and N-002/N-003 later record successful
native login/identity and same-session ID equality via user-supplied screenshots. Preserve all
three observations; they neither explain the earlier failure nor establish the remaining contracts.
Production adapter capability states are unchanged.

## Evidence vocabulary

N-005/N-006: [native-history-restoration-2026-09-24.md](native-history-restoration-2026-09-24.md)
records native history-list HTTP 200 following manual login and then after verified Keychain
restoration in a fresh process. One-account, same-build scope only; no raw native fixture exported.

N-007: [native-detail-observation-2026-09-24.md](native-detail-observation-2026-09-24.md) records
the A1 detail experiment run live: one observed list page, first `evaluation` entry, one GET
`/api/evaluation/{id}` → HTTP 200, complete transport, 49084 bytes; detail ID equals the selected
list entry, message session IDs match, 3 messages, 0 duplicate message IDs, 0 parent/last-message
references outside the response. Same run restored the astra-saved Keychain session in the
opus-repo build without manual login (prompt interactivity unknown). One account, one build, one
request each; no raw native fixture, in-memory capture only.

N-008/N-009/N-010: [phase0a-observation-2026-09-24.md](phase0a-observation-2026-09-24.md) records
native cursor pagination (`cursor=<pagination.cursor>`, pages 5/5/4, union equals the full list),
entry types `evaluation`/`agentic`, auth-cookie names and lifetimes, `/api/me` without a session
(401 JSON `message`), cross-build Keychain restore with a stable signing identity, and two-account
isolation in one process. Also records that detail `messages[].metadata` contains per-user
anti-abuse telemetry. The native detail fixture now exists (`native-detail.fixture.json`).

N-011: [phase2-accounts-2026-09-24.md](phase2-accounts-2026-09-24.md) records three accounts signed in
through the product app's adapter and restored after relaunch and after a rebuild with a new signature.

H-001/H-002: [history-observation-2026-09-22.md](history-observation-2026-09-22.md) records browser
list query and observed evaluation detail GET, including synthetic-message relationship checks.
A projected sanitized list fixture now exists. N-005/N-006 verify narrow native list access and
N-007 adds narrow native detail access; N-008 adds the sanitized native detail fixture.

C-001/C-002 and S-002 are recorded in [conversation-observation-2026-09-22.md](conversation-observation-2026-09-22.md).
Browser create/follow-up succeeded; sanitized response fixtures now exist. The inspected public
client supports a null-token fallback experiment. N-004 subsequently records native HTTP 403,
`recaptcha validation failed`: the tested fallback is rejected, not a supported generation recipe.


`verified_observation`: a measured observation with fixture/time/environment and narrow scope;
local fixture transport results do not prove Arena behavior.
`repository_evidence`: pinned inspected source, not a current service contract.
`design_decision`: selected local architecture.
`assumption`: untested prerequisite, never promoted by implementation convenience.
`NEEDS PROTOCOL VERIFICATION`: unanswered live behavior. Evidence and capability status are distinct.

## Append-only research entry template

Copy for each observation; supersede earlier entries by ID rather than overwriting disagreements.
Do not record credential values or bearer-like query values.

```text
entry_id / supersedes / operation / account_pseudonym / mode:
evidence_kind / browser_or_native / validation_utc / observer:
app_browser_os_versions / adapter_transport_build:
source_commit_and_file_lines (repository evidence only):
authorization_reference / fixture_ids / private_source_reference:
observed_origin / redacted_path / query_parameter_names / method:
request_grammar / response_content_types / status:
credential_mechanism_and_names_only / credential_omissions_policy:
csrf_requirements / session_rotation / verified_principal_scope:
redirect_sequence / credential_forwarding_boundaries:
stream_grammar / encoding_representation / observation_layer:
terminal_evidence / local_cancel_vs_remote_stop:
request_turn_lane_message_branch_ID_scopes:
version_hints / retry_after_rate_limits / idempotency_resume_evidence:
pagination_order_cursor_exhaustion / history_live_discrepancies:
file_resolution_expiry_ranges / model_identity_claim_provenance:
unknown_fields_and_limits / transformations_and_offset_mapping:
capability_state / last_validated_utc / next_experiment:
```

Unknown fields are explicitly `unknown`, not guessed values. A route match does not identify a
grammar. Supporting fixtures carry original/transformed fidelity and provenance. Supported status
requires a native observation in its specific account/mode/build scope; unsupported requires
observed negative evidence; absent or stale evidence is unknown pending revalidation.

## Pinned repository research R-001

Inspected 2026-09-20: `musterm4nn-alt/arena-exporter`, version 2.1.3,
commit **`71d0978e1f7506289d1229b8660b208d45b9461b`**.
Sources at `https://github.com/musterm4nn-alt/arena-exporter/tree/71d0978e1f7506289d1229b8660b208d45b9461b`.

| Source | Inspected research lead (repository evidence only) |
|---|---|
| `src/history-backfill.js:110–160` | `/api/history/unified`, `/api/history/list`; fallback and several cursor/entry field alternatives |
| `src/history-backfill.js:222–240` | `/api/evaluation/` plus ID; `/agent/` HTML fallback |
| `src/injected-main.js:243–254` | realtime session `/out`, `in/append`, `create-chat`, `create-evaluation`, `post-to-evaluation` matchers |
| `src/injected-main.js:84,562` | `x-session-settled`, `x-stream-version`, `x-arena-chat-id` retained header names |

Verified file blobs: `injected-main.js` = `821354300eff2a76d5d963dd225118c5343517f4`;
`history-backfill.js` = `b120559e8e4134430791e1dd37d583d6fa3f8bf0`;
`session-store.js` = `f51f160abf0090df47d55099032f6fd2718c357c` (hash recorded, not a fresh full source audit).
These match the master plan's representative blobs; they are not commit IDs.
The inspected exporter coerces history types and filters IDs; those choices are not adopted here.

## Operation records

All native capability validation times remain null and no byte-exact live fixture exists.
B-001 now observes browser URL/method and structural metadata for email sign-in, `/api/me`,
`/api/me/pulse` and history listing. Native credential/CSRF/refresh contracts and all generation
grammar/terminal semantics remain unknown. R-001 remains a source lead, not a service contract.

<a id="authenticate"></a><a id="refreshSession"></a><a id="verifyIdentity"></a>
- `authenticate`, `refreshSession`, `verifyIdentity`: **NEEDS PROTOCOL VERIFICATION** — Q01–Q04.
<a id="createConversation"></a><a id="sendPrompt"></a><a id="streamResponse"></a>
- `createConversation`, `sendPrompt`, `streamResponse`: **NEEDS PROTOCOL VERIFICATION** — Q05–Q08, Q10–Q15, Q19–Q21.
<a id="stopRemoteGeneration"></a>
- `stopRemoteGeneration`: **NEEDS PROTOCOL VERIFICATION** — Q09, Q12.
<a id="listHistory"></a><a id="getHistoryDetail"></a><a id="continueConversation"></a>
- `listHistory`, `getHistoryDetail`, `continueConversation`: **NEEDS PROTOCOL VERIFICATION** — Q08, Q16–Q17; native relaunch/restore additionally Q01.
<a id="uploadAttachment"></a><a id="downloadWorkspace"></a>
- `uploadAttachment`, `downloadWorkspace`: **NEEDS PROTOCOL VERIFICATION** — Q17–Q18 plus actual upload composition/resource association.
<a id="revealModels"></a>
- `revealModels`: **NEEDS PROTOCOL VERIFICATION** — Q14–Q15; public-effect action separated from ordinary reads.

## Complete unresolved verification register

Every Arena question in master-plan section 22 retains unresolved scope. B-001/B-002 provide
partial browser evidence for Q01/Q03/Q16, and N-002/N-003 demonstrate Q01's initial native login
and same-session identity substeps. N-005/N-006 additionally demonstrate same-build relaunch
restoration and native history listing. N-007 adds one cross-build Keychain restore with unknown
prompt interactivity. Refresh/expiration, settled cross-build access and full feasibility remain open.

| ID | NEEDS PROTOCOL VERIFICATION | Next evidence required |
|---|---|---|
| Q01 | Broader session retention, refresh/expiration, cross-build restoration | N-002/N-003 login and N-006 same-build restart observed; N-007 adds one cross-build restore (Keychain-prompt interactivity unknown); verify remaining lifecycle and live forgetting |
| Q02 | Browser-bound challenge/runtime or unavailable registration | Observe legitimate login/send requirements; no bypass |
| Q03 | Cookies/bearer/CSRF, OAuth callback/email/OTP, rotation, multiple origins | Redacted full auth/request/redirect sequence |
| Q04 | Two simultaneous accounts and session invalidation | Native A/B identity/refresh/isolation run |
| Q05 | Available modes/modalities and shared protocol families | One fixture per available family |
| Q06 | Stream encodings, compression, binary, reconnect framing | Declared-boundary byte fixtures + content types |
| Q07 | Whether Foundation hides data actually required by Arena | Compare live requirements with local transport matrix |
| Q08 | Request/turn/lane/branch/message correlation, edits/regeneration | Same-flow live/history ID graph comparison |
| Q09 | Remote stop versus local cancellation | Official stop and subsequent history/native proof |
| Q10 | Resume cursors versus fresh-stream reconnect | Authorized interruption and observed resume behavior |
| Q11 | Idempotency/duplicate handling | Observed IDs and safe controlled duplicate semantics; no blind resend |
| Q12 | Logical lane/turn terminal semantics versus closure | Finish events, multi-lane/tool turns, final history |
| Q13 | Exposed reasoning/tool data and historical differences | Same interaction live/UI/history comparison |
| Q14 | Model labels: selection/catalog/reveal/vote/lane/round scope | Provenance-linked claims and contradictions |
| Q15 | Reasoning level, harness, routing metadata | Exposed config/response claims only |
| Q16 | History pagination stability, cursor expiry, archived/deleted entries, branches | Bounded known-history traversal and counts/IDs |
| Q17 | Older tools/files and upload resource linkage | Benign upload/download, revisit older resources |
| Q18 | Download immutability, ranges, validators, redirects, expiry renewal | Byte hashes plus observed resolution/range metadata |
| Q19 | Token count/timestamp units and scope | Source claims with explicit units/meaning |
| Q20 | Version/change signals and header semantics | Observed headers/build metadata across captures |
| Q21 | Throttle/concurrency/rate-limit rules | Normal traffic and explicit retry metadata; no quota exhaustion |
