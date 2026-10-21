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

N-015: [datasets-2026-09-27.md](datasets-2026-09-27.md) records, from the archived journals (counts only):
model claims on `battle` conversations appear only after a pairwise vote (25 of 40 battles, exactly the voted ones;
no battle `history_list` claim); all 148 vote-scoped claims agree with the message `modelId`; all 217 message claims
are in the revealed set; every assistant message has one parent, a user prompt, and in multi-turn battles that prompt's
parent is one lane's response (113 `a`, 111 `b`). Which history each lane's model received is not observable.

N-016 (2026-10-19, `verified_observation`, counts only): in the live index (`arena-decoder/1`, 3 accounts),
the latest snapshots hold 74 `pairwiseFeedbacks[].value` strings, all from this vocabulary: `model_a` 35,
`model_b` 36, `tie` 1, `both_bad` 2. Each vote carries `modelAId`/`modelBId` (148 vote-scoped claims, two per
vote). Conversation modes: `battle` 43, `side-by-side` 7, `direct-battle` 4, none or other 6 (the `agentic`
entries). Claim sources: `message_model_id` 217, `pairwise_feedback` 148, `detail_revealed` 134,
`history_list` 107; 36 conversations carry a revealed set. **`assumption`:** the values mean "A is
better", "B is better", "tie" and "both are bad" (the site's vote buttons). The names support this,
but no response states it. Insights interprets only these four values and shows any other value as
unrecognized, uninterpreted. Also counted (2026-10-19, journals re-projected with
`arena-decoder/2`): no unknown field path under `pointwiseFeedbacks`, so no single-response feedback with
content is recorded. An empty element would carry no path and would not be counted. Insights shows pairwise
votes only and says so.

N-018 (2026-10-20, `verified_observation` + `assumption`, counts only): in the live index, all 54
latest snapshots record a `lastMessageIds` list (49 with two IDs, 5 with one). Every listed ID is a message
of the same snapshot. In 52 the list is exactly the responses after the last prompt. In the other 2 it is
the last prompt itself (status `flagged`), which has no response. No response after the last prompt is ever
left out. **`assumption`:** the list names the conversation's last messages, so they and the `user`
messages they reply to are its "last answer" (the export scope, `Docs/export-options-2026-10-20.md`).
Nothing in a response states this. An empty, dangling or unreadable list is refused, never filled in.

