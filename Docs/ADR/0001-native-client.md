# ADR 0001 — Native path is conditional

Status: accepted design decision; live feasibility pending.

One native app process owns an engine actor independent of the main actor. SwiftUI currently
calls only its status method. Closing the last window does not terminate the app; explicit Quit
does. Later UI/MCP actions share the application boundary. No browser transport, daemon,
database, or MCP server is required by this skeleton.

Authorized browser research is evidence collection only. If normal native authentication or
generation is unavailable, document the observed blocker; do not replace the design with a
WebView or a different service API. App signing uses local ad-hoc identity here; hardened runtime
is requested but Xcode may disable it for ad-hoc Debug signing. Development-team signing is
a later packaging configuration, not a reason to weaken TLS or ATS.
