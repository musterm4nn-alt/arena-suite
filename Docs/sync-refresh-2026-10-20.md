# Unfinished conversations and Refresh (2026-10-20)

A conversation synced while Arena was still generating keeps its unfinished responses, and a vote cast
after a sync is never archived. Arena's history list doesn't change when responses finish or a vote is
cast (ledger N-020), so the incremental rule of plan v3 §9.3 never fetches that conversation again.

The user chose (2026-10-20): Sync History also fetches again a conversation whose latest snapshot is
unfinished, within a bound. A user-clicked **Refresh** fetches one conversation now: for a vote cast
after a sync, or to get its attachments' links fresh.

This comes before attachment downloads (item 2 of `Docs/arena-exporter-gaps-2026-10-19.md`). A
download needs a link less than an hour old (N-019), so it has to follow a detail fetch, and these
fetches change which details are fetched.

## Evidence and assumptions

- **`verified_observation` (N-020):** a detail fetched mid-generation holds both responses with status
  `pending`. The list stayed byte-identical after they finished and after the vote.
- **`assumption`:** `pending` is the only status meaning "still generating". `success`, `failed`,
  `flagged` and `stopped` (all observed) are final. An unknown status is not treated as unfinished,
  so it causes no extra traffic. The app still shows any status other than `success` beside the
  message, as before.
- The detail route is the one already verified (N-007, N-008). No new route, parameter or field.

## Acceptance criteria

1. **Unfinished is derived from the journal.** A conversation is unfinished when its latest valid
   detail snapshot (HTTP 200, complete transfer, a body naming the conversation) has a message whose
   `status` is `pending`. The adapter reads this from the journal, like every other sync decision,
   so it survives relaunch and rebuild. The `pending` value is Arena vocabulary, so it is defined once
   in the adapter (`ArenaArchiveDecoder.unfinishedStatuses`, beside the vote vocabulary) and passed
   to the app.
2. **Sync fetches it again.** A sync (incremental or full pass) fetches again every unfinished
   conversation under the limit, even when its `updatedAt` is unchanged:
   - one listed by this job is fetched like any changed entry, with the `updatedAt` just listed;
   - one the listing didn't reach is fetched by ID after the listed ones (if its count has an
     `updatedAt`, 3). An incremental listing
     stops at the first unchanged page, so older conversations aren't listed. Like a refresh (4),
     its record carries the last listed type and `updatedAt`, marked `entry_type_origin` and
     `source_updated_at_origin` `last_listed`.
   The listing itself is unchanged: its early stop doesn't wait for unfinished entries.
3. **Bounded.** A conversation is fetched again for being unfinished only while it has fewer than 3
   unfinished snapshots in a row for the same `updatedAt` (the first fetch and up to two more). After
   that, sync leaves it until its `updatedAt` changes (the ordinary rule) or the user clicks Refresh.
   A finished snapshot, or a different `updatedAt`, starts the count again. A 404 ends it (the
   conversation is absent; plan §9.5). A request that fails otherwise isn't a snapshot and isn't
   counted. Like any failed detail, the next user-started sync tries it again, one request each
   time.
   - Snapshots a Refresh fetched count too: the limit counts unfinished snapshots, not sync jobs.
   - The sync manifest counts the details fetched again because they were unfinished
     (`detailsRefetchedUnfinished`: valid snapshots that arrived, not requests) and the unfinished
     conversations left alone because of the bound (`unfinishedLeft`). The second is counted
     however the job ends, also when it stops before fetching details. A conversation this job
     listed with a new `updatedAt` isn't counted: the limit no longer holds it. If the job stops
     before listing (at the identity check, say), it is the count from the journal.
   - The count needs an `updatedAt`: a snapshot recorded without one starts no count. Entries
     listed without `updatedAt` keep the earlier rule: a change can't be detected, so sync fetches
     them on every run (with a manifest warning), whatever their state, and also after a 404. When
     the listing doesn't reach one, it isn't fetched by ID. It is never counted as fetched for
     being unfinished or as left at the limit. If the listing stops stating `updatedAt` for a
     conversation that has a count, sync fetches it by ID once more; that snapshot has no
     `updatedAt`, so the count ends there. This predates the milestone and is unchanged. The
     live archive has no such entry (all 338 recorded list entries carry `updatedAt`, counted on
     2026-10-20).
