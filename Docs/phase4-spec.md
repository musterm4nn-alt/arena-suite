# Phase 4 implementation spec — decoding and index

Plan v3 §8, §10, §12, §13 (Phase 4). Definition of done: deleting the index and replaying the
journals reproduces identical entity IDs and content hashes; unknown fields are counted, not lost.
Read AGENTS.md first. Swift 6 language mode, strict concurrency, no new dependencies beyond GRDB
7.11.1 (already declared). Do not modify files outside the list below except where stated.

## Already done (do not change)
- `Packages/ArenaSuiteCore/Package.swift`: targets `ArchiveIndex` (deps SuiteDomain, GRDB) and
  `ApplicationActions` (deps SuiteDomain, CaptureJournal, ArchiveIndex), test target `ArchiveIndexTests`.
- `Packages/ArenaSuiteCore/Sources/SuiteDomain/Archive.swift`: neutral types `RecordRef`,
  `ConversationFacts`, `BlockKind`, `ArchivedBlock`, `ArchivedAttachment`, `ArchivedMessage`,
  `ModelClaim`, `ArchivedFeedback`, `ConversationSnapshot`, `ArchiveEvent`, `DecodedRecord`. Use them.

## 1. `Packages/ArenaSuiteCore/Sources/ArchiveIndex/ArchiveIndex.swift` (new)
`public final class ArchiveIndex: Sendable` wrapping a GRDB `DatabasePool` (WAL, foreign keys on).
GRDB must not appear in any public signature. Account IDs stored as `uuidString` TEXT.

- `public init(url: URL) throws`: create parent dir with 0700, open pool, run migrations, then
  `chmod` the database file to 0600.
- Migration "v1" creates (all keys deterministic; no autoincrement IDs):
  - `meta(key TEXT PK, value TEXT)`
  - `checkpoints(account_id TEXT PK, last_sequence INTEGER NOT NULL)`
  - `conversations(account_id, remote_id, kind, title, mode, modality, visibility, created_at, updated_at, updated_order INTEGER, archived_at, deleted_at, first_seen_seq INTEGER, last_seen_seq INTEGER, latest_snapshot_seq INTEGER, absent_seq INTEGER, PK(account_id, remote_id))`
  - `snapshots(account_id, seq INTEGER, remote_id, segment INTEGER, record_offset INTEGER, record_length INTEGER, updated_at, title, message_count INTEGER, last_message_ids TEXT /*JSON array*/, PK(account_id, seq))`
  - `messages(account_id, snapshot_seq, remote_id, conversation_id, ordinal INTEGER, role, status, lane, model_remote_id, created_at, updated_at, failure_reason, PK(account_id, snapshot_seq, remote_id))`
  - `message_parents(account_id, snapshot_seq, message_id, ordinal INTEGER, parent_id, PK(account_id, snapshot_seq, message_id, ordinal))`
  - `blocks(account_id, snapshot_seq, message_id, ordinal INTEGER, kind, text, tool_name, tool_call_id, payload, pointer, PK(account_id, snapshot_seq, message_id, ordinal))`
  - `attachments(account_id, snapshot_seq, message_id, ordinal INTEGER, name, content_type, has_url INTEGER, PK(...ordinal))`
  - `model_claims(account_id, seq INTEGER, conversation_id, subject, subject_id, role TEXT NOT NULL DEFAULT '', model_id, display_name, organization, provider, source, PK(account_id, seq, subject, subject_id, role, source, model_id))` — use '' for a nil role in the key.
  - `feedback(account_id, snapshot_seq, remote_id, value, message_a, message_b, PK(account_id, snapshot_seq, remote_id))`
  - `unknown_fields(account_id, path, count INTEGER, first_seq INTEGER, last_seq INTEGER, PK(account_id, path))`
  - `warnings(account_id, seq INTEGER, ordinal INTEGER, code, detail, PK(account_id, seq, ordinal))`
  - FTS5 virtual table `search(text, account_id UNINDEXED, conversation_id UNINDEXED, snapshot_seq UNINDEXED, message_id UNINDEXED, kind UNINDEXED)`, tokenizer unicode61 with diacritics removed.
