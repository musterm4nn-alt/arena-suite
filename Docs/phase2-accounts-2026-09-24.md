# Phase 2 — accounts and sessions

Plan v3 §13, Phase 2. Completed 2026-09-24.

## Acceptance criteria and result

| Criterion (plan §13) | Result |
|---|---|
| Accounts persist across **relaunch** | **Passed (N-011).** Three accounts added in the app; after quit + relaunch all three restored and verified without sign-in. |
| Accounts persist across **rebuild** | **Passed (N-011).** Rebuilt with a new build number (CDHash `183f8ff2…` → `e65c63e3…`); all three restored within seconds, so no Keychain prompt was waiting. Requires the stable signing identity in git-ignored `Config/Signing.local.xcconfig`. |
| Identity **mismatch quarantines** | Saved material for another principal is never sent; a server reply with another principal discards the in-memory session and the saved material and marks the account `quarantined` (adapter tests). Re-signing into an account with a different Arena principal is refused (`principalChanged`). |
| **No request before identity verification** | `ArenaAccountSession` sends only sign-in and `/api/me` until a principal is verified; every other request must use `performVerified`, which refuses with `notVerified` and sends nothing (test). |
| Expiry → re-auth | `/api/me` 401/403 → saved session deleted, state `needsSignIn`, "Sign In…" offered. Transport errors, 429, 5xx, non-JSON → `unreachable`, saved session kept. |

## Design

- `FoundationTransport.AccountHTTPSession` (Arena-agnostic): one ephemeral `URLSession` per account,
  private cookie jar, no URL cache or credential storage, redirects refused, bounded capture declared
  as `captureLimit`, response headers and start/end ticks recorded for Phase 3, prompt cancellation.
- `ArenaAdapter` (`Authentication/`): observed sign-in and identity recipes, `ArenaAccountSession`
  (verification gate), `ArenaAccountSessions` (`AccountSessionProviding`; never shares a transport),
  `KeychainSessionVault` (one item per account, service `ArenaSuite.Account.Session.v1`,
  principal + cookies, never passwords, not synchronized). It uses the legacy login Keychain, which
  **ignores** `kSecAttrAccessible`: prompt-free access is limited by the code-signing ACL, but the item
  is not device-bound (it travels with login-Keychain backups/migration). Moving to the
  data-protection Keychain needs a keychain-access-group entitlement and provisioning profile. Rotated cookies are re-saved after each
  successful verification (Arena re-issues them, N-008).
- `ApplicationActions.AccountService`: registry (`Archive/accounts/registry.json`, `0600`, atomic
  write with full sync), add / sign in again / restore all (concurrent, one request per account) /
  verify / rename / remove; duplicate Arena accounts refused, also under concurrent adds.
  Registry holds display names, principal claims and credential generation — no email or secrets.
- App: Accounts window (add, sign in again, verify, remove with confirmation) and a value-free
  `Archive/diagnostics/accounts-status.json` (local IDs and states only).
  `App/AppComposition.swift` is the only app file allowed to import `ArenaAdapter` (boundary check).

## Tests

Adapter 13 (+ transport 4), account service 10, loopback probe for the production transport
(isolated jars, export/import restore, redirect refusal incl. POST 307/308, gzip, interrupted
prefix, capture limit, cancellation). `Scripts/test-offline.sh` passes; Debug and Release build.

## Not in Phase 2

- No history requests yet (Phase 3 uses `performVerified`).
- Journal records for sign-in/verification events arrive with Phase 3's recorded transport.
- The account-B research slot and proof Keychain items are separate and can be deleted with the
  proof's "Forget Saved Session".