4. **Refresh is one user-clicked job.** It fetches one conversation's detail and nothing else:
   - `job.started` with `job_kind` `conversation_refresh`;
   - the identity check (`/api/me`), journaled as in every job;
   - one detail GET on the observed route, journaled before anything reads it.
   The detail record carries `entry_id`, `entry_type`, and `source_updated_at` with the last
   `updatedAt` listed for it in this account's journal (none if it was listed without one). Because
   this job didn't observe these values, the record says so: `entry_type_origin` and
   `source_updated_at_origin` `last_listed`.

   The job never lists and never retries automatically. A 404 is recorded as absence (plan §9.5).
   401, 403, a challenge and 429/503 are handled as in sync. Only an entry last listed as a kind
   whose detail route is observed can be refreshed (`ArenaHistorySync.refreshableKinds`:
   `evaluation`); anything else is refused before any request.
5. **Same traffic rules as sync.** A refresh is refused (`busy`) while that account syncs or
   refreshes, and while maintenance runs. Sync is refused while a refresh runs. It needs a signed-in
   account, like sync. Requests keep the one-second spacing. When a sync ends, its progress is
   cleared and its manifest kept before another job of that account can start, so a finished job
   never overwrites a newer one's.
6. **Account context.** Refresh takes the account and conversation from the transcript it was
   clicked in, never from the selection. The service also requires the index to hold that
   conversation for that account, with a snapshot, as one of the kinds the adapter passes in
   (`refreshableKinds`); otherwise it refuses (`notRefreshable`) and nothing is written.
7. **After a refresh** the index is updated the same way as after a sync, and the open transcript
   shows the new latest snapshot unless an older snapshot was chosen explicitly. If the index update
   fails, the app says so as after a sync: the index could not be updated, and the journals are
   unaffected.
8. **In the app.**
   - The transcript header has a Refresh button (help: "Fetch this conversation again from Arena,
     for example after voting").
     It is off while that account syncs, refreshes or isn't signed in, for conversations that are
     only listed, and for kinds that can't be fetched again (the service's own rule,
     `canRefresh`).
   - A latest snapshot with an unfinished response says so above the first turn, and that Sync
     History fetches it again a few times or Refresh fetches it now.
   - A refused or failed refresh says why in the sidebar, as a failed sync does: no transcript in
     the archive, an index that couldn't be read, or the job's outcome. A refresh that completed
     (a valid detail, or a 404) clears a session problem still shown for that account if the
     account is signed in, as a Verify does; a 404 still shows its own message. This is rare:
     a session problem usually leaves the account not signed in, and then Refresh is off; signing
     in again clears the message anyway.
9. **Not reachable from MCP.** MCP stays read-only, with no network. `Scripts/check-boundaries.py`
   forbids the MCP sources from naming the refresh.
10. **Tests (adapter, with the scripted transport):**
    - an unfinished snapshot is fetched again on an unchanged list (the listing stops early as
      before);
    - a finished one is then left alone;
    - one the incremental listing doesn't reach is fetched by ID, with the origin recorded, but not
      one recorded without `updatedAt`;
    - the bound: after 3 unfinished snapshots for the same `updatedAt` nothing more is fetched, and a
      new `updatedAt` fetches again and restarts the count;
    - a 404 ends the refetching;
    - an unknown status is not unfinished;
    - state is rebuilt from the journal by a new job;
    - refresh: record kinds and order, exactly two requests, the metadata and its origin, 404 as
      absence, 403 blocked, a non-`evaluation` or unknown entry refused with no request;
    - `busy` against a running sync, and during maintenance;
    - the service refuses a conversation not in the index for that account, one of another kind,
      and an index it can't read.

## Not in this milestone

- Fetching again battles that have no vote. A battle may never get one, so it can't be bounded the
  same way; Refresh covers a vote cast after a sync.
- Attachment downloads (next milestone, on top of this one).
- A Refresh button for many conversations at once.

## Results (2026-10-20)