N-017 (2026-10-19, `verified_observation` + `assumption`, counts only): in the live index (3 accounts), 18 of
the 65 claimed model IDs are claimed in more than one account. All 18 carry a `detail_revealed` name in more
than one account, and no model ID has more than one revealed name in any account or across accounts.
**`assumption`:** a model ID is Arena's own identifier, the same in every account, so a name revealed in
one account labels that ID in another (Insights and the history filters' model menu). Nothing in a response
states this. Where names differ, the latest record's name is shown (by sequence, then account, then name).

N-019 (2026-10-20, `verified_observation`, counts and shapes only; read-only over the archived journals):
the 19 detail responses that carry attachments hold 138 `messages[].experimental_attachments[]`, all with a `url`,
all images (`image/png` 77, `image/jpeg` 59, `image/webp` 2). Every URL is `https` on
`messages-prod.<id>.r2.cloudflarestorage.com` with path `/<id>/<id>.<ext>`, and an S3 SigV4 presigned query:
`X-Amz-Algorithm`, `X-Amz-Content-Sha256` (`UNSIGNED-PAYLOAD`), `X-Amz-Credential` (scope `auto/s3/aws4_request`),
`X-Amz-Date`, `X-Amz-Expires` (`3600` in all 138), `X-Amz-Signature`, `X-Amz-SignedHeaders` (`host`),
`x-amz-checksum-mode` (`ENABLED`), `x-id` (`GetObject`). Every `X-Amz-Date` is 0–5 s before the record's
`observed_at`, one signing time per response: Arena signs the links when it serves the detail. All 138 had
expired at the time of counting. No object path appears in more than one snapshot, so whether a path stays the
same across fetches is not observed. **Live (2026-10-20, announced, the user's own new battle with one image,
synced by the user):** one native GET of the fresh link (ephemeral `URLSession`, no cookies, no credentials, no
cache, redirects refused) returned `200`, `Content-Type: image/png` as declared, `Content-Length` equal to the
1 234 131 bytes received, PNG magic bytes, and an `ETag`; headers `accept-ranges`, `cf-ray`, `connection`,
`content-length`, `content-type`, `date`, `etag`, `last-modified`, `server` (no `x-amz-checksum-*`). No request
went to Arena itself; the bytes stayed in memory. Still not observed: whether a later fetch of the same
conversation signs the same object path, whether the `ETag` is the bytes' MD5, and whether old objects remain.

N-020 (2026-10-20, `verified_observation` + `assumption`, counts only; the user's own battle, announced): the
user synced while a new battle was generating, then let it finish, voted, and synced again about 40 minutes later.
The first sync's detail recorded 3 messages: the prompt `success` and both responses `pending`, no vote. The
second sync's history list response was **byte-identical** to the first, so the incremental rule (plan §9.3:
refetch only when the list's `updatedAt` changes) fetched no detail. The archive keeps the unfinished responses
and no vote. Across the live index, the latest snapshots of 3 conversations hold `pending` messages (2 `battle`,
1 `direct-battle`; 5 messages); 25 of 44 battles' latest snapshots carry a vote. **`assumption`:** the list
entry, including `updatedAt`, does not change when responses finish or a vote is cast (server-side caching is not
excluded). So a snapshot taken before either is never refreshed by the incremental sync.

N-022 (2026-10-21, `verified_observation` + `assumption`, counts and key names only; announced, `Tools/NativeAuthProof
--agent-detail`, slot A's saved session from 2026-09-24 still verified): one history page held 5 `agentic` entries
with keys `archivedAt`, `codingSessionStatus`, `createdAt`, `id`, `isMaxRouter`, `productMode`, `title`, `type`,
`updatedAt`. For the first: `GET /api/evaluation/{id}` → `404` JSON `{error}`; `GET /agent/{id}` → `200`
`text/html; charset=utf-8`, 246 462 bytes, 42 Next.js flight chunks (`self.__next_f.push([1,"…"])`, all decodable).
One flight row holds the transcript object: `taskId`, `triggerAddress` (equal to the page's `sessionId` and to the
conversation ID), `messages[]` (`id`, `role` `user`/`assistant`, `metadata` with `nodeId`, `manifestNodeId`,
`pending`, `requiresReview`, `feedback`, and `timing` on replies, `parts[]`), `pagination` (`hasMore` `false`,
`cursor` `null`, `limit` `20`), `transcriptReadStrategy` `bounded`, `session` (`publicAccessToken`: a JWT,
`lastEventId`, `taskId`, `triggerAddress`), `productMode`, `feedbackType`, `customFeedbackArm`, `connectorsEnabled`,
`arenaFeedbackEnabled`, `rubricsEnabled`, `pinnedModel`. Part types (AI SDK message parts): `text`, `reasoning`
(`state` `done`), `step-start`, `tool-write_file` and `tool-present_file` (`toolCallId`, `input`, `output`, `state`
`output-available`). The page's only JWT-shaped string is that token. The page loads Cloudflare's
`challenge-platform` script without being a challenge. arena-exporter's lead (`{"messages":[` at an object's
start) does not match this page. **`assumption`:** `triggerAddress` names the conversation on every page; the
first 20 messages are what the page serves (`bounded`), and how to read more (`hasMore: true`) is not observed;
no `/api/…` route for the transcript appears in the page. Not observed: the realtime stream, `workspace/latest`.

N-021 (2026-10-20, `design_decision` + `assumption`; no new live observation): attachment downloads
(`Docs/attachments-2026-10-20.md`). Downloads accept only `https` links on a host ending in
`.r2.cloudflarestorage.com` with no user, password or port (the only host N-019 observed); other links are kept
and never requested. **`assumption`:** a link stops working `X-Amz-Expires` seconds after `X-Amz-Date` (the S3
presigned-URL rule; what R2 answers to an expired link is not observed), so such a link is not requested.
**`assumption`:** an object key (scheme, host and path, without the query) names the same bytes every time, so a key
already stored with its file present is not requested again (N-019 saw no path in two snapshots). 401/403 and
429/503 from the file host stop downloads for the rest of the job (plan §2 applied to the file host). Q18 stays open.

N-013: [phase4-index-2026-09-24.md](phase4-index-2026-09-24.md) records that every field in the 51 archived
detail and 7 list responses is recognized by `arena-decoder/1` (0 unknown paths, 0 warnings), content-block kinds
`text`/`reasoning`/`tool-call`/`tool-result`, lanes `a`/`b`, and that `JSONSerialization` keeps the first duplicate key.

N-012: [phase3-history-sync-2026-09-24.md](phase3-history-sync-2026-09-24.md) records full native
history sync for three accounts (57 list entries, 51 detail snapshots, one 2-page listing), a resumed
sync after `kill -9`, an incremental re-sync, and that list entries are ordered newest-first by `updatedAt`.

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
