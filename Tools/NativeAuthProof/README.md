# Disposable native authentication proof
Phase 0 research executable, separate from the product app and its adapter. Contract sources:
`Docs/browser-auth-observation-2026-09-21.md` (B-001/B-002/S-001).

```sh
swift test --package-path Tools/NativeAuthProof
bash Scripts/build-auth-proof.sh
open DerivedData/NativeAuthProof.app
```

The user enters email/password directly into a native window. Pressing **Test Native Sign-In**
sends exactly one POST to the observed sign-in route, then GET `/api/me` only after status 200.
The password field is cleared at submission; credentials necessarily remain in process/request
memory while used. No secure zeroization guarantee is made. No credentials enter command-line
arguments, diagnostic output, app preferences, evidence files, or Git.

Each client owns a fresh ephemeral URLSession/cookie jar, nil cache/credential storage, serial
delegate queue, and bounded request/resource timeouts. All redirects are refused. No TLS exception,
browser state extraction, CAPTCHA bypass, automatic retry, refresh, or general-purpose URL UI.
Origin/Referer and browser-only headers are not impersonated; whether native defaults work is
the experiment. `shouldLinkHistory=false` is a declared source-supported Boolean choice whose
native/server behavior still needs verification. Auth response bodies are omitted from evidence.

After a failure, **Show server error locally** can display selected `error`/`requiresVerification`
fields observed in the public client source. This optional view is in-memory UI only, untrusted,
and can contain personal information; do not send a raw screenshot or secret-bearing text to chat.
Only error JSON up to 64 KiB is inspected, and error text is limited to 512 characters. Unsupported
shapes produce a fixed omission message. The ordinary error/status path remains value-free.
The password field clears after a snapshot is taken for submission; that does not clear the request.

A 200 login alone is insufficient: the observed identity shape and nonempty ID/email values must
also be returned. The email is shown only in the native UI for the user to check against the
intended account. This does not automatically prove equality with the earlier browser identity.
**Recheck Identity** compares both ID claims; disagreement quarantines this client's requests.
**New Isolated Session** discards the active client/session. With the user's explicit authorization,
native cookies and expected IDs are now saved in one dedicated macOS Keychain slot after sign-in.
The password is never saved. Launch restores into a fresh jar and verifies both IDs before one
automatic read-only history check. **Forget Saved Session** deletes the item and discards the active
session. See `Docs/native-restoration-experiment.md` for scope, failure handling and live gates.
Value-free status is written to `DerivedData/NativeProofResult.json` for agent inspection.

Generation is now **on hold** following N-004's HTTP 403 / reCAPTCHA validation failure; its UI
button is disabled. **Inspect Native History List** verifies identity and performs one read-only
GET using H-001's observed query. It retains bounded private response bytes in memory and shows
only HTTP/transport status, byte count and a provisional count/partiality summary. Unknown shapes
remain unverified. No pagination occurs. The automatic workflow now follows successful listing
with a separate identity-checked fresh list and one detail GET for its first `evaluation` entry;
see `Docs/native-detail-experiment.md`. Only relationship counts and match flags are reported.
`--agent-detail` instead reads history pages until the first `agentic` entry, then GETs
`/api/evaluation/{id}` and `/agent/{id}` for it (1 s apart) and writes counts and key names to
`DerivedData/AgentDetailResult-<slot>.json`; the page bytes go to a git-ignored local candidate file (N-022).

The retained generation experiment implementation, **Test One Native Prompt**, attempted the fixed C-001 prompt once,
following S-002's null-token fallback. See `Docs/conversation-observation-2026-09-22.md`.
It rechecks identity first and retains response callback bytes/offsets/ticks in memory, bounded
at 4 MiB / 4096 callbacks with a 30-second resource timeout. A locally canceled limit is not remote
stop. An optional local response preview is limited to 16 KiB. No parser or completion claim is made.
Rejection never triggers a token acquisition, challenge escalation, or automatic retry.

This experiment now tests Keychain/relaunch restoration; live acceptance remains pending. No refresh
or multi-account persistence is implemented. Stop
on an auth/challenge failure and record its status; do not blindly repeat a login. Test fixtures
for authentication are synthetic; browser generation fixtures have explicit transformed provenance.
Neither proves native generation behavior. `HTTPReply` and
`ObservedIdentity` are in-memory sensitive values, not archival DTOs or logging payloads.
