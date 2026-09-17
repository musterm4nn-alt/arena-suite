You are taking over an architecture-planning task from a previous GPT-6 Astra Pro run that was interrupted by provider rate limits and a WebSocket timeout before it could write the final deliverable.

This is a STANDALONE handoff. You have no access to the previous conversation or its files. Everything important from the previous run is summarized below.

Your job is to FINISH THE REPORT, not restart the investigation from scratch.

# PRIMARY TASK

Create a polished, technically rigorous architecture and implementation plan for a private macOS application that embeds/owns a browser environment for Arena (arena.ai), records the owner's Arena conversations accurately, backfills existing history where feasible, stores everything locally with strong provenance and account isolation, exposes essentially all functionality to an LLM through MCP, and later supports local model-behavior analysis.

The final deliverable is:

`arena-model-archive-plan.html`

Do NOT implement the actual archive application.

Create the finished HTML report in the workspace. The report itself is the product of this task.

Do not stop at research notes, an outline, a Markdown report, or a prose answer.

---

# CRITICAL EXECUTION INSTRUCTION

The previous run failed because it repeatedly accumulated ~90k–108k-token contexts while fetching large documentation pages.

DO NOT REPEAT THAT.

You have already been given the important research findings below.

Perform only a SHORT, TARGETED verification pass where necessary.

Rules:

* Do not crawl documentation sites.
* Do not fetch the Arena homepage just to inspect its giant HTML/bundles.
* Do not download enormous raw source trees or protocol specifications when a targeted documentation page suffices.
* Do not perform open-ended web research.
* Prefer the handoff evidence below.
* Re-fetch a source only when needed to confidently support an architecture-defining factual claim.
* Rough target: no more than ~8–12 targeted documentation fetches before you begin writing.
* Once the architecture decision is sufficiently supported, WRITE THE REPORT.
* If some Arena-specific behavior cannot be verified without a signed-in owner session, explicitly label it as unverified and create a falsifiable acceptance test. Do not keep researching indefinitely.
* Do not ask me questions.
* Do not provide calendar/time estimates.

Your priority is to finish a high-quality artifact in this run.

---

# PRODUCT CONTEXT

This is a private macOS productivity/developer-research application centered on Arena, especially Arena Code and Arena conversation surfaces.

The owner wants to use Arena normally inside the application while the application records accurate local transcripts of the owner's own conversations.

Over time the archive should become a searchable local research corpus for studying:

* model behavior;
* prose and formatting habits;
* recurring phrases;
* response structure;
* coding style;
* possible stylistic/model fingerprints;
* variation over time and by prompt type.

This is permanently PRIVATE software for one owner.

There is:

* no App Store submission;
* no public distribution;
* no commercial product;
* no hosted backend;
* no telemetry;
* no cloud analytics;
* no multi-user application account system;
* no public updater infrastructure requirement.

Target hardware:

* Apple Silicon only;
* M3 Pro;
* 18 GB unified memory;
* current machine runs macOS 27.

Choose an explicit minimum supported macOS version separately rather than simply saying macOS 27.

AI coding agents will do most implementation, maintenance, diagnostics, and troubleshooting.

Prefer:

* mainstream dependencies;
* reproducible tooling;
* explicit schemas;
* machine-readable diagnostics;
* tests an agent can execute;
* simple local deployment;
* minimal unnecessary infrastructure.

---

# HARD REQUIREMENT: DEDICATED BROWSER

The application must own/embed its browser runtime or browsing environment.

A conventional browser extension is NOT an eligible primary architecture.

Specifically, do not recommend as the primary solution:

* Manifest V3 extension;
* `chrome.debugger` extension;
* extension + native messaging;
* extension + companion daemon/application.

The owner already has such a recorder:

`https://github.com/musterm4nn-alt/arena-exporter`

It is useful only as the rejected baseline.

Problems experienced with that approach include:

* incomplete/missed capture;
* missing parts of conversations or streams;
* dependence on page/runtime interception;
* extension lifecycle weaknesses;
* awkward artifact/download management;
* need for companion mechanisms.

The new architecture must materially improve the observation/control surface.

Important distinction:

OWNING THE BROWSER WINDOW != HAVING DEEPER CAPTURE PRIVILEGES.

For every architecture, state exactly what capture mechanisms exist outside page JavaScript.

---

# SIMULTANEOUS MULTI-ACCOUNT REQUIREMENT

At least two Arena accounts must be able to remain signed in and usable SIMULTANEOUSLY.

This is not an account switcher.

Each Arena account requires isolated:

* cookies;
* local storage;
* session storage;
* HTTP cache;
* service-worker state;
* browser session/partition;
* capture pipeline;
* authentication authority;
* provenance;
* history sync state;
* destructive-action scope.

One account signing out, expiring, encountering a CAPTCHA, changing identity, or failing synchronization must not corrupt/rebind the other account.

Account/session identity is part of every archived record's provenance.

Cross-account source-ID collisions MUST NOT cause records to merge.

Identical text is not enough to prove two records are the same.

---

# AUTHENTICATION REQUIREMENT