- `public func checkpoint(for account: AccountID) throws -> UInt64` (0 if none).
- `public func projectionVersion() throws -> String?` / stored in `meta` key `decoder_version`.
- `public func apply(account: AccountID, records: [(RecordRef, DecodedRecord)], through sequence: UInt64, decoderVersion: String) throws`
  — ONE write transaction: apply every record in order, then upsert the checkpoint to `sequence`
  and `meta.decoder_version`. Semantics per event (record `seq` = `ref.sequence`):
  - `.listed(facts, claims)`: upsert conversation — on insert set `first_seen_seq`; always overwrite
    the facts columns with non-nil incoming values and set `last_seen_seq = seq`. Insert claims
    (conversation_id = facts.remoteID) with `INSERT OR IGNORE`.
  - `.snapshot(s)`: insert the `snapshots` row (segment/offset/length from ref); messages with
    `ordinal` = array index; parents; blocks (ordinal = block index); attachments; claims; feedback.
    Upsert the conversation facts like `.listed` and set `latest_snapshot_seq = seq`,
    `absent_seq = NULL`. Replace the FTS rows of that conversation (delete all rows for
    account+conversation, insert one row per block of this snapshot whose indexable text is:
    `text` for text/reasoning blocks, `payload` for tool_call/tool_result/sources blocks; skip empty).
  - `.absent(id)`: upsert conversation (kind `"[unknown]"` if new) and set `absent_seq = seq`.
  - `.warning(code, detail)`: insert with ordinal = position among warnings of that record.
  - `unknownFields`: upsert `count = count + n`, `first_seq = min`, `last_seq = max`.
  - If a record's sequence is ≤ the account's current checkpoint, skip it (idempotent replays).
- Queries (public result structs, `Sendable`, `Equatable`):
  - `conversations(account: AccountID?) -> [ConversationSummary]` ordered by `updated_order DESC NULLS LAST, remote_id`.
    Fields: account, remoteID, kind, title, mode, modality, updatedAt, snapshotCount, latestSnapshotSequence, messageCount (of latest snapshot), isAbsent.
  - `conversation(account:remoteID:snapshot: UInt64? = nil) -> ConversationDetail?` (latest snapshot by default):
    summary, snapshotSequences (ascending), messages (ordinal order) each with role, status, lane,
    parentIDs, modelRemoteID, createdAt, blocks (kind, text, toolName, toolCallID, payload), attachments;
    plus claims (all, for that conversation, any seq) and feedback of that snapshot.
  - `search(_ text: String, account: AccountID?, includeReasoningAndTools: Bool, limit: Int) -> [SearchHit]`:
    build the MATCH pattern with GRDB `FTS5Pattern(matchingAllTokensIn:)` (return [] if nil);
    when `includeReasoningAndTools` is false restrict to kind `text`. Hit: account, conversationID,
    title, messageID, kind, snippet (FTS5 `snippet()` with `[`/`]` markers, 12 tokens).
  - `unknownFields(account: AccountID?) -> [(path: String, count: Int)]` (use a small public struct).
  - `counts() -> [String: Int]` rows per table.
  - `contentDigest() -> String`: SHA-256 (CryptoKit) over every row of every table above in a fixed
    table order, each ordered by its full primary key (search: order by all its columns); hash each
    value with a type tag. Exclude nothing except SQLite internal tables. Identical content ⇒ identical digest.

## 2. `Packages/ArenaSuiteCore/Sources/ApplicationActions/ArchiveService.swift` (new)
- `public protocol ArchiveDecoding: Sendable { var version: String { get }; func decode(_ record: JournalRecord, account: AccountID) -> DecodedRecord }`
- `public actor ArchiveService(index: ArchiveIndex, journals: JournalStore, decoder: any ArchiveDecoding, accounts: [AccountID] provider closure)`:
  - `project(_ account: AccountID) async throws -> Int`: read the account journal with
    `JournalReader(root: journals.root(for:))`, decode records with sequence > checkpoint, apply in
    batches of 200 (each batch one `apply` call, `through` = last sequence of the batch). Returns records applied.
    If `projectionVersion()` differs from `decoder.version` (and is not nil), call `rebuild` instead.
  - `rebuild(accounts:) async throws`: delete the database files (`-wal`, `-shm` too) via the index's
    `reset()` (add `public func reset() throws` to ArchiveIndex that drops and recreates all tables in
    one transaction — simpler than deleting files under an open pool), then `project` each account.
  - pass-through queries.
- `JournalStore.root(for:)` already exists (HistorySync.swift).

## 3. `Packages/ArenaProtocol/Sources/ArenaAdapter/Decoders/ArenaArchiveDecoder.swift` (new)
`public struct ArenaArchiveDecoder: ArchiveDecoding`, `version = "arena-decoder/1"`.
Only `exchange` records with metadata `status == 200` and `transfer_end == "complete"` produce events,
except role `detail` with status 404 → `.absent(entry_id)`. Roles: `list`, `detail` (ignore `identity`).
Use `JSONSerialization`. Everything below is the observed shape (N-012):
- list body: top keys `entries, pagination, partial, failedSources`; `pagination` keys `hasMore, cursor, limit`.
  Entry keys: `id, type, title, createdAt, updatedAt, mode, modality, modelAId, modelBId,
  modelAOrganization, modelBOrganization, archivedAt, codingSessionStatus, productMode`.
  → one `.listed` per entry with id; claims: `modelAId` (role "a", organization modelAOrganization)
  and `modelBId` (role "b"), subject `.conversation`, source `history_list`, only when non-null.
