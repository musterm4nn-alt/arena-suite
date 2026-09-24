# N-008 … N-010 — Phase 0-A experiments (A2–A8)

Date: 2026-09-24. Tool: `Tools/NativeAuthProof`, identity-signed (stable Apple Development identity, see
`Scripts/build-auth-proof.sh`), direct native Foundation transport. Read-only: no generation,
no continuation, no vote. Requests one at a time, at least 1 s apart. Reports are value-free
(counts, shapes, names, booleans); raw bodies stayed in process memory and were discarded.
Local reports: `DerivedData/Phase0AResult-A*.json`, `DerivedData/IsolationResult.json` (not in Git).

## N-008 — account A, runs at 09:14Z and 09:16Z (9 requests each)

| Item | Observation |
|---|---|
| **A2 pagination** | `limit=5&includeArchived=false`, then `cursor=<pagination.cursor>` (parameter name from R-001, now confirmed natively). Pages of 5, 5, 4 entries; `hasMore` true, true, false; cursor 66 bytes when present, `null` on the last page; 0 overlap; union of IDs equals the 14-entry `limit=20` list. Identical in both runs. |
| **A3 entry types** | 9 `evaluation`, 5 `agentic`. `agentic` entries have no `mode`/`modality`. Evaluation modes: `battle` (7), `direct-battle` (2); modalities `chat` (3), `webdev` (6). `includeArchived=true` returned the same 14 entries (account has no archived entries). No detail route for `agentic` has been observed. |
| **A4 cookies** | Jar holds `arena-auth-prod-v1.0` and `arena-auth-prod-v1.1` (domain `arena.ai`, not HttpOnly, not Secure, SameSite=Lax, expiry 2027-10-29), `__cf_bm` (Cloudflare, 30 min), and a session cookie `_vcrr_…`. One `/api/me` request changed no cookie. The auth-cookie expiry is 08:57:46Z + ~13 months, i.e. it was re-issued during the N-007 run, so rotation does happen on some request; which one is not yet known. |
| **A5 no session** | `GET /api/me` with an empty jar: HTTP 401, `application/json`, top-level key `message` only. |
| **A8 detail** | The synthetic C-001/C-002 conversation (selected by its synthetic title): HTTP 200, 20 348 bytes. Sanitized projection committed as `Fixtures/SanitizedArena/native-detail.fixture.json`. |

**Finding — telemetry in message metadata.** Detail responses carry, per message, a `metadata`
object with anti-abuse and routing data about the user: bot and reCAPTCHA scores, JA4 fingerprint
ratios and ranks, Cloudflare geo fields and hashed IP, account age, hour/day of activity, prompt
and vote counts, and for assistant messages routing (`fromAutoRouter`, `p2lConfig`, `routedModel*`),
timing and token usage. The first sanitizer pass kept these numbers; a second pass masked every
number/boolean under `metadata` before the fixture was committed. Consequences in plan v3 §12.

Other detail shape observed: top-level `revealedModels`, `maskedEvaluations`, `pairwiseFeedbacks`,
`pointwiseFeedbacks`, `deletionPendingProcessing`; per message `participantPosition`, `modelId`,
`evaluationId`, `failureReason`. Top-level `createdAt`/`updatedAt` are 26–29-character strings
that are not ISO 8601 with `T` (exact format to be decoded in Phase 4).

## N-009 — A6 cross-build Keychain access

- Item originally created by an ad-hoc build: identity-signed builds got preflight `wouldPrompt`
  (`errSecAuthFailed`, −25293) and restored only after the macOS prompt, in two consecutive builds.
- After `--rekey` (delete + re-add from an identity-signed build), a **different** later build
  (new build number and cdhash `faec1544…`) read the item with interaction disabled:
  preflight `found`, status 0.
- Conclusion: with a stable Apple Development identity, Keychain items created by a signed build
  survive rebuilds without prompts. Items created by ad-hoc builds must be recreated once.

## N-010 — A7 two accounts in one process

Slots A and B restored concurrently in one process (separate `URLSession` configurations and
cookie jars), then listed history concurrently (one request in flight per account) and re-verified
identity: principals differ; both identities stable; entries A 14, B 20 (B `hasMore=true`);
**0 overlapping entry IDs**; **0 cookie values shared** between the jars. Account B's first
sign-in in slot B also fetched one detail (HTTP 200) with consistent structure.

## Open

- A3: `agentic` detail route (v1 archives agentic entries as list entries only until observed).
- A4: session behaviour after ≥ 24 h, and which request rotates the auth cookies.
