# Encrypted backup (2026-10-20)

This adds a backup that is one file locked with a passphrase the user chooses. It is the first part
of item 7 of the user's gap analysis (`Docs/arena-exporter-gaps-2026-10-19.md`). The user chose the
key on 2026-10-20: a passphrase, as arena-exporter does, with a way to recover the backup without
the app.

The second part, importing arena-exporter folders, is a separate milestone. GitHub backup stays a
separate decision, because it sends private conversations off the Mac.

Nothing is sent anywhere. The plain backup (plan v3 §13, Phase 7) is unchanged and stays available.

## Format

- **Content:** exactly the plain backup folder that `BackupService.create` writes:
  - the journals;
  - the account list;
  - `backup-manifest.json`, format `arena-suite-backup/1`.
- **Container:** an Apple Encrypted Archive (AEA) holding an Apple Archive of that folder.
  - Profile: `hkdf_sha256_aesctr_hmac__scrypt__none`. The key comes from the passphrase through
    scrypt. Data is encrypted with AES-CTR, and every segment is authenticated with HMAC-SHA256.
  - Compression: lzfse.
  - Each entry holds only its type, path and data (`TYP,PAT,DAT`): no owner, permissions, times or
    extended attributes.
  - Apple's framework does the cryptography. Arena Suite has no cryptographic code of its own.
- **File:** `Arena Suite Backup <yyyy-MM-dd HHmmss>.aea`, with a number added if the name is taken.
- **Passphrase:**
  - at least 20 characters and at most 256 bytes in UTF-8, entered twice. These are AEA's own
    limits: `setPassword` refuses anything outside 20–256 bytes, and 20 characters always make at
    least 20 bytes;
  - normalized to Unicode NFC before use, so the same words typed on another keyboard open it. The
    recovery recipe below normalizes the same way;
  - never stored, logged or written by Arena Suite. Without it the backup cannot be opened.
  - Swift strings cannot be wiped from memory reliably. The passphrase is held only for the action
    and cleared from the form afterwards.

## Recovery without Arena Suite

macOS 12 or later has the needed tools: `aea`, `aa` and Perl. In Terminal (zsh), paste this block
with the backup's path in place of the example (dragging the file into Terminal types its path),
then type the passphrase and press Return:

```bash
(
umask 077
mkdir arena-recovery && cd arena-recovery || exit 1
IFS= read -rs P
P=$(P=$P /usr/bin/perl -MEncode -MUnicode::Normalize -e 'print encode("UTF-8", NFC(decode("UTF-8", $ENV{P})))')
aea decrypt -i ~/Desktop/"Arena Suite Backup 2026-10-20 120000.aea" -o backup.aar -password-value "$P" && mkdir backup && aa extract -i backup.aar -d backup; result=$?; unset P; rm -f backup.aar
exit $result
)
```

- The parentheses run it apart from the Terminal session: `umask`, `cd` and `exit` do not outlast
  it.
- It works only in a new `arena-recovery` folder. If that folder exists (an earlier attempt), it
  stops before reading anything; delete the folder first.
- `umask 077` makes everything recovered owner-only. `read -rs` keeps the passphrase out of the
  shell history and off disk; `IFS=` keeps spaces at its start and end. The Perl line normalizes
  it to NFC, as the app does.
- While `aea` runs, the process list shows the passphrase to other processes of the same user.
  `aea` does not prompt and could not read a pipe on macOS 27 (observed).
- A failed decryption stops it: nothing is extracted, and the block ends with a non-zero status.
  The intermediate archive is removed either way. If extraction fails part-way, `backup` may be
  partial: delete it.
- `arena-recovery/backup` is then a plain Arena Suite backup, in plaintext: the app's Check Backup
  and Restore accept it. Delete it when done.
- `macOSToolsOpenAnEncryptedBackup` reads this block from this file and runs it with one
  substitution, the example path. It types the passphrase on standard input, including one with
  spaces at both ends.

## Acceptance criteria