- detail body top keys: `id, userId, title, mode, visibility, lastMessageIds, archivedAt, deletedAt,
  deletionPendingProcessing, createdAt, updatedAt, messages, maskedEvaluations, pairwiseFeedbacks,
  pointwiseFeedbacks, revealedModels`. `kind` = metadata `entry_type` or "evaluation".
  - message keys: `id, role, status, content, reasoning, sources, createdAt, updatedAt, evaluationId,
    evaluationSessionId, experimental_attachments, failureReason, metadata, modelId, parentMessageIds,
    participantPosition, activeWorkflowRunId, pairwiseFeedbackId`. `lane` = participantPosition.
  - `content`: string → one `.text` block; array → one block per element by `type`:
    `text` → text; `reasoning` → reasoning (text); `tool-call` → toolCall (toolName, toolCallId,
    payload = canonical JSON of `args`); `tool-result` → toolResult (payload = canonical JSON of
    `result`); other → opaque (payload = canonical JSON of the element). Block keys: `type, text,
    toolCallId, toolName, args, result, providerOptions`. `args`/`result` subtrees are free-form:
    do NOT report unknown keys inside them. `providerOptions` (contains encrypted reasoning) is
    never projected and never reported as unknown.
  - message `reasoning` string → extra reasoning block after content blocks; `sources` array →
    one `.sources` block with canonical JSON payload.
  - attachments (`experimental_attachments`): keys `name, contentType, url` → hasURL = url non-empty.
  - `revealedModels[]` keys `id, name, displayName, publicName, organization, provider, capabilities,
    userSelectable` → claims subject `.conversation`, role nil, source `detail_revealed`.
  - message `modelId` non-null → claim subject `.message` (subjectID = message id), role = lane,
    source `message_model_id`.
  - `pairwiseFeedbacks[]` keys `id, arenaId, messageAId, messageBId, modelAId, modelBId, value` →
    `ArchivedFeedback` and claims subject `.feedback` roles "a"/"b", source `pairwise_feedback`.
  - `maskedEvaluations[]` keys `id, arenaId, modality, metadata`: known, not projected.
  - `pointwiseFeedbacks[]` elements: not projected; any keys inside are reported as unknown paths.
  - **Every subtree under a key named `metadata` is excluded** (anti-abuse telemetry, plan §12):
    not projected, not reported as unknown.
- Unknown field counting: any key not listed at its path → `unknownFields["$.path.key"] += 1`,
  arrays written as `[]` (e.g. `$.messages[].newKey`, `$.entries[].newKey`).
- `updatedOrder`: parse `updatedAt` with the observed format `2026-09-24 10:00:00.123456+00` or ISO
  8601 into microseconds since 1970 (integers only). Reuse `SourceInstant` in
  `ArenaAdapter/History/ArenaHistorySync.swift` (add a `microseconds: Int64` computed property there).
- Canonical JSON: `JSONSerialization` with `[.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]`.
- A `detail` 200 whose body has no string `id` → `.warning("detail_unrecognized", …)`, no snapshot.
- Deterministic: same record ⇒ identical output.

## 4. Tests (Swift Testing)
- `Packages/ArenaSuiteCore/Tests/ArchiveIndexTests/ArchiveIndexTests.swift`: apply synthetic events;
  latest snapshot wins; claims coexist; absent flag; FTS search finds text, excludes reasoning when
  asked, returns [] for garbage patterns; unknown field counts accumulate; replay of already-applied
  sequences is ignored; `reset()` then re-apply ⇒ identical `contentDigest()`; file mode 0600.
- `Packages/ArenaProtocol/Tests/AdapterTests/ArchiveDecoderTests.swift`: decode the committed fixture
  `Fixtures/SanitizedArena/native-detail.fixture.json` (base64 `units[0]` is a detail body; wrap it in
  a synthetic `JournalRecord` via a real temporary `JournalWriter` append + `JournalReader`), check 4
  messages, parent chain, lanes, claims; metadata never produces blocks or unknown paths; a body with
  an extra key reports `$.messages[].newKey`; list body decoding; 404 → absent; determinism.
- End-to-end test (ArenaProtocol tests): write a temporary journal with list + 2 detail exchanges,
  project into a temporary index via `ArchiveService`, record digest, `rebuild`, digest identical.

## 5. Verify
`bash Scripts/test-offline.sh` must pass. Update `Scripts/check-boundaries.py` so
`Packages/ArenaSuiteCore/Sources/ArchiveIndex` may import `Foundation, SuiteDomain, GRDB, CryptoKit`,
ApplicationActions may also import `ArchiveIndex`, and ArenaAdapter may import `ArchiveIndex` only if needed.
Do not commit. Do not touch the app, the journal, or unrelated files.
