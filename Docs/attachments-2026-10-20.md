# Attachment downloads (2026-10-20)

Plan v3 §9.4, item 2 of `Docs/arena-exporter-gaps-2026-10-19.md`. A conversation's detail lists
its attachments (`messages[].experimental_attachments[]`) with a name, a content type and a link.
Until now the archive kept the name and type and whether a link existed, never the file.

The links are signed when Arena serves the detail and work for an hour (N-019), so a file can only
be downloaded right after a detail fetch. This milestone downloads them there: in a sync and in a
Refresh (`Docs/sync-refresh-2026-10-20.md`).

## Evidence and assumptions

- **`verified_observation` (N-019):**
  - all 138 recorded attachments are images with an `https` link on
    `messages-prod.<id>.r2.cloudflarestorage.com`, path `/<id>/<id>.<ext>`;
  - each link carries an S3 presigned query with `X-Amz-Date` (when Arena signed it, 0–5 s before
    the record) and `X-Amz-Expires` (`3600` in all 138);
  - one fresh link downloaded natively without cookies or credentials, redirects refused: `200`,
    `Content-Type` as declared, `Content-Length` equal to the bytes received.
- **`assumption`:** a link stops working `X-Amz-Expires` seconds after `X-Amz-Date` (the S3
  presigned-URL rule). All 138 recorded links had expired when counted; what R2 answers to an
  expired link is not observed. The app uses this rule only to skip a request that would fail
  and to explain a missing file, never to state what the server did.
- **`assumption`:** an object key (the link without its query: scheme, host and path) names the
  same bytes every time. Two fetches of one conversation haven't been compared, so it is not
  known whether a later fetch signs the same key. If it does, the file is not downloaded again;
  if it doesn't, it is downloaded again, and the identical bytes are stored once.
- Not observed, not relied on: whether the `ETag` is the bytes' MD5, and whether old objects
  remain.
- The links point at Arena's file storage, not Arena's API. The same traffic rules apply anyway.

## Acceptance criteria

1. **When.** After each valid detail (HTTP 200, complete, a body naming the conversation) in a sync
   or a Refresh, the job downloads that snapshot's attachments before its next request. It downloads
   nothing else: an older snapshot's links have expired, so its files arrive only with a new detail
   (Refresh, or a sync that fetches the conversation again). There is no automatic backfill.
2. **Which links.**
   - The adapter defines one rule for a downloadable link, used by the download and by the decoder:
     - `https`, on a host ending in `.r2.cloudflarestorage.com` (the only host observed);
     - no user name, password or port;
     - a non-empty path.
   - Any other link is never requested; the manifest counts it as not recognized.
   - A link whose stated lifetime has passed (`X-Amz-Date` + `X-Amz-Expires` before now) is not
     requested; the manifest counts it as expired. It is checked again after the spacing wait,
     right before the request. A link without these parameters is requested.
   - A link whose object key this account already stored, with its file still present, is not
     requested again (counted as already stored).
3. **The request.**
   - One GET at a time, through a separate transport that has no cookie jar and sends no
     credentials. It uses no cache and refuses redirects, like the account sessions, and never
     touches the account's Arena session.
   - It keeps the job's one-second spacing and its single request in flight, and it stops when the
     job is cancelled.
4. **Record before interpret.** Each response is stored before anything uses it:
   - **200 with a complete body:** the bytes go to the account's object store, content-addressed:
     `Archive/accounts/<uuid>/objects/sha256/<hex>`. The write goes to a temporary file, then a
     full sync, a rename and a directory sync. An object already there with the right bytes is
     kept; one with the wrong bytes is replaced.
   - **Then, for every response,** one `attachment.download` record is appended and flushed. It
     holds:
     - the conversation, the detail record's sequence, the message ID and the attachment's
       position;
     - the object key;
     - the HTTP status, how the transfer ended, the bytes observed and the response headers
       (`Set-Cookie` omitted; the query of a `Location` or `Content-Location`, which a redirect
       never followed may carry as a newly signed link, replaced by `[omitted]`);
     - the outcome.
   - The link's signed query is not repeated; it stays in the detail record
     (`signed_query_omitted`).
   - **A stored body** is named by `object_sha256` and `object_size`, with payload representation
     `object_reference` and an empty payload.
   - **Any other body** is the record's payload, as captured.
   - **Storage failures:** if the object can't be written, the body becomes the record's payload
     instead (outcome `not_stored`), so the response is not lost, and then the job stops as
     `storageFailed`. If the record can't be written either, the job stops the same way. An object
     written without its record is left in place: it's harmless and never shown, since nothing
     names it.