1. **Service** (ApplicationActions, `EncryptedBackup.swift`):
   - `BackupService.createEncrypted(in:passphrase:)` writes the file into the chosen folder:
     - never over anything existing;
     - it appears only when complete (a staging file, full sync, exclusive rename);
     - no plaintext is written in the chosen folder: the plain copy is made in a private temporary
       folder;
     - on success, failure or cancellation, the plain copy and the staging file are removed. A
       crash can leave them; they are swept, once older than an hour, by the next encrypted backup
       (the plain copy and the staging file) or the next backup, check or restore (the replay
       folder below).
   - `checkEncrypted(_:passphrase:)` and `restoreEncrypted(from:passphrase:)` decrypt into a private
     temporary folder, then run the plain `check` / `restore`, then remove that folder.
   - Plaintext on this Mac outside the archive exists only in the user's private temporary
     directory: the plain copy (`arena-suite-plain-backup-*`), and the replay folder that every
     backup check builds its digest in (`arena-suite-replay-*`, made by the plain backup too).
   - Restore installs the account list in one rename. An existing, empty account list is first set
     aside in one rename and only then checked, so an account added after the restore was allowed
     is never removed (the restore is refused). This fixes the plain restore too. A crash between
     the renames leaves the list in `.previous-accounts-*`. When the app starts and before a
     restore, with no `accounts` folder, one is put back (one that holds something first); empty
     ones are then removed. Anything else is kept: Maintenance names it, and restore is
     unavailable while it is there. Only real folders are put back.
   - When opening, only directories and regular files with safe relative paths are written:
     - no absolute path, no empty, `.` or `..` component, no NUL byte, no duplicate, no path under
       a file or file over a folder another entry made;
     - each file is new (`O_EXCL`, `O_NOFOLLOW`) and owner-only;
     - anything else is refused (`unsafeEntry`), and nothing outside the temporary folder is
       touched.
     - Apple Archive's decoder already refuses `..`, absolute, `./` and `//` paths itself. Those
       archives fail as damaged content (below); the backup's own check is a second layer, tested
       directly.
   - Refusals:
     - a passphrase under 20 characters (`passphraseTooShort`) or over 256 bytes
       (`passphraseTooLong`);
     - a file that is not an encrypted archive, or a folder (`notABackup`);
     - another AEA profile (`unsupportedFormat`);
     - a wrong passphrase or a damaged header (`wrongPassphraseOrDamaged`). AEA authenticates its
       header with the key derived from the passphrase, so these cannot be told apart;
     - damage after decryption has started: a truncated, shortened or altered file, an entry the
       decoder refuses, or a data field that is not data (`encryptedContentDamaged`). Decryption
       starting proves the passphrase right;
     - a failure writing the decrypted copy on this Mac, or a backup file that cannot be read again
       to its end (a failing disk), is `io`, never reported as damage. The decoder reports a failed
       read like damaged content, so the file is read again to tell them apart;
     - a pipe, device or anything other than a regular file (`notABackup`): it could block;
     - when opening, only AEA's own limits apply (20–256 bytes, refused by `setPassword`); a
       passphrase outside them is `wrongPassphraseOrDamaged`. The 20-character minimum is the rule
       for new backups. The file is looked at before the passphrase;
     - a name longer than a file name may be (255 bytes) is `unsafeEntry`.
2. **Tests:**
   - a round trip checks and restores to an archive equal to the source;
   - the folder holds only the `.aea` file afterwards;
   - a wrong passphrase, a truncated file and a flipped byte are refused;
   - crafted archives with `../`, an absolute path, a symlink and a duplicate path are refused, with
     nothing written outside;
   - a file larger than one 1 MiB read is opened whole;
   - a mistyped data field is damage; a local write failure is `io`;
   - the passphrase rules;
   - cancellation leaves nothing;
   - recovery with the system `aea` and `aa` gives a folder that `check` accepts.
3. **App** (Maintenance):
   - "Encrypted Backup…" asks for a folder, then a passphrase (twice, with the rules and the warning).
     It writes the file, then checks it with the same passphrase.
   - "Check Backup…" and "Restore from Backup…" accept an `.aea` file as well as a folder, and ask
     for the passphrase for a file.
   - The passphrase fields are cleared when the sheet closes.
4. **Checks:**
   - the tests above, `Scripts/test-offline.sh` and the boundary check;
   - the boundary check allows `AppleArchive` and `System` in ApplicationActions, as Apple system
     frameworks rather than dependencies;
   - the Debug build checked on a synthetic archive;
   - a second-model review, required for a change touching backup and recovery.

## Known limits

- **AEA's behaviour is observed, not specified here.** That a wrong passphrase stops decryption
  before any plaintext (so "decryption started" means "passphrase right") and AEA's 20–256-byte
  limits are tested on macOS 27, not taken from Apple's documentation.
- **Directory sync is best effort.** After the final rename the folder is synced with
  `F_FULLFSYNC` (or `fsync`), and a failure is ignored: the file is complete and in place, and
  some volumes cannot sync a folder. The plain backup does not sync its folder either.
- **Sweeps go by age.** A private folder older than an hour is taken as left by a crash. A backup
  running longer than an hour in a second instance of the app could lose its plain copy and fail;
  it never produces a wrong file.
- **The first bytes are read before the passphrase.** Damage there can read as another format
  (`unsupportedFormat`) or as not a backup, rather than "wrong passphrase or damaged".
- **A read error that does not recur looks like damage.** The file is read again only to tell a
  failing disk from damage; a disk that fails once and then reads cleanly is reported as damage.
  Neither reading has a time limit, so a hung network volume holds the check.
- **The folder must support exclusive renames.** The file is installed with `renamex_np` and
  `RENAME_EXCL`, as the plain backup is. APFS and HFS+ support it; on a volume that does not
  (some network and exFAT volumes), the backup fails with a file-operation error and leaves no
  file. Only APFS was tested.
- **The MCP server does not report a set-aside list.** It reads the archive without changing it,
  so it does not run recovery. After an interrupted restore it shows an empty account list until
  the app has started once.
- **No size limit when opening.** A crafted file could expand to fill the temporary directory.
  Opening one needs its passphrase, so this needs the user to type a stranger's passphrase.