Arena's own authentication UI remains authoritative.

The required workflow is Arena EMAIL-BASED SIGN-IN.

The embedded browser should allow normal owner-driven handling of:

* email verification;
* one-time codes;
* MFA if encountered;
* CAPTCHA/challenges;
* redirects;
* popups.

Google OAuth, passkeys, and other third-party sign-in methods are NOT requirements and must not disqualify a stronger browser architecture.

Do not import cookies/tokens from Safari, Chrome, or other applications.

Browser-managed persistent authentication state may persist in each isolated app-owned browser partition.

Native sync logic may transiently reuse credentials belonging to the correct app-owned Arena session, but copied bearer tokens/cookies must never be persisted into:

* the archive database;
* logs;
* fixtures;
* exports;
* diagnostics.

---

# OWNER-DATA BOUNDARY

This application is for the owner's own Arena accounts and data.

Distinguish carefully between:

1. authenticated first-party reads made using the owner's current Arena session;
2. internal/undocumented first-party endpoints;
3. ordinary browser automation/anti-bot compatibility;
4. actual access-control workarounds.

Do not call every undocumented endpoint a "bypass."

Do not enumerate unrelated private infrastructure or attempt to access other users' data.

A conversation ID or URL alone does not prove ownership.

Every backfill/capture operation must be bound to a verified Arena account/session partition.

---

# PREVIOUS [MODEL] PRO RESEARCH HANDOFF

The previous model DID NOT reach the final architecture decision.

Do not claim that it did.

Electron/Chromium and CEF emerged as the serious dedicated-browser contenders.

The following evidence was gathered.

## Electron / Chromium

Primary source previously inspected:

https://www.electronjs.org/docs/latest/api/debugger

Verified/documented:

* Electron `webContents.debugger` provides an alternate transport for Chrome DevTools Protocol.
* It can attach to a WebContents and receive instrumentation events.
* `debugger.sendCommand(...)` can issue CDP methods.
* Commands can target associated CDP session IDs.
* Therefore Electron provides a main-process-controlled CDP observation surface outside page-world JavaScript.

This establishes browser instrumentation capability, NOT Arena-specific capture correctness.

Primary source:

https://www.electronjs.org/docs/latest/api/session

Verified/documented:

* `session.fromPartition(partition)` creates/retrieves isolated Electron `Session` objects.
* partitions beginning with `persist:` persist browser state.
* separate partitions provide a credible primitive for one persistent Arena browser session per account.
* Electron's Session also exposes download handling via `will-download`.

Use a design resembling:

`persist:arena-<internal-account-partition-uuid>`

Do NOT derive partition names directly from email addresses or other unnecessarily sensitive identifiers.

Each account should have its own Session + associated browser view/window/capture coordinator.

Primary sources inspected:

https://www.electronjs.org/docs/latest/api/service-workers
https://www.electronjs.org/docs/latest/api/service-worker-main

Electron exposes main-process/session APIs for querying and observing service workers.

Again: this does not by itself prove that Arena's actual response streams are capturable from those APIs.

Chromium CDP Network protocol source was also inspected.

Relevant documented resource families include:

* XHR;
* Fetch;
* EventSource;
* WebSocket;
* ordinary HTTP resources.

The Network domain exposes request/response metadata and body-related mechanisms.

CDP target/session attachment should therefore be part of the proposed capture spike, especially for worker/target lifecycle coverage.

If you use mechanisms such as target discovery/auto-attachment, verify the exact current CDP method before presenting it as a Verified Fact.

Electron security guidance was inspected.

Recommended renderer posture should include at least:

* `nodeIntegration: false`;
* `contextIsolation: true`;
* Chromium/Electron sandboxing where compatible;
* a very small preload bridge or ideally no privileged bridge in Arena-controlled content;
* navigation/new-window restrictions;
* no archive/MCP/key access from Arena renderers.

Useful source:

https://www.electronjs.org/docs/latest/tutorial/security

### Important implication

Electron is the likely pragmatic v1 choice because it combines:

* Chromium behavior;
* direct CDP;
* per-account persistent Session partitions;
* service-worker/session introspection;
* direct download control;
* mature JavaScript/TypeScript ecosystem;
* comparatively easy autonomous maintenance by coding agents.

However, this was not empirically proven against authenticated Arena traffic.

Authenticated capture MUST remain an acceptance gate.

---

# CEF RESEARCH HANDOFF

CEF was also investigated and has a potentially deeper network interception primitive.

Relevant source:

https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_resource_request_handler.h

Documented behavior observed in the header:

`CefResourceRequestHandler` operates on browser resource requests on the IO thread.

Its callbacks note that `browser` and `frame` may be NULL for requests originating from:

* service workers;
* `CefURLRequest`.

Critically, CEF provides:

`GetResourceResponseFilter(...)`

returning a `CefResponseFilter`, allowing resource response content to be filtered/observed.

CEF therefore offers a credible native response-body interception path that may cover requests originating outside ordinary page frames, including service-worker-originated requests.

This is a meaningful advantage to discuss.

Other CEF sources consulted included request-context headers and general usage documentation.