5. **Outcomes.**
   - **`stored`:** HTTP 200 and a complete transfer.
   - **`denied`:** 401 or 403. Downloads stop for the rest of the job, with a manifest warning.
   - **`unavailable`:**
     - 404, any other status, or an interrupted transfer;
     - a body over 32 MiB (`capture_limit`);
     - 429 or 503, which also stop downloads for the rest of the job, with no retry.
   - **`not_stored`:** HTTP 200 and complete, but the object store refused the bytes (see above).
   - A failed attachment is tried again only when a later detail of that conversation is fetched.
   - Attachments never change the job's outcome, which names the history it covered. The manifest
     counts them:
     - `attachmentsStored`;
     - `attachmentsAlreadyStored`;
     - `attachmentsFailed` (denied, unavailable or not stored);
     - `attachmentsExpired`;
     - `attachmentsNotRecognized`.
6. **The object store** (`CaptureJournal.ObjectStore`, no Arena knowledge):
   - files and folders private (0600, 0700); opening it makes files copied or restored by hand
     private again;
   - leftover temporary files removed when it is opened;
   - a read checks the bytes against their name.
   - **Record convention:** a journal record that stores its body as an object names it with
     `object_sha256` and `object_size`. Verify and backup use this convention; they don't know the
     record kind. The container format is unchanged (`Docs/journal-format-v1.md`).
