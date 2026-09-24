# Arena Suite

A native macOS (ARM64) app that archives your Arena conversation history: it signs in natively,
imports your history into a durable local evidence journal, and lets you browse, search and export it.
It is **read-only**. You keep chatting on arena.ai. Native generation is blocked by reCAPTCHA v3 and
is a separate, conditional track.

- Plan: [`Arena-Suite-Master-Plan-v3.md`](Arena-Suite-Master-Plan-v3.md) (v2 is kept for history)
- Where things stand: [`Docs/status.md`](Docs/status.md)
- Evidence ledger: [`Docs/protocol-ledger.md`](Docs/protocol-ledger.md)
- Journal format: [`Docs/journal-format-v1.md`](Docs/journal-format-v1.md)

## Build and test

Full Xcode, ARM64 macOS, and Python 3 are required. The deployment target is macOS 14.0.

```sh
bash Scripts/test-offline.sh      # unit tests, golden fixture, SIGKILL crash gate, transport probes
bash Scripts/build.sh Debug       # app shell
bash Scripts/build-auth-proof.sh  # disposable Phase 0 research tool (talks to arena.ai when you run it)
```

Offline tests use only synthetic data and loopback traffic; they never contact Arena.

## Layout

- `Packages/ArenaSuiteCore`: `SuiteDomain` values, `CaptureJournal` (Phase 1), `ApplicationActions`.
- `Packages/ArenaProtocol`: `ArenaAdapter`, the only module allowed to know Arena routes.
- `App`: SwiftUI shell.
- `Tools/NativeAuthProof`: disposable Phase 0 research executable, never linked into the app.
- `Tools/CrashHarness`: journal crash gate. `Tools/FixtureHarness`: fixtures and transport probes.
- `Fixtures`: synthetic, sanitized and golden fixtures. Private captures stay outside Git.

Credentials, private captures and build products are ignored by Git.
