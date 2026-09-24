# Phase 0 browser conversation evidence — 2026-09-22

## C-001 / C-002: authorized browser research

The official Direct UI submitted two synthetic prompts in the same browser conversation.
Create used POST `https://arena.ai/nextjs-api/stream/create-evaluation`; follow-up used POST
`/nextjs-api/stream/post-to-evaluation/[conversation-id]`. Both returned HTTP 200 with
`Content-Type: text/event-stream`. C-001 request content type was `text/plain;charset=UTF-8`
and Accept was `*/*`. Browser version was not recorded for this experiment.

| Observation | Request observed UTC | Complete body available UTC | Original decoded bytes |
|---|---|---|---|
| C-001 | 2026-09-22T07:43:17.277Z | 2026-09-22T07:43:21.048Z | 160 |
| C-002 | 2026-09-22T07:49:03.748Z | 2026-09-22T07:49:06.386Z | 161 |

Prompts requested exactly `Arena Suite feasibility check.` and `Arena Suite continuation check.`.
Joining the four `a0` JSON string rows in each response matched its expected answer.
Each response also had two `a2` array rows and `ad:{"finishReason":"stop"}`.
This is observed prefixed-line syntax, not proof of standard SSE framing or a general terminal grammar.
No native completion, stop, retry, or idempotency semantics have been verified.

Create body fields: `id`, `mode`, `modelAId`, `userMessageId`, `modelAMessageId`, `userMessage`,
`modality`, `recaptchaV3Token`. Observed mode was `direct-battle`, modality `chat`.
`userMessage` contained synthetic `content`, empty `experimental_attachments`, and empty `metadata`.
Follow-up had the same field names except `mode` was absent. Both had a nonempty challenge token.
Request tokens were omitted and custom raw request buffers dropped; no auth headers were exported.
The selected public model ID is frozen in the disposable recipe, not a verified backend identity.
Retained browser requests had expired before a later exact ID-linkage comparison; that comparison
was unavailable. Same-conversation scope is based on UI navigation, not verified ID equality.

The prior research session reported both answers visible after reload. The tool response retained
in the conversation was truncated; treat this as a manual browser observation, not a native history
or independently replayable retrieval proof. GET `/api/history/unified` was observed during reload;
its response semantics were not captured here.

Fixtures: `Fixtures/SanitizedArena/direct-create.fixture.json` and `direct-continue.fixture.json`.
They retain transformed complete decoded response bodies, source hashes, and declared transformations.
`a2` values were omitted, JSON reserialized, LF delimiters added, and timing ordinals are synthetic.
Original callback boundaries, wire bytes, exact offsets, and streaming latency are unavailable.
Raw responses existed only transiently in controller memory. These are not raw-exact captures.

## S-002: inspected public client source

Source: `/_next/static/chunks/15863-20218739ca4d1ea6.js`, inspected 2026-09-22.
SHA-256: `5313dfe619cc300d790a2cccefe9d9081be15ac113a15a8ce6cb4c2a2ff16bb8`.
Immediately before request construction, the source initializes `O=null`, tries
`O=await (0,J.ic)("chat_submit")`, catches acquisition failure, and assigns `recaptchaV3Token:O`.
This supports a null-token request experiment; it does not establish server acceptance.
The public helper chunk `38621-dbfe6710c20b746e.js` defines `generateSafeUUIDv7` using UUID v7
with a random sequence. That helper was inspected but not hash-pinned separately.

## Disposable native experiment and acceptance

The proof verifies both previously observed identity IDs immediately before one generation POST.
It uses the observed create fields with fresh local UUIDv7 request IDs and a null challenge token.
It never obtains/transfers browser tokens. A rejection or challenge ends the experiment.
Response callback bytes are retained before interpretation, with offsets, monotonic callback ticks,
and explicit interruption/capture-limit status. Limits: 4 MiB, 4096 callback units, 30-second resource
timeout. Capture is memory-only; no durability, complete HTTP metadata, or logical completion claim.
One attempt is permitted per client; there is no automatic retry, follow-up, or challenge escalation.

Acceptance: source-backed recipe; identity mismatch prevents mutation; rejection cannot retry;
opaque/interrupted bytes remain inspectable; local executor tests cover redirect refusal, isolated
cookies, callback reassembly and explicit limits; build and reviewer pass before live handoff.
**Native generation acceptance remains NEEDS PROTOCOL VERIFICATION.** All production capabilities
remain unknown. Refresh, restoration, native continuation/history/stop and two-account live gates remain open.

## N-004: native null-token generation rejected

After the reviewed proof was built and launched, the user supplied screenshots showing
`Generation HTTP 403`, transport `complete`, one callback observation, and 39 retained bytes.
The subsequent local-preview screenshot shows exactly:

```json
{"error":"recaptcha validation failed"}
```

This is user-supplied UI evidence supported by the reviewed single-shot recipe, not an exported
raw native fixture. Exact request time and original callback bytes were not independently captured
in the repository. Private account values from screenshots are omitted.

The tested native null-token create request failed reCAPTCHA validation. Native authentication
success does not establish generation access. This blocks the tested generation path; it does not
prove that every legitimate native integration is impossible or identify all server-side requirements.
No retry, browser-token transfer, challenge bypass, or browser production fallback is authorized
by this result. The next feasibility step requires evidence of a legitimate native-compatible
authentication/challenge contract; absent that, retain this precise blocker and stop this path.
Phase 0 remains blocked/incomplete, and no production capability is promoted.
