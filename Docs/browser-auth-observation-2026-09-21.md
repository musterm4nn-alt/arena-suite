# B-001 — Authorized browser authentication research

Evidence class: **verified observation, browser scope only**. User authorized Playwright
research and manually signed in on 2026-09-21. Browser: Chrome 153.0.8010.50, headed mode.
Local account pseudonym: `research-account-A`. Real account identifiers/credentials are omitted.
This report is sanitized structural metadata, **not a raw protocol fixture or replayable request**.

## Observation boundary and limitations

The initial custom metadata collector recorded zero events because `URL` was unavailable in the
Playwright tool's server-side JavaScript runtime. Its exception handler suppressed the error.
The login sequence is consequently **not a continuous capture**. No claim is made about every
redirect, intermediate request, authentication challenge, or original byte/timing boundaries.

Browser Performance resource entries identified routes; Playwright's retained recent Request
objects then supplied the metadata below. `page.requests()` retains at most approximately 100
requests and is not an archive. Those objects were inspected before collection; original auth
bodies, credential values, personal identifiers and headers were not exported to this report.
Only request field names and cookie names/attribute names were returned by the tool.
Authentication response bodies were not inspected. Cookie attributes here are names only;
their values/expiry semantics and chunking/refresh rules remain unverified.

## Observed requests (2026-09-21, approximately 05:56–05:59 UTC)

All listed routes used origin `https://arena.ai`. Browser requests carried Cookie headers,
with no Authorization header in the inspected request metadata. This does not establish the
minimal native header set, whether a CSRF check exists, or which cookie is sufficient.

| Route | Method/status | Observed metadata |
|---|---|---|
| `/nextjs-api/sign-in/email` | POST / 200 | Request body field names: `email`, `password`, `shouldLinkHistory`; response `application/json`; Set-Cookie names below |
| `/api/me` | GET / 200 | Response `application/json`; `user` object shape below |
| `/api/history/unified` | GET / 200 | Query names `limit`, `includeArchived`; JSON content type; body omitted |
| `/api/me/pulse` | GET / 200 | JSON content type; body omitted; semantics unknown |

Sign-in Set-Cookie names: `arena-auth-prod-v1`, `arena-auth-prod-v1.0`, `arena-auth-prod-v1.1`.
First exposed attribute names `Path`, `SameSite`; latter two also `Expires`, `Max-Age`.
This is not a cookie parser implementation or proof of cookie deletion/fragment reconstruction.
No values were retained in the research report or copied into the native client.

`GET /api/me` response structural observation:

```text
user: object
  id: string
  supabaseUserId: string
  touConsentTimestamp: string
  avatarUrl: null
  email: string
  emailProvider: string
  username: string
  marketingSubscribed: boolean
```

`id` and `supabaseUserId` are distinct server claims. Their general uniqueness, equivalence,
and lifetime are not established. No account profile is accepted into a production registry.

## B-002 — Browser reload and identity comparison

After a normal page reload, a corrected metadata monitor observed history and pulse GETs
returning 200. The research tool made two additional GETs to the **already observed** `/api/me`
route. The first returned 200 but its comparison script errored by using Fetch's numeric `status`
as a function. The second, 05:59:52.100–05:59:52.540 UTC at controller-event boundaries, returned
200 and confirmed equality of both ID claims with the pre-reload observation.

The corrected monitor reported zero errors and dropped events within its narrow allowlist.
This demonstrates browser page-reload continuity, **not browser-process restart or native
session restoration**. Personal identity values were used only in controller memory for equality
and were not included in the report. Browser/controller context later restarted; its in-memory
baseline and retained login request are no longer available. No inference about logout follows.

## S-001 — Public client source, not a verified native request contract

Inspected the actual external JS sources referenced by Arena's page at 17:11 UTC on 2026-09-21.
These are **repository/source evidence**, not a new live login observation. No inline hydration
or private user data was copied. Hashes cover browser-delivered decoded public JavaScript bytes:

| Path | SHA-256 / byte count |
|---|---|
| `/_next/static/chunks/53304-2edc4d21985255c5.js` | `a9d1e40bbe23cd86f1585bb4c21877a655ed831f92231c625f34588e3f968ba0` / 79335 |
| `/_next/static/chunks/app/%5Blocale%5D/(app)/layout-4b8b60c257b3707e.js` | `f5dcb08db986f8a6b4f306892f5b700cae90cac40c3982c9a02a65afa246c41c` / 26236 |

The login handler uses `fetch('/nextjs-api/sign-in/email')`, POST, Content-Type
`application/json`, and JSON fields `email`, `password`, `shouldLinkHistory`. Conditional
`marketingConsent`/`registeredCountryCode` fields appear only when that state is present.
These optional fields were absent in the retained B-001 request's field inventory.
State source initializes `shouldLinkHistory` to Boolean true and includes Boolean conversion
from a URL parameter plus a setter. Visible source copy describes saving current chat history
to the account. This supports Boolean syntax, not server-side semantics of either value.