However, CEF carries substantially greater implementation/maintenance cost:

* C++/Obj-C++ integration;
* larger native build surface;
* framework bundling;
* Chromium/CEF version management;
* more difficult build/debug environment;
* greater burden for AI coding agents;
* likely more bespoke UI/app integration than Electron.

The report should directly compare Electron CDP vs CEF native response filtering.

A sensible decision rule is:

* prefer Electron for v1 IF the capture falsification spike proves required Arena streams, worker/service-worker traffic, navigation lifecycle, downloads, and multi-account isolation can be captured reliably;
* escalate to CEF if Electron's maintained public CDP/session surfaces cannot provide the required capture completeness but CEF's native resource filtering can.

Do not hide this reversal condition.

---

# WKWEBVIEW RESEARCH HANDOFF

Native Swift + WKWebView was considered.

Relevant sources:

https://developer.apple.com/documentation/webkit/wkurlschemehandler

and WebKit's public header:

https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewConfiguration.h

The public configuration surface exposes `WKWebsiteDataStore`, useful for website state.

However:

`WKURLSchemeHandler` is for custom URL schemes.

The WebKit header explicitly says an exception is thrown when attempting to register a handler for a URL scheme WebKit handles internally.

Therefore it is NOT a general-purpose interception hook for normal Arena HTTPS traffic.

Also, separate `WKProcessPool` instances are no longer a useful modern isolation primitive; the property has been deprecated with the note that creating multiple instances no longer has an effect.

Do not imply that native Swift/WKWebView provides magically deeper network capture merely because it is native.

It may offer lower runtime duplication and strong macOS integration, but its public network interception surface appears substantially weaker for this project's core requirement.

---

# TAURI / WRY RESEARCH HANDOFF

Source consulted:

https://v2.tauri.app/reference/webview-versions/

On macOS, Tauri/Wry relies on the system WebKit webview.

Therefore Tauri's small application/runtime footprint is attractive, but it fundamentally inherits many of WKWebView's capture limitations unless substantial native/custom interception machinery is added.

Do not select Tauri merely because it is lightweight.

Capture correctness is the first priority.

---

# DEPARTURE MONO RESEARCH HANDOFF

The previous run successfully inspected the official site:

https://departuremono.com/

The page describes Departure Mono as a monospaced pixel font by Helena Zhang under the SIL OFL.

The site's official stylesheet contained:

`@font-face { font-family: Departure Mono; src: url(/assets/DepartureMono-Regular.woff2) format("woff2"), url(/assets/DepartureMono-Regular.woff) format("woff"), url(/assets/DepartureMono-Regular.otf) format("opentype"); ... }`

Thus the official-site asset path for the WOFF2 resolves to:

https://departuremono.com/assets/DepartureMono-Regular.woff2

Use Departure Mono as the primary report typeface.

Prefer WOFF2.

Include reasonable monospace fallbacks.

If remote font loading fails in the rendered environment, keep the report usable and disclose the fallback rather than inventing a different font source.

---

# SQLCIPHER RESEARCH HANDOFF

Source inspected:

https://www.zetetic.net/sqlcipher/design/

SQLCipher is a modified SQLite build providing transparent page-level database encryption.

The documented design includes encrypted database pages and integrity protection.

The product requirement is:

* generate a random archive encryption key;
* protect that key using macOS Keychain;
* use SQLCipher for the main database unless you identify a genuinely stronger practical alternative;
* do not use a human password as the primary archive key merely because SQLCipher supports passphrases.

Also address:

* WAL/journal files;
* FTS/search indexes;
* temporary files;
* large artifacts;
* exports;
* crash logs;
* fixtures;
* Spotlight;
* Time Machine/backups;
* swap and unavoidable OS-level residual exposure.

Do not promise impossible perfect deletion of external backups or already-exported files.

---

# MCP RESEARCH HANDOFF

Source inspected:

https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

The MCP specification documents:

* stdio;
* Streamable HTTP;

and recommends stdio support where possible.

For this private local app, strongly consider a local MCP server using stdio as the default trusted agent interface.

You may optionally justify a loopback-only HTTP transport if it provides an important operational advantage, but do not expose privileged archive operations to the LAN.

GUI and MCP must share the same application service layer rather than implement different behavior.

---

# ARENA RESEARCH HANDOFF

Relevant Arena Help Center pages previously consulted included:

https://help.arena.ai/articles/7258407731-arena-how-to-create-an-account

https://help.arena.ai/articles/5701270322-arena-how-to-code-arena

https://help.arena.ai/articles/8802082719-arena-archive-chat

The previous run concluded that Arena documentation supports:

* account-backed history;
* email/account workflows;
* Code Arena conversations/output concepts.

BUT:

NO authenticated Arena browser was connected during the previous run.

Therefore the previous run DID NOT verify:

* actual current Arena history endpoints;
* pagination APIs;
* stream transport;
* WebSocket vs SSE vs streamed fetch for each mode;
* exact message schema;
* model/reveal payload fields;
* mutation/read semantics;
* authenticated backfill endpoints;
* worker/service-worker involvement in the real application.