- **Tests:**
  - `Packages/ArenaProtocol/Tests/AdapterTests/HistorySyncTests.swift` (14 new):
    - an unfinished conversation is fetched again while the list is unchanged, then left alone once
      finished;
    - one the incremental listing doesn't reach is fetched by ID, with `last_listed` recorded;
    - at most three unfinished snapshots for one `updatedAt`, and a new `updatedAt` starts the
      count again;
    - an unknown status, or `stopped` and `failed`, is not unfinished;
    - a 404 ends the refetching;
    - a refresh: identity first, exactly two requests and one pause between them, the record kinds,
      `job_kind`, metadata and both origins; the next sync then completes and fetches nothing;
    - a refresh records a 404 as absence and stops on a 403 (`blocked`);
    - a refresh of a list-only or unknown entry sends and writes nothing;
    - a refresh leaves an interrupted sync for the next sync to resume, and closes an interrupted
      refresh;
    - after the review:
      - an unlisted unfinished conversation stops at the limit too;
      - a sync stopped while listing still counts the unfinished conversations it left;
      - unfinished snapshots a refresh fetched count toward the limit;
      - without `updatedAt`, an unfinished conversation keeps the always-fetch rule, and a refresh
        of it records no `source_updated_at`;
      - a sync closes an interrupted refresh;
    - after the re-review:
      - an unfinished conversation recorded without `updatedAt` that the listing doesn't reach is
        not fetched by ID, and counted neither as fetched for being unfinished nor as left;
      - a conversation at the limit that a sync lists with a new `updatedAt` isn't counted as
        left, even when the sync then stops (403 on the next page);
      - the limit test also checks that nothing is counted as left once the `updatedAt` changes;
    - after the third review:
      - a refetch answered 404 isn't counted as fetched again (the 404 test);
      - an unfinished conversation whose listing stops stating `updatedAt` is fetched by ID once
        more, with no `source_updated_at`, and then no more.
  - `Packages/ArenaProtocol/Tests/AdapterTests/VoteNoteTests.swift` (3 new): the service refuses a
    conversation the index doesn't hold for that account, one of a kind Arena can't fetch again
    (a snapshot recorded as `agentic`), and an index it can't read.
  - `Packages/ArenaSuiteCore/Tests/SuiteDomainTests/HistorySyncServiceTests.swift` (3 new): a refresh
    and a sync of one account exclude each other (and maintenance), other accounts are independent,
    a refresh isn't the account's last sync, it is refused during maintenance and for an unknown
    account, and a refused refresh updates the account's state.
- **Checked by reverting each guard; the named tests then fail:**
  - no refetch of a listed unfinished conversation;
  - no limit, and a count that isn't restarted by a new `updatedAt`;
  - no fetch by ID for unlisted ones, and no limit on them;
  - a 404 that doesn't end the refetching;
  - a refresh without the type check;
  - a refresh that closes an interrupted sync;
  - no `last_listed` origins (`entry_type_origin`, `source_updated_at_origin`), and a refresh
    without `source_updated_at`;
  - a broader status rule (anything but `success`);
  - `unfinishedLeft` not counted when the job starts;
  - the service without the index check, and without `indexUnreadable`;
  - after the re-review: a count started by a snapshot without `updatedAt`; no recount when the
    job ends; a recount that ignores what this job listed; the service without the kind check;
  - after the third review: counting planned refetches instead of arrived snapshots.

  Two tests passed with their guard reverted: the failed request ended their sync early, and they
  checked only counts. They now also check the outcome and the number of requests.
- **Untested** (the app target has no test target, or there is no seam):
  - the Refresh button's reasons, and a completed refresh clearing a session problem (200 or 404);
  - a sync ending while another job of that account starts: the gap is one actor hop, which the
    tests can't hold open. The order is the one the service had before this milestone.
- **Suites and checks:** core 128, adapter 189, MCP 17, all passing; `Scripts/check-boundaries.py`
  (MCP may not name the refresh or the sync engine, with self-tests); Debug build.
- **Review:** `Docs/reviews/2026-10-20-sync-refresh.md` (three runs; the third found it ready).
- **In the app, on a synthetic archive copy** (its one account has no saved session, so nothing can
  reach Arena): a synthetic battle whose two responses are `pending` shows the notice above the
  first turn, and the Refresh button is off because the account isn't signed in. Refresh against
  Arena was not clicked: that is a live request.
