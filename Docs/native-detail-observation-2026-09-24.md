# N-007 — native conversation detail (A1)

Scope: one account, rebuilt proof app from the `arena-suite-opus` working tree (ad-hoc signed with
`codesign --force --sign - --options runtime`; `codesign --verify --deep --strict` passed), direct
native Foundation transport. Generation remained disabled. No browser state or password was
extracted by the agent; the saved Keychain session was restored without a manual sign-in.

Build: `bash Scripts/build-auth-proof.sh` on 2026-09-24 (`swift build --package-path
Tools/NativeAuthProof --arch arm64`, incremental complete). Launch: `open
DerivedData/NativeAuthProof.app`. The app was quit by the agent after the report settled.

## Run

The reviewed automatic startup path reported, in order, `restoring` → `historyObserved` →
`detailObserved` (run ID `54367D1A-559A-4CB0-B5F9-5AFA613010B0`, report updated
2026-09-24T08:57:49Z). No `awaitingLogin` and no `failed` phase occurred.

Value-free report (exact `summary` field):

> History HTTP 200 · transport complete · 4811 bytes. Entries: 14; hasMore: false; partial: false;
> failed sources: 0. No further page requested. Detail HTTP 200 · transport complete · 49084 bytes.
> ID matches selected list entry: true; message session IDs match: true; messages: 3; duplicate
> message IDs: 0; parent references outside response: 0; last-message references outside response:
> 0. No continuation attempted.

This is exactly the A1 acceptance recipe: identity verification, one fresh observed history-list
page, explicit selection of the first entry typed `evaluation`, one GET `/api/evaluation/{id}`,
both replies retained in memory before structure inspection.

## What this verifies (narrow)

- `getHistoryDetail` for a single selected entry: HTTP 200, complete transport, 49084 bytes in this
  build/account run.
- Structural consistency as reported by the reviewed code: detail ID equals the selected list
  entry ID; message `evaluationSessionId` values match; 3 messages; 0 duplicate message IDs; 0
  parent references and 0 last-message references outside the response.
- The list page in the same run (4811 bytes, 14 entries, `hasMore=false`, `partial=false`, 0 failed
  sources) reproduces the N-005/N-006 counts; no further page was requested.
- Session restore: the Keychain item (`ArenaSuite.NativeAuthProof.Session.v1`) saved by the earlier
  astra-repo build was restored and identity-verified by this opus-repo build with no manual login,
  once. The value-free report cannot show whether macOS displayed an interactive Keychain approval;
  that is **unknown**, not observed either way.
- No generation, no continuation, no pagination, no more than one in-flight request per step.

## Remaining limits

- One account, one build, one list page, one detail request. Counts are not a full history
  comparison; equal byte sizes across runs do not establish payload identity.
- No byte-exact native fixture was exported; the detail bytes stayed in memory and were discarded
  when the app was quit. A detail fixture (A8) remains pending.
- Cross-build Keychain access is one narrow observation with unknown prompt interactivity; it is not
  the A6 signing result (A6 still needs a signing decision and a deliberate rebuild/sign test).
- Pagination, other entry types, session expiry and two-account isolation (A2–A7) remain open.
- No production capability is promoted; evidence and capability status stay distinct. `getHistoryDetail`
  keeps its NEEDS PROTOCOL VERIFICATION register items (Q08, Q16–Q17) at the ledger.