DO NOT INVENT THESE.

The final report must say that authenticated owner-session capture and replay remain empirical acceptance gates.

---

# ARCHITECTURE DECISION YOU MUST COMPLETE

Make the actual recommendation now.

Unless a short targeted verification reveals a concrete contradiction, the expected direction is:

## Recommended v1

Electron + Chromium, using TypeScript for the application/service layer.

Core browser design:

* one persistent Electron Session partition per Arena account;
* separate BrowserWindow/WebContents context per active account;
* attach CDP capture as early as practical;
* observe target lifecycle, requests/responses, streaming mechanisms, WebSocket frames where applicable, worker/service-worker targets where available;
* use Electron Session APIs for account/browser isolation and download handling;
* use minimal DOM/page instrumentation only as secondary evidence, not as the primary transport capture mechanism;
* reconcile browser/network evidence with rendered UI evidence.

## Escalation

CEF is the primary architectural fallback if the falsification spike demonstrates that Electron/CDP cannot reliably observe an architecture-critical class of Arena traffic and CEF's native resource response filtering solves that gap.

A custom Chromium fork is a LAST-RESORT escalation only.

Do not recommend it unless a specific required capability is impossible through maintained Electron/CEF surfaces.

## Other major technologies

Recommend a coherent concrete stack, likely along these lines unless you have a strong reason to alter it:

* Electron;
* TypeScript;
* a small internal application-service layer;
* SQLCipher-backed SQLite;
* macOS Keychain for the random archive key;
* FTS5 or equivalent local full-text search inside the encrypted DB;
* filesystem-backed encrypted large-object storage where appropriate rather than bloating the DB indefinitely;
* stdio MCP server;
* deterministic local statistical analysis in v1;
* no embeddings/large local ML dependency until an explicit empirical gate justifies it.

Choose actual libraries/bindings carefully and discuss native-module/build risk without inventing version numbers.

---

# PROCESS / TRUST MODEL TO DESIGN

The remote Arena renderer is UNTRUSTED content.

It must not have direct access to:

* archive database;
* encryption keys;
* filesystem;
* MCP server;
* Node;
* application services;
* privileged IPC;
* destructive archive actions.

A useful logical separation is:

1. Electron main/browser process
2. isolated Arena renderer per account partition
3. capture coordinator per account
4. sanitizer/parser pipeline
5. local application services
6. encrypted storage
7. MCP process/interface
8. minimal local diagnostics UI
9. optional analysis worker

Make IPC allowlisted and strongly typed.

Archived Arena prompts/responses/tool traces are untrusted DATA.

They can never authorize destructive application actions.

---

# CAPTURE MODEL

Design discovery as a maintained product capability.

Create a machine-readable protocol catalog containing concepts such as:

* operation/adaptor identity;
* first-party origin;
* owning account/session partition;
* observed URL family without persisted secrets;
* method where safe;
* transport class;
* read vs suspected mutation vs unknown;
* request/response schema family;
* parser/adapter version;
* first/last observed timestamp;
* capture mechanism;
* sanitization status;
* confidence/evidence status;
* drift status;
* completeness notes.

Broadly inventory first-party traffic encountered during supported workflows, but do NOT persist a credential-dumping HAR.

Credentials and sensitive headers must be sanitized BEFORE durable persistence.

Explicitly exclude:

* authorization headers;
* cookies;
* CSRF secrets;
* passwords;
* OTPs;
* OAuth codes;
* bearer tokens;
* sensitive signed URLs/query parameters;
* unrelated private response fields.

Retain only enough sanitized raw evidence for:

* parser debugging;
* drift detection;
* reparsing;
* provenance.

---

# INITIAL TEXT RELEASE

The first complete release must handle:

* Arena battle;
* direct-model conversations;
* side-by-side modes;
* completed responses;
* stopped responses;
* failed responses;
* partial responses;
* conversations opened from history;
* archived/history views;
* search/pagination when observable;
* selected model labels;
* blind labels/participant positions;
* votes;
* post-vote model reveals;
* titles;
* timestamps;
* Arena source IDs;
* branches;
* revisions;
* regenerations;
* completion/capture state;
* source/provenance;
* owning Arena account/session.

Do NOT flatten everything into an alternating user/assistant transcript.

Preserve the comparison/branch structure.

---

# CAPTURE COMPLETENESS MODEL

Define states that do not confuse:

* response completed normally;
* response intentionally stopped;
* model/backend failure;
* network interruption;
* observer missed beginning;
* observer missed ending;
* parser unsupported;
* schema drift;
* UI-only reconstruction;
* backfilled result;
* live capture;
* conflicting evidence.

Never silently label inferred/partial content as complete.

Include confidence/provenance.

---

# RECONCILIATION

Network evidence and rendered DOM/UI evidence should be separate observations that can be reconciled.

Design idempotent ingestion.

Potential observations may arrive:

* more than once;
* out of order;
* after navigation;
* after reconnect;
* after a model reveal;
* during an overlapping history sync.

Do not overwrite stronger historical provenance with newer weaker inference.

