# ADR 0002 — Provisional Foundation boundary and credential exception

Status: accepted evidence policy; final transport selection pending Q07.

Preserve application bytes at the declared native observation boundary before interpretation.
Foundation data callbacks expose entity bytes, not TLS/HTTP wire framing. Local measurements
show gzip decoding, duplicate-header merging, hidden trailers, and assembled WebSocket messages.
See `../transport-results.md`. If Arena requires hidden data, replace the transport before
production capture; libcurl is conditional, not an unimplemented promise of exact packet capture.

Credential injection occurs after an archived sanitized request description is constructed.
Passwords, OTP/session/Authorization/Cookie/CSRF values, challenge solutions and authentication-only
bodies are omitted from ordinary evidence; record scope/reason/version as `credential_omitted`.
Keychain owns eventual session material. A sanitized request is not authenticated-wire-exact or
replayable. Ordinary non-auth conversation bytes are not subjected to broad text-redaction regexes.
Raw payloads never enter diagnostics. Private fixture originals remain outside Git.