The disposable native proof chooses **false** to request no history linking. This is a declared
design choice/hypothesis, not a retained value from B-001 or a proven server guarantee. It does
not create an anonymous browser history or copy browser cookies. No marketing option is submitted.

## Credential exclusion policy `auth-research/1`

Cookie/Authorization values, email/password values, authentication response bodies, signed query
values, and personal ID/profile values are omitted from ordinary research evidence. Metadata is
transformed/structural and cannot reconstruct an authenticated request. This is the master plan's
declared credential exception, not a claim of byte-exact capture. Browser tooling may internally
retain requests in its own profile/session; no HAR, storage state, or private payload is committed.

## Gate consequence at the browser-only checkpoint

Q01/Q03 now have limited browser observations; Q16 has an observed history URL/status only.
All **native** capability states remain unknown. Native login requires the separate manual proof;
refresh, relaunch, challenges, minimal credentials/headers and two-account isolation remain open.

## N-001 — First manual native attempt: HTTP 401

On 2026-09-21 the user supplied a screenshot of the native proof status:
`signIn returned HTTP 401`. The user confirmed that they had entered the password.
Evidence scope is **user-supplied screenshot of native UI**, not an independently retained HTTP
response or proof that the entered credentials matched the browser account. No identity request
follows this status in the reviewed implementation, and no automatic retry occurs.

The UI copies the password to the submission before clearing its input field. Code inspection
and the synthetic serialization regression establish that clearing the field does not empty
the request password. This is not an inspection or claim about the user's actual secret bytes.
The discarded error body cannot be recovered. HTTP 401 alone does not identify invalid credentials,
missing session prerequisites, a policy rejection, or a fundamental native-client blocker.

**Gate remains unproven, with one failed native auth attempt.** Do not promote supported or
unsupported capability states based solely on this result, and do not introduce browser transport.

### Diagnostic revision for a controlled follow-up

The previously pinned S-001 public login handler inspects `error` and `requiresVerification`
on unsuccessful responses; it displays a verification warning when the latter is truthy.
This establishes source evidence for the field names, not a live observation of N-001's body.
The revised proof interprets only a string `error` and strict Boolean `requiresVerification`
from error JSON up to 64 KiB. Other shapes are unsupported; no heuristic meaning is invented.

Policy `auth-local-presentation/1`: a user may reveal the selected server message locally in the
native UI. It is untrusted text, capped at 512 characters, may contain sensitive information,
and is not logged/exported or added to the ordinary evidence archive. Public error/status
values remain fixed/value-free; default descriptions of the presentation object are redacted.
Successful auth bodies are still uninterpreted. Session reset/quit discards the presentation.
This changes local presentation only, not the submitted login request or retry policy.

## N-002 / N-003 — Manual native login and identity recheck succeeded

On 2026-09-21 the user supplied two subsequent screenshots of the native proof:

- **N-002:** `Native sign-in HTTP 200; identity HTTP 200 with the observed ID fields.`
- **N-003:** after clicking Recheck Identity, `Native identity HTTP 200; both ID claims match
  the prior native observation.`

Evidence classification: verified observation **of user-supplied native UI screenshots**,
supported by the reviewed proof implementation; not a saved raw HTTP fixture. Exact request
times, response bytes and credentials are not available in this record. Personal account/email
values from screenshots are deliberately omitted. Pseudonym: `research-account-A`; equality
with the earlier browser's server IDs has not been established because its baseline was lost.

The screenshots show a dot difference between the entered personal Gmail address and the
server-returned email. The proof forwards the input email unchanged; it performs no dot removal.
Google documents dot equivalence for personal `@gmail.com` mailboxes, but that provider rule is
not used to merge Arena accounts or infer principal equality. The stable-ID check in N-003
compares the two distinct server ID claims directly, without email normalization.
Reference: https://support.google.com/mail/answer/7436150?hl=en.

**Scoped result:** direct Foundation-based email/password login followed by an identity GET,
and a second identity GET with both ID claims unchanged, succeeded within one process/session
for this manual account experiment. The reviewed tool has no browser transport/state import.
This demonstrates the initial native authentication substep; it does not establish why N-001
failed, guarantee `shouldLinkHistory=false` semantics, or prove refresh/rotation, relaunch
restoration, browser/native principal equality, a second account, or conversation operations.

**Full Phase 0 remains pending.** Preserve N-001 alongside the positive observations. The next
research step is a representative authorized conversation flow and the native reproduction of it;
credential restoration and two-account work remain separate required checks.