A reveal event should add an identity observation rather than retroactively pretending the model name was known earlier.

---

# MODEL IDENTITY

Keep distinct:

* participant position A/B;
* blind Arena label;
* selected marketing model;
* provider label;
* route/model string;
* post-vote revealed identity;
* owner annotation;
* inferred stylistic identity.

Do not equate these silently.

Store identity observations with:

* source;
* applicable account;
* conversation/turn/participant scope;
* timestamp;
* evidence mechanism;
* confidence/completeness.

Inferred model identity from text must NEVER overwrite observed/revealed identity.

---

# HISTORY BACKFILL

Treat backfill separately from live capture.

Compare:

* observed history/list/detail responses;
* replaying verified authenticated read operations in the owner session;
* UI traversal;
* rendered-page capture;
* official export if one exists in future;
* user-imported archive;
* future documented API.

Preferred strategy:

If the capture/discovery phase identifies stable authenticated owner-history LIST and DETAIL reads and empirically verifies that they are non-mutating and correctly account-bound, use those operations as the primary sync adapter.

Fallback:

automated browser/UI traversal + capture, with visibly lower completeness guarantees.

Do not call an endpoint read-only merely because it uses GET or has a friendly name.

Verify absence of mutation in an owner-session acceptance test.

Sync must support:

* one selected account;
* multiple selected accounts;
* per-account progress;
* per-account checkpoint;
* cancellation;
* resume;
* bounded retries;
* idempotent page processing;
* overlap/repeated-page handling;
* auth expiry;
* challenges;
* rate limiting;
* source-ID collisions;
* live-capture overlap;
* partial histories;
* drift.

If two accounts can sync concurrently safely, say why.

Otherwise schedule independently without sacrificing correctness.

"Synchronized" must have a precise per-account meaning and expose known coverage gaps.

---

# DATA MODEL

Provide enough concrete schema/relationships for an implementation agent.

At minimum represent:

* arena_account
* browser_partition/session
* conversation
* branch
* turn
* revision/generation
* participant
* identity_observation
* source_observation
* capture/completeness state
* vote/reveal where appropriate
* artifact/attachment
* sync_cursor/checkpoint
* protocol_catalog entry
* parser/adapter version
* analysis_run
* analysis cohort/result

Use internal UUIDs as stable local identities.

Keep Arena source IDs as scoped source identifiers rather than universal primary keys.

Account scope should participate in uniqueness rules where appropriate.

Choose a proportionate source-of-truth design.

A hybrid such as:

normalized current state
+
sanitized immutable-ish observations needed for provenance/reparse

is preferable to gratuitous full event sourcing unless you can justify the latter.

Explain:

* transactions;
* crash recovery;
* schema migration;
* parser reprocessing;
* backup/restore;
* deletion cascades;
* FTS updates;
* artifact lifecycle.

---

# ENCRYPTION / LOCAL DATA

Use:

random archive key -> macOS Keychain -> SQLCipher DB

Do not persist the archive key in config.

For large artifacts, propose a practical encrypted blob format/store using keys derived from or wrapped by the archive key.

Explain plaintext exposure realistically.

Browser profile data itself may contain Arena authentication cookies because persistent sign-in requires it.

That browser-managed state is materially different from deliberately copying credentials into the research archive.

Explain how browser profile directories are protected by OS account permissions and what residual risk remains.

---

# DELETION

Support:

* delete one archived conversation;
* delete all local archive data associated with one Arena account;
* delete the whole local archive.

Deletion must not automatically delete the owner's Arena cloud conversations unless a future feature explicitly performs a separate remote operation.

Account-wide/archive-wide deletion requires a trusted explicit user directive, not something found in archived content.

Use a mechanism such as a two-step destructive intent token:

1. trusted client asks for deletion preparation;
2. server returns exact scope + nonce/confirmation token;
3. trusted client must submit that token with an explicit destructive command.

Archived content cannot mint or satisfy the authorization.

Discuss:

* DB rows;
* source observations;
* FTS;
* analysis derivatives;
* blobs;
* sync checkpoints;
* dedup markers;
* future re-sync behavior;
* backups and exports.

---

# MCP / FULL LLM OPERABILITY

The LLM interface is PRIMARY.

Everything available in the GUI must have an equivalent machine interface unless it is literally an owner interaction with the remote Arena webpage itself.

Design a concrete local MCP contract.

Prefer stdio.

Include compact but real tool/resource families for:

* accounts.list
* accounts.get
* browser.open/account activate
* recording.start
* recording.pause
* recording.resume
* recording.stop
* capture.status
* conversations.search
* conversations.get
* conversations.transcript
* provenance.get
* sync.start
* sync.status
* sync.cancel
* sync.resume
* jobs.list/get
* protocols.list/get
* diagnostics.status
* diagnostics.capture_gaps
* diagnostics.drift
* analysis.profile.run
* analysis.runs.get
* export.create
* export.status
* archive.delete_conversation
* archive.prepare_delete_account
* archive.confirm_delete_account
* archive.prepare_delete_all
* archive.confirm_delete_all

You may improve naming/organization.