7. **Index** (decoder `arena-decoder/3`, one rebuild on first launch).
   - An attachment keeps its name, type and whether it has a link. It also gains:
     - its object key, when the link is downloadable;
     - the link's end of life, computed from `X-Amz-Date` and `X-Amz-Expires`.
   - `attachment.download` records go into a new table, so the transcript can tell, for each
     attachment:
     - **Stored**, with size and SHA-256 (a stored object for the same key counts for every
       snapshot that has it);
     - **Denied**, **Unavailable** or **Not stored** (the latest attempt);
     - **Link expired** (no attempt, and the link's lifetime has passed);
     - **Not downloaded yet** (no attempt, and the link is still valid or its lifetime unknown);
     - **Link not recognized**;
     - **No link**.
   - Replaying the journal gives the same rows. The new table is hashed only when it has rows.
8. **Verify** also checks, per account, every object a record names, and reports each one that is
   missing or whose bytes differ, also when the journal itself has issues (the records it can read
   are checked). It repairs nothing.
9. **Backup** (`arena-suite-backup/2`):
   - It copies every object a record of the copied journal names, and lists each with its size.
     A named file that is missing, whose bytes don't match its name, or whose size isn't the one
     its record states is refused as damage; the message says which record, and nothing is
     written. A file no record names (a store interrupted before its record) is left out.
   - Check re-hashes every object and compares its size with the listed one, and refuses a listed
     object no record names, a missing one, and a link in place of a folder. Restore copies them
     back.
   - `/1` backups still check and restore.
   - The replay digest is compared only when the backup's decoder version is the app's. Otherwise
     check reports that it couldn't be compared. The journals and files are still checked against
     the manifest and each other (internal integrity: the manifest itself is not signed). Without this, every decoder change would make older backups unrestorable
     (the `/2` decoder already did).
   - Encrypted backups seal the same folder.
10. **In the app.**
    - A stored image shows inline under its message, scaled to fit. Any other stored file shows as
      a row.
    - Both have Save Copy…, which writes the bytes under the attachment's name where the user
      picks.
    - The other states show as text. Link expired and Not downloaded yet say that Refresh fetches
      the conversation again with new links.
    - The bytes are read through `ApplicationActions`, checked against their SHA-256; a missing or
      damaged file says so.
    - Only raster images are shown inline, decided by their bytes (ImageIO's type), never by the
      stated type, up to 100 megapixels and previewed at most 1 600 pixels across; SVG, PDF and
      anything else stay files.
11. **Unchanged:**
    - exports, so the frozen view of a snapshot stays byte-identical;
    - MCP, which stays offline and read-only. The boundary script forbids MCP from naming the
      object store or reading attachment files (`ObjectStore`, `attachmentData`,
      `.objects(for:)`); what the index says about attachments stays readable.
12. **Tests:**
    - **Adapter, with scripted transports:**
      - after a detail with two attachments, two GETs on the download transport, never the
        session's;
      - record order (detail, then downloads), metadata, no signed query in the download record,
        objects with the right bytes;
      - not-recognized and expired links send nothing;
      - an object key already stored isn't requested again, unless its file is missing;
      - 403 and 429 stop the downloads but not the sync;
      - 404, an interrupted transfer and the capture limit are recorded as unavailable;
      - Refresh downloads too;
      - an object write failure records the body and stops the job as `storageFailed`;
      - a redirect's signed `Location` query is not journaled;
      - a link that expires during the spacing wait is not requested.
    - **Object store:** atomic write, the same bytes twice, a damaged object replaced, temporary
      leftovers, permissions, reads checked.
    - **Decoder and index:**
      - the object key and the end of life;
      - an unknown host;
      - the state of each attachment;
      - rebuild equality.
    - **Verify:** a missing object and a damaged object.
    - **Backup:**
      - objects copied, checked and restored;
      - a damaged or missing object refused;
      - a `/1` backup still restored;
      - a different decoder version restores with the digest not compared.

## Not in this milestone

- **Old attachments.** The 138 recorded links have expired. Each conversation's files arrive with
  its next detail: Refresh, one conversation at a time. Fetching every conversation with missing
  files in one click is a separate decision, since it means many requests at once.
- Attachment files in exports, including the planned bulk export.
- Agent workspace files (`downloadWorkspace`), which need the Agent detail route first.
- Removing objects that no record names.
- Comparing the `ETag` with the bytes.

## Results

- **Tests** (all suites pass: ArenaSuiteCore 136, ArenaProtocol 209, ArenaSuiteMCP 17; boundary
  check passes):
  - `ObjectStoreTests` (8): private files and folders, the same bytes kept once, a damaged object
    reported and replaced, invalid names, a failed write leaving nothing and `open` removing
    leftovers, a file in place of a folder refused, a symlink not read, `open` making object files
    private again.
  - `AttachmentDownloadTests.swift` (26; the encrypted one runs in the serialized
    `EncryptedBackupTests` suite, whose tests check for leftover plain copies): every criterion
    of item 12 (including the review's: a body kept when the store refuses it, a redirect's signed
    query, a link expiring during the wait, Verify past a torn record, a backup listing an unnamed
    file or holding a linked folder), plus Verify naming each missing or
    damaged file by record, a backup holding and restoring the files byte-identical (index shows
    them stored after a rebuild), a changed, missing or unlisted file in a backup refused, a file
    no record names left out, a `/1` backup still checking and restoring (and `/1` with objects
    refused), another decoder's digest not compared while the same decoder's still is, and an
    encrypted backup carrying the files.
  - Whole-conversation exports are byte-identical to their goldens; only the evidence's decoder
    version reads `arena-decoder/3`.
- **App, on a synthetic archive** (never the real one): one prompt with nine attachments showed a
  stored PNG inline with its size and Save Copy…, a stored text file as a row with Save Copy…, and
  the texts for refused (HTTP 403), unavailable (HTTP 404), link expired, link not recognized, no
  link, a stored file missing from the archive, and not downloaded yet. Save Copy… itself was not
  clicked.
- **Not yet run against Arena.** After installing, Sync History and Refresh download the files of
  each detail they fetch (requests to the file host, one at a time). The 138 recorded links have
  expired: each conversation's files arrive with its next Refresh.
- **Review:** `Docs/reviews/2026-10-20-attachments.md`.
- **Known limits:**
  - Verify and a refused backup name the record, not the conversation; opening the conversation
    shows which file is missing.
  - A request that fails before any response is counted in the manifest but not journaled, as for
    Arena's own requests.
  - The sync summary counts downloaded and failed files; expired and not-recognized links are only
    in the manifest.