## Results (2026-10-20)

- **Tests:** `EncryptedBackupTests` has 18 test functions, all passing:
  - a round trip: the folder holds only the `.aea` file, owner-only. The file contains none of the
    plaintext probed (a message, a title, `backup-manifest`, `segments`). Its check gives the same
    record count and replay digest as a plain backup's. Restoring gives byte-identical journals
    and account list. A second restore into the now non-empty archive is refused. No plain copy
    is left in the temporary directory;
  - a wrong passphrase and a too-short one are refused (`wrongPassphraseOrDamaged`). A file cut in
    half, one shortened by a byte and one with a flipped byte are refused
    (`encryptedContentDamaged`). A text file and a folder are refused (`notABackup`);
  - crafted archives: `../x`, `accounts/../../x`, `/tmp/x`, `a/./b.json` and `a//b.json` are
    refused by the decoder. A symlink, a duplicate path, a file under a file and a file over a
    folder are refused as `unsafeEntry`. Nothing appears outside. `safeComponents` refuses `../x`,
    `a/../../x`, `/x`, `a/./b`, `a//b`, `a/`, the empty path and a NUL byte;
  - a crafted 2.5 MiB file (three reads) and an empty file are opened byte-identical, owner-only;
  - a `DAT` field holding a number, and a file without one, are `encryptedContentDamaged` (a probe
    showed Apple Archive writes a size-0 `DAT` for empty files). Opening into an immutable folder
    is `io`, for a file and for a folder entry; this fails (as damage) with the `io` mapping
    reverted;
  - a file that cannot be read again to its end (permissions removed) is told apart by
    `readsToTheEnd`;
  - a pipe is refused at once (`notABackup`); an AEA with a symmetric-key profile is
    `unsupportedFormat`; an empty archive and one without a manifest are `notABackup`; `%2E%2E`
    and `%2F` stay literal names;
  - the passphrase limits at 19/20 characters and 256/257 bytes, NFC normalization (a decomposed
    passphrase opens a backup with the composed one), and that AEA accepts every allowed
    passphrase: 20 ASCII characters, 22 Japanese characters (66 bytes), 256 bytes. A separate
    test pins AEA's own limits (19 and 257 bytes refused, 20 and 256 accepted) and that Swift's
    `==`, which the sheet uses, treats canonically equivalent text as equal;
  - two backups with the same time stamp: the second is named `… 2.aea`, and the first is
    byte-identical afterwards;
  - stale (two hours old) plain copies, replay folders and staging files are swept by the next
    encrypted backup; a current replay folder is not. This fails with the replay sweep reverted;
  - restore's install refuses an `accounts` folder whose only file is a non-empty
    `registry.json` (an account added meanwhile), keeps it byte-identical and leaves nothing set
    aside; an empty one is replaced. This fails with the old name-only check;
  - an account list a crash set aside is put back, with its registry and journals; with a list
    in place, a set-aside list holding accounts is kept and an empty one removed; an empty
    archive with such a list cannot be restored over, and the list survives the refusal. This
    fails with the recovery and the `canRestore` guard reverted;
  - with two lists set aside, the one holding accounts is put back whichever name sorts first
    (this fails with name order); a file named like a set-aside list is never put back, and is
    named by `keptAccountLists`;
  - an empty file sealed by Apple Archive's own encoder (as `seal` does) opens as an empty file;
  - a text file with a three-character passphrase is `notABackup`; a 256-byte name is
    `unsafeEntry`;
  - a backup cancelled at once leaves the folder empty and no plain copy;
  - the recovery block, read from this doc and run by zsh with the passphrase typed on standard
    input: a passphrase with accents typed decomposed opens the backup (while `aea` given the raw
    decomposed text refuses it), every recovered folder and file is owner-only, the intermediate
    archive is removed, `check` accepts the folder with the same replay digest, and a wrong
    passphrase leaves the recovery folder empty. Run again in the same
    place, the block stops before reading anything and a `backup.aar` next to the folder is
    untouched. A passphrase with spaces at both ends opens its backup; this fails without
    `IFS=`.
- **Debug build, synthetic archive (120 conversations, 1 journal, 120 records):**
  - the new-backup sheet keeps Encrypt disabled and shows "9 of at least 20 characters." in orange
    for a short entry;
  - submitting a valid passphrase twice wrote `Arena Suite Backup <stamp>.aea` and showed
    "Encrypted backup written and checked: 1 journal(s), 120 record(s)." with Reveal in Finder;
  - Check Backup's sheet for that file (one field, "Open the Encrypted Backup") refused a wrong
    passphrase: "The passphrase is wrong, or the start of the backup file is damaged. Nothing was
    changed." The right one gave "Backup is intact: 1 journal(s), 120 record(s)…";
  - with a stray file named `.previous-accounts-test` in the archive folder, launch left it in
    place, and Maintenance named it in orange and offered no Restore;
  - the test files were removed afterwards. Not exercised by hand: the file and folder pickers,
    and Restore (an empty archive is needed; `restoreEncrypted` is tested).
- **Review:** `Docs/reviews/2026-10-20-encrypted-backup.md`.