Do not generate 100 repetitive schemas.

Instead:

* provide a full inventory;
* define common envelopes;
* then show representative JSON contracts for several important tools.

Explicitly define:

* account/session scope;
* pagination;
* IDs;
* error categories;
* jobs;
* progress;
* cancellation;
* idempotency;
* capabilities/unavailable reason;
* destructive authorization.

---

# LOCAL ANALYSIS

All transcript analysis runs locally.

Start with deterministic, transparent statistics.

Profiles may include:

* response length;
* paragraph/sentence length;
* code-block length;
* lexical diversity;
* recurring n-grams;
* punctuation;
* casing;
* Markdown habits;
* headings;
* list/table usage;
* citation patterns;
* code/prose ratio;
* opening phrases;
* transitions;
* conclusions;
* qualifications;
* hedging;
* refusal/apology language;
* uncertainty markers.

Allow stratification by:

* model identity evidence;
* mode;
* prompt type;
* topic;
* language;
* date;
* conversation context;
* Arena account if relevant to sampling.

Every profile should reveal its cohort and sample counts.

Discuss major confounders:

* one-user selection bias;
* repeated prompting habits;
* topic;
* conversation context;
* Arena hidden prompts;
* model system prompts;
* decoding parameters;
* tools;
* routing;
* aliases;
* temporal model updates;
* safety layers;
* Arena post-processing.

Embeddings/local ML are optional future additions only after an empirical gate shows deterministic methods are insufficient.

Do not add heavyweight ML to v1 merely because it sounds sophisticated.

---

# LATER MODEL-FINGERPRINTING EXPERIMENTS

Treat stylistic similarity as a hypothesis, never proof of model identity.

Require:

* held-out conversations;
* leakage-resistant splits;
* branches/near-duplicates kept in the same split;
* prompt/topic controls;
* negative controls;
* calibration;
* unknown-class rejection;
* temporal validation;
* reproducible preprocessing;
* preserved observed-vs-inferred identity separation.

Do not invent a universal minimum sample threshold.

Let empirical power/stability analysis determine whether an experiment is worth continuing.

---

# LATER MODALITIES

Text first.

Show extension points for:

1. search responses and citations;
2. Arena Code/web-dev generated files, previews, DB metadata, tool events;
3. images + metadata;
4. video/workflow artifacts;
5. agent sessions + tool traces;
6. uploads and derived artifacts.

Avoid building a gigantic universal content framework in v1.

Use shared observation/artifact provenance primitives plus modality-specific adapters.

---

# ARCHITECTURE COMPARISON REQUIRED

The report must still compare:

* Swift + WKWebView;
* Electron/Chromium;
* Tauri/Wry/WebKit;
* CEF;
* browser extension + native companion as rejected baseline;
* explicit export/import without embedded browser.

Give credible alternatives fair treatment.

DO NOT use arbitrary numerical scores.

Compare qualitatively across:

* HTTPS response-body visibility;
* fetch/XHR;
* streamed responses;
* EventSource;
* WebSocket;
* worker/service-worker coverage;
* target lifecycle;
* early attachment;
* DOM instrumentation;
* account/session isolation;
* email authentication compatibility;
* downloads/artifacts;
* security boundary;
* Apple Silicon;
* memory/runtime footprint;
* build complexity;
* agent maintainability;
* drift diagnostics;
* capture depth vs existing extension.

Spend most report detail on Electron vs CEF because those are the serious contenders.

---

# FIRST FALSIFICATION SPIKE

This must be one of the strongest sections.

The first engineering spike should attempt to DISPROVE Electron's suitability.

Before building the full application, implement a minimal dedicated-browser harness that tests:

1. Arena email sign-in works.
2. Account A and Account B can remain logged in simultaneously using separate persistent Session partitions.
3. Cookie/local-storage/cache/service-worker state does not leak across partitions.
4. CDP can attach before/through relevant Arena navigation.
5. Fetch/XHR traffic is observable.
6. Streamed response content can be reconstructed where Arena uses streams.
7. WebSocket frames are observable if Arena uses WebSockets.
8. Worker/service-worker related traffic does not disappear silently.
9. Capture survives navigation/target changes.
10. stopped/failed/partial Arena generations are distinguishable.
11. late model-reveal/vote evidence can be associated correctly.
12. downloads/generated artifacts can be captured directly.
13. no credentials are retained by the sanitizer.
14. disconnecting/signing out Account A does not damage Account B.
15. compare the same workflow against the existing extension when practical.

Define machine-checkable outputs.

Example:

* capture manifest;
* event counts;
* source/target IDs;
* sanitized payload hashes;
* response reconstruction digest;
* expected-vs-observed workflow markers;
* gaps list.

Do not claim success because a page simply loads.

## Reversal gate

If Electron cannot reliably capture an architecture-critical traffic class through maintained CDP/session mechanisms, perform a focused CEF spike using native resource response filtering.

If CEF demonstrably solves the missing observation, switch architecture.

If neither maintained Electron nor CEF can meet the requirement, only then investigate more invasive Chromium customization.

---

# BACKFILL GATE

Authenticated history replay was NOT verified previously.

Treat this as a separate falsification gate.

The test must prove:

* operation belongs to current authenticated account;
* listing behavior;
* pagination;
* conversation detail retrieval;
* read-only/non-mutating behavior;
* checkpoint/resume;
* overlap handling;
* account isolation;
* auth expiry behavior;
* completeness boundaries.

Opening one known conversation does NOT prove backfill viability.

---

# ACCEPTANCE-GATED IMPLEMENTATION SEQUENCE

Organize the plan around evidence, NOT weeks/months.

Do not give calendar estimates.

Use phases such as:

Phase 0 — reproducible toolchain and fixture harness
Phase 1 — dedicated-browser falsification spike
Phase 2 — sanitized observation/protocol catalog
Phase 3 — normalized live text capture vertical slice
Phase 4 — encrypted archive/search
Phase 5 — authenticated backfill validation + sync
Phase 6 — full v1 text-mode coverage
Phase 7 — MCP completeness + diagnostics
Phase 8 — deterministic model profiles
Phase 9+ — later modalities / fingerprinting experiments

For each significant phase include:

* purpose;
* deliverables;
* prerequisites;
* machine-checkable acceptance criteria;
* falsifying evidence;
* continue/change/stop decision.

---

# TESTING

Separate:

## Synthetic tests

Use generated fixtures for:

* stream chunk splitting;
* duplicate/out-of-order events;
* reconnect;
* truncated streams;
* parser drift;
* sanitizer failure;
* account-ID collisions;
* DB crash recovery;
* deletion;
* migration;
* corrupted encrypted blobs.

## Platform tests

Test documented Electron/CDP/session behavior independently of Arena.

## Authenticated owner-session Arena acceptance tests

Needed for claims about:

* real stream protocols;
* capture completeness;
* model reveals;
* auth flows;
* backfill;
* simultaneous account use.

Synthetic tests cannot substitute for owner-session evidence.

Do not put real credentials or raw owner traffic into fixtures.

---

# FAILURE BEHAVIOR

Failure should be scoped as narrowly as possible.

Examples:

* one parser drifts -> retain sanitized unknown observation, mark adapter degraded;
* one account signs out -> pause that account's sync/capture authority;
* one account gets CAPTCHA -> expose NEEDS_OWNER_INTERACTION for that account;
* rate limiting -> bounded backoff for that account/job;
* account identity changes -> halt/rebind only after explicit verification;
* ambiguous source ID -> create conflict, never cross-account merge;
* sanitizer failure -> fail closed for durable raw evidence;
* DB unavailable -> stop durable ingestion rather than silently pretending capture succeeded;
* MCP client disconnect -> long-running jobs have explicit defined continuation/cancellation semantics.

---

# EVIDENCE LABELS

Use these exact concepts throughout the report:

**Verified fact**
Supported by primary documentation actually consulted during THIS run or direct observation during this run.

**Strong inference**
Evidence makes the claim likely but an architecture-relevant confirmation is missing.

**Hypothesis to test**
Requires an explicit empirical test.

**Recommendation**
An architectural decision based on the evidence.

**Unknown**
Evidence does not currently establish the answer.

IMPORTANT:

The research handoff I gave you is from a PREVIOUS RUN.

If you want to label something `Verified fact` in your final report, perform a quick targeted re-fetch of the relevant primary source during this run.

Otherwise describe it as previous-run evidence / strong inference, or verify it now.

Never pretend owner-session tests happened.

---

# SOURCE DISCIPLINE

Prefer primary sources.

Useful fixed source list:

Electron debugger:
https://www.electronjs.org/docs/latest/api/debugger

Electron Session:
https://www.electronjs.org/docs/latest/api/session

Electron ServiceWorkers:
https://www.electronjs.org/docs/latest/api/service-workers

Electron ServiceWorkerMain:
https://www.electronjs.org/docs/latest/api/service-worker-main

Electron security:
https://www.electronjs.org/docs/latest/tutorial/security

Chrome DevTools Protocol:
https://chromedevtools.github.io/devtools-protocol/

CEF:
https://github.com/chromiumembedded/cef/wiki/GeneralUsage

CEF request handler:
https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_resource_request_handler.h

WebKit configuration:
https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewConfiguration.h

Apple WKURLSchemeHandler:
https://developer.apple.com/documentation/webkit/wkurlschemehandler

Tauri webview versions:
https://v2.tauri.app/reference/webview-versions/

SQLCipher design:
https://www.zetetic.net/sqlcipher/design/

MCP transports:
https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

Departure Mono:
https://departuremono.com/

Arena account help:
https://help.arena.ai/articles/7258407731-arena-how-to-create-an-account

Arena Code help:
https://help.arena.ai/articles/5701270322-arena-how-to-code-arena

Arena archive help:
https://help.arena.ai/articles/8802082719-arena-archive-chat

Existing rejected extension baseline:
https://github.com/musterm4nn-alt/arena-exporter

Do not fetch every source merely because it is listed.

Use only the sources required to support consequential claims.

Include a source register in the report separating:

* sources actually consulted during this run;
* useful follow-up references not consulted.

---

# FINAL HTML ARTIFACT

Create:

`arena-model-archive-plan.html`

It must be a complete semantic HTML document.

Use Departure Mono as the primary typeface.

The report should look deliberately designed, not like raw Markdown rendered into HTML.

Aim for a professional technical/research aesthetic suitable for a serious architecture document.

Useful presentation elements may include:

* strong title/summary;
* architecture decision banner;
* sticky or compact table of contents;
* architecture diagram using HTML/CSS/SVG;
* trust-boundary diagram;
* account/session partition diagram;
* capture pipeline diagram;
* comparison tables;
* evidence badges that do not rely on color alone;
* schema snippets;
* MCP contract examples;
* state machines;
* acceptance-gate tables;
* risk/reversal table;
* source register.

Do not overload it with decoration.

No giant hero marketing page.

The actual architecture argument matters most.

Responsive behavior:

* comfortable laptop width;
* narrow-window/mobile readable;
* horizontal tables handled gracefully;
* accessible contrast;
* semantic heading hierarchy;
* keyboard-friendly navigation;
* useful printing/PDF CSS.

Do not rely on color alone to distinguish evidence labels.

Escape any external/source text that could be untrusted.

Avoid unnecessary JavaScript.

---

# REPORT STRUCTURE

You may choose the exact headings, but the finished report should make this story easy to follow:

1. Executive architecture decision
2. What is verified vs unknown
3. Why Electron is recommended / exact reversal condition
4. Electron vs CEF focused comparison
5. Other alternatives and why they lose
6. Process + trust architecture
7. simultaneous multi-account partition design
8. discovery/protocol catalog
9. live-capture architecture
10. capture completeness/reconciliation
11. history synchronization
12. normalized data/provenance model
13. model identity evidence
14. encryption/security/deletion
15. MCP/LLM interface
16. deterministic analysis
17. later fingerprinting experiments/modalities
18. evidence-gated implementation sequence
19. testing/falsification plan
20. major risks + detection + fallback + capability loss
21. source register

Do not merely mirror this checklist mechanically if a better narrative exists.

---

# IMPORTANT IMPLEMENTATION DETAILS TO INCLUDE

The report should be specific enough that an AI coding agent can start the first spike.

Include a plausible repository/component layout, for example:

* apps/desktop
* packages/browser
* packages/capture
* packages/protocol
* packages/domain
* packages/storage
* packages/sync
* packages/mcp
* packages/analysis
* packages/test-fixtures

or a better structure you justify.

Identify process boundaries and module ownership.

Give representative TypeScript interfaces/pseudocode for:

* account partition descriptor;
* sanitized observation;
* protocol catalog entry;
* capture completeness;
* normalized conversation/participant;
* identity observation;
* sync checkpoint;
* job status;
* destructive action intent.

Do not implement the application.

The snippets exist only to make the architecture unambiguous.

---

# MINIMUM MACOS VERSION

Choose and justify a concrete minimum.

Do NOT blindly set macOS 27 simply because the development machine uses it.

Consider:

* Electron/Chromium support;
* Apple Silicon;
* Keychain APIs;
* required native dependencies;
* deployment simplicity.

Because this is private software, there is no need to support very old macOS releases.

State the exact minimum and why.

---

# RESOURCE USE

The owner has an M3 Pro with 18 GB unified memory.

Avoid inventing benchmark numbers.

Discuss measurement instead:

* per active Arena partition renderer memory;
* main-process memory;
* capture queue size;
* encrypted database growth;
* artifact storage;
* concurrency limits;
* background sync load.

Use configurable practical quotas/backpressure rather than fabricated capacities.

At least two Arena sessions must remain usable simultaneously.

---

# DEFINITION OF DONE

Before stopping, verify that `arena-model-archive-plan.html` actually exists.

Inspect it if your environment provides preview/rendering.

Check that it contains:

* a single clear recommended architecture;
* explicit CEF reversal condition;
* dedicated-browser design;
* materially deeper-than-extension capture strategy;
* simultaneous account isolation;
* exact capture mechanisms;
* no invented Arena protocol;
* authenticated acceptance gates;
* live capture;
* backfill;
* data/provenance schema;
* model identity handling;
* SQLCipher/Keychain design;
* security/trust boundaries;
* complete MCP feature inventory;
* destructive-action guard;
* analysis plan;
* later modalities;
* acceptance-gated implementation plan;
* source register;
* evidence labels;
* Departure Mono;
* responsive/printable HTML.

Also check:

* browser extension is NOT the recommendation;
* Google OAuth/passkeys are NOT treated as requirements;
* no claim that authenticated Arena capture was already verified;
* no claim that an endpoint is read-only without owner-session testing;
* no calendar estimates;
* no TODO/placeholders;
* no unresolved architecture menu;
* no fabricated benchmarks;
* no fabricated citations;
* no huge irrelevant appendix generated merely to inflate completeness.

FINISH THE ARTIFACT IN THIS RUN.

Do not return to broad research after you have enough evidence to decide.

The report, not the research process, is the objective.
