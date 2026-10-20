import AppleArchive
import ArchiveIndex
import CaptureJournal
import CryptoKit
import Foundation
import SuiteDomain
import System
import Testing

@testable import ApplicationActions
@testable import ArenaAdapter

// Encrypted backups (Docs/encrypted-backup-2026-10-20.md). Serialized: the tests compare this user's
// temporary directory before and after, to prove no plain copy is left behind.

private let passphrase = "correct horse battery staple"

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The plain copies in this user's temporary directory.
private func plainCopies() -> Set<String> {
    Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        .filter { $0.hasPrefix("arena-suite-plain-backup-") })
}

/// The recovery block of `Docs/encrypted-backup-2026-10-20.md`, read from the doc, with the file
/// from `BACKUP`. It reads the passphrase from standard input, as typed.
private func recoveryRecipe() throws -> String {
    let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Docs/encrypted-backup-2026-10-20.md")
    let text = try String(contentsOf: doc, encoding: .utf8)
    let section = try #require(text.range(of: "## Recovery without Arena Suite"))
    let open = try #require(text.range(of: "```bash\n", range: section.upperBound..<text.endIndex))
    let close = try #require(text.range(of: "```", range: open.upperBound..<text.endIndex))
    var block = String(text[open.upperBound..<close.lowerBound])
    let example = #"~/Desktop/"Arena Suite Backup 2026-10-20 120000.aea""#
    #expect(block.components(separatedBy: example).count == 2, "the doc's block names the example once")
    block = block.replacingOccurrences(of: example, with: #""$BACKUP""#)
    return block
}

/// Runs `tool` in `directory` with only `environment` and `input` on standard input, and returns its
/// exit status.
private func run(_ tool: String, _ arguments: [String], in directory: URL, environment: [String: String] = [:], input: String = "") throws -> Int32 {
    let process = Process()
    let stdin = Pipe()
    process.standardInput = stdin
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = ["PATH": "/usr/bin:/bin"].merging(environment) { $1 }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    return process.terminationStatus
}

/// An encrypted archive with exactly these entries, as a crafted or damaged backup could hold.
/// `decorate` may add fields to an entry's header.
private func craft(
    _ entries: [(path: String, type: ArchiveHeader.EntryType, data: Data?)],
    context: ArchiveEncryptionContext? = nil,
    decorate: (String, ArchiveHeader) -> Void = { _, _ in }
) throws -> URL {
    let url = try folder().appendingPathComponent("crafted.aea")
    let context = try context ?? {
        let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
        try context.setPassword(passphrase)
        return context
    }()
    try ArchiveByteStream.withFileStream(
        path: FilePath(url.path), mode: .writeOnly, options: [.create, .exclusiveCreate], permissions: [.ownerReadWrite]
    ) { file in
        let encrypted = try #require(ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context))
        try ArchiveStream.withEncodeStream(writingTo: encrypted) { encoder in
            for entry in entries {
                let header = ArchiveHeader()
                header.append(.uint(key: .init("TYP"), value: UInt64(entry.type.rawValue)))
                header.append(.string(key: .init("PAT"), value: entry.path))
                if entry.type == .link { header.append(.string(key: .init("LNK"), value: "/etc")) }
                if let data = entry.data { header.append(.blob(key: .init("DAT"), size: UInt64(data.count))) }
                decorate(entry.path, header)
                try encoder.writeHeader(header)
                if let data = entry.data { try data.withUnsafeBytes { try encoder.writeBlob(key: .init("DAT"), from: $0) } }
            }
        }
        try encrypted.close()
    }
    return url
}

@Suite(.serialized) struct EncryptedBackupTests {
    @Test func anEncryptedBackupChecksAndRestoresToAnEqualArchive() async throws {
        let source = try await MaintenanceArchive()
        let before = plainCopies()
        let out = try folder()
        let backup = try await source.backups.createEncrypted(in: out, passphrase: passphrase)
        #expect(backup.lastPathComponent.hasPrefix("Arena Suite Backup ") && backup.pathExtension == "aea")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [backup.lastPathComponent], "only the file")
        #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
        let bytes = try Data(contentsOf: backup)
        for plain in ["Hello private words", "Secret title", "backup-manifest", "segments"] {
            #expect(bytes.range(of: Data(plain.utf8)) == nil, "no plaintext: \(plain)")
        }

        let plainOut = try folder()
        let plainCheck = try await source.backups.check(try await source.backups.create(in: plainOut))
        let check = try await source.backups.checkEncrypted(backup, passphrase: passphrase)
        #expect(check.accounts == 2 && check.records == plainCheck.records && check.replayDigest == plainCheck.replayDigest)

        let targetRoot = try folder()
        let target = BackupService(archiveRoot: targetRoot, decoder: ArenaArchiveDecoder(), appVersion: "test")
        let restored = try await target.restoreEncrypted(from: backup, passphrase: passphrase)
        #expect(restored.replayDigest == plainCheck.replayDigest)
        let targetJournals = JournalStore(archiveRoot: targetRoot)
        #expect(targetJournals.accountsOnDisk() == source.journals.accountsOnDisk())
        for account in source.accounts {
            #expect(try Data(contentsOf: targetJournals.root(for: account).appendingPathComponent("segments/000001.asj"))
                == Data(contentsOf: source.journals.root(for: account).appendingPathComponent("segments/000001.asj")))
        }
        #expect(try Data(contentsOf: targetRoot.appendingPathComponent("accounts/registry.json"))
            == Data(contentsOf: source.root.appendingPathComponent("accounts/registry.json")))
        #expect(plainCopies() == before, "no plain copy left behind")
        await #expect(throws: BackupError.targetNotEmpty) { try await target.restoreEncrypted(from: backup, passphrase: passphrase) }
    }

    @Test func aWrongPassphraseAndADamagedFileAreRefused() async throws {
        let source = try await MaintenanceArchive(conversations: 2)
        let before = plainCopies()
        let backup = try await source.backups.createEncrypted(in: try folder(), passphrase: passphrase)
        let data = try Data(contentsOf: backup)
        let truncated = try folder().appendingPathComponent("truncated.aea")
        try data.prefix(data.count / 2).write(to: truncated)
        let shortened = try folder().appendingPathComponent("shortened.aea")
        try data.dropLast(1).write(to: shortened)
        let flipped = try folder().appendingPathComponent("flipped.aea")
        var changed = data
        changed[data.count / 2] ^= 0x01
        try changed.write(to: flipped)

        for words in ["another long passphrase", "short"] {
            await #expect(throws: BackupError.wrongPassphraseOrDamaged) { try await source.backups.checkEncrypted(backup, passphrase: words) }
        }
        // Decryption starts with the right passphrase, so these are damaged content.
        for file in [truncated, shortened, flipped] {
            await #expect(throws: BackupError.encryptedContentDamaged, "\(file.lastPathComponent)") {
                try await source.backups.checkEncrypted(file, passphrase: passphrase)
            }
        }
        let text = try folder().appendingPathComponent("notes.aea")
        try Data("not an archive".utf8).write(to: text)
        await #expect(throws: BackupError.notABackup) { try await source.backups.checkEncrypted(text, passphrase: passphrase) }
        await #expect(throws: BackupError.notABackup) { try await source.backups.checkEncrypted(try folder(), passphrase: passphrase) }
        #expect(plainCopies() == before)
    }

    @Test func unsafeEntriesAreRefusedAndNothingIsWrittenOutside() async throws {
        let source = try await MaintenanceArchive(conversations: 1)
        let before = plainCopies()
        let escape = "escape-\(UUID().uuidString).txt"
        // Apple Archive's decoder refuses these paths itself.
        for path in ["../\(escape)", "accounts/../../\(escape)", "/tmp/\(escape)", "a/./b.json", "a//b.json"] {
            let file = try craft([(path, .regularFile, Data("x".utf8))])
            await #expect(throws: BackupError.encryptedContentDamaged, "\(path)") {
                try await source.backups.checkEncrypted(file, passphrase: passphrase)
            }
        }
        // These it accepts; the backup refuses them.
        let cases: [[(path: String, type: ArchiveHeader.EntryType, data: Data?)]] = [
            [("accounts", .link, nil)],
            [("a.json", .regularFile, Data("1".utf8)), ("a.json", .regularFile, Data("2".utf8))],
            // A file under a file, and a file over a folder.
            [("a", .regularFile, Data("1".utf8)), ("a/b", .regularFile, Data("2".utf8))],
            [("a/b", .regularFile, Data("1".utf8)), ("a", .regularFile, Data("2".utf8))],
        ]
        for entries in cases {
            let file = try craft(entries)
            await #expect(throws: BackupError.unsafeEntry(entries.last!.path)) {
                try await source.backups.checkEncrypted(file, passphrase: passphrase)
            }
        }
        // The backup's own check, which does not rely on the decoder's.
        for path in ["../x", "a/../../x", "/x", "a/./b", "a//b", "a/", "", "a\0b"] {
            #expect(BackupService.safeComponents(path) == nil, "\(path.debugDescription)")
        }
        #expect(BackupService.safeComponents("accounts/registry.json") == ["accounts", "registry.json"])
        let temporary = FileManager.default.temporaryDirectory
        #expect(!FileManager.default.fileExists(atPath: temporary.appendingPathComponent(escape).path))
        #expect(!FileManager.default.fileExists(atPath: "/tmp/\(escape)"))
        #expect(plainCopies() == before)
    }

    /// A data field that is not data is damage. A failure writing on this Mac is this Mac's, never
    /// reported as a damaged backup.
    @Test func malformedDataIsDamageAndLocalFailuresAreNot() throws {
        let mistyped = try craft([("a.json", .regularFile, nil)]) { _, header in header.append(.uint(key: .init("DAT"), value: 7)) }
        #expect(throws: BackupError.encryptedContentDamaged) { try BackupService.open(mistyped, passphrase: passphrase, into: try folder()) }
        let missing = try craft([("a.json", .regularFile, nil)])
        #expect(throws: BackupError.encryptedContentDamaged) { try BackupService.open(missing, passphrase: passphrase, into: try folder()) }

        let entries: [[(path: String, type: ArchiveHeader.EntryType, data: Data?)]] = [
            [("a.json", .regularFile, Data("1".utf8))], [("journals", .directory, nil)],
        ]
        for entry in entries {
            let file = try craft(entry)
            // An immutable folder: neither its permissions nor its contents can change.
            let locked = try folder()
            #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
            defer { chflags(locked.path, 0) }
            #expect("\(entry[0].path)", performing: { try BackupService.open(file, passphrase: passphrase, into: locked) }, throws: { error in
                if case .io = error as? BackupError { true } else { false }
            })
        }
    }

    /// Files are read in 1 MiB pieces; journal segments can be larger.
    @Test func aFileLargerThanOneReadIsOpenedWhole() throws {
        var generator = SystemRandomNumberGenerator()
        let big = Data((0..<(5 << 19)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let file = try craft([("journals", .directory, nil), ("journals/big.bin", .regularFile, big), ("empty.txt", .regularFile, Data())])
        let root = try folder()
        _ = try BackupService.open(file, passphrase: passphrase, into: root)
        #expect(try Data(contentsOf: root.appendingPathComponent("journals/big.bin")) == big)
        #expect(try Data(contentsOf: root.appendingPathComponent("empty.txt")).isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("journals/big.bin").path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func thePassphraseHasLimitsAndIsNormalized() async throws {
        #expect(BackupService.usablePassphrase("nineteen chars long") == .failure(.passphraseTooShort))
        #expect(BackupService.usablePassphrase("twenty characters ok") == .success("twenty characters ok"))
        #expect(BackupService.usablePassphrase(String(repeating: "ab", count: 128)) == .success(String(repeating: "ab", count: 128)))
        #expect(BackupService.usablePassphrase(String(repeating: "ab", count: 128) + "c") == .failure(.passphraseTooLong))
        let composed = "caf\u{E9} au lait, s'il vous pla\u{EE}t", decomposed = "cafe\u{301} au lait, s'il vous plai\u{302}t"
        #expect(BackupService.usablePassphrase(decomposed) == .success(composed))

        let source = try await MaintenanceArchive(conversations: 1)
        let out = try folder()
        await #expect(throws: BackupError.passphraseTooShort) { try await source.backups.createEncrypted(in: out, passphrase: "too short") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        // Every passphrase the rules allow is one macOS's encrypted archives accept.
        for words in ["twenty characters ok", "日本語のパスフレーズを二十文字にしてみました", String(repeating: "ab", count: 128)] {
            _ = try await source.backups.createEncrypted(in: out, passphrase: words)
        }
        let backup = try await source.backups.createEncrypted(in: out, passphrase: decomposed)
        #expect(try await source.backups.checkEncrypted(backup, passphrase: composed).accounts == 2)
    }

    @Test func aCancelledEncryptedBackupLeavesNothing() async throws {
        let source = try await MaintenanceArchive(conversations: 2)
        let before = plainCopies()
        let out = try folder()
        let task = Task { try await source.backups.createEncrypted(in: out, passphrase: passphrase) }
        task.cancel()
        await #expect(throws: BackupError.cancelled) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        #expect(plainCopies() == before)
    }

    /// Recovery without Arena Suite, with the recipe the milestone doc gives: an accented passphrase
    /// typed decomposed opens it, everything recovered is owner-only, and a wrong passphrase leaves
    /// nothing behind.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/aea")))
    func macOSToolsOpenAnEncryptedBackup() async throws {
        let source = try await MaintenanceArchive(conversations: 2)
        let decomposed = "cre\u{300}me bru\u{302}le\u{301}e pour deux personnes"
        let backup = try await source.backups.createEncrypted(in: try folder(), passphrase: decomposed)

        // Without normalizing, macOS's tool is given other bytes than the app used.
        let direct = try folder()
        #expect(try run("/usr/bin/aea", ["decrypt", "-i", backup.path, "-o", "x.aar", "-password-value", decomposed], in: direct) != 0)

        let recipe = try recoveryRecipe()
        let work = try folder()
        #expect(try run("/bin/zsh", ["-f", "-c", recipe], in: work, environment: ["BACKUP": backup.path], input: decomposed + "\n") == 0)
        let recovery = work.appendingPathComponent("arena-recovery")
        let extracted = recovery.appendingPathComponent("backup")
        #expect(try FileManager.default.contentsOfDirectory(atPath: recovery.path) == ["backup"], "the intermediate archive is removed")
        let inside = try #require(FileManager.default.subpathsOfDirectory(atPath: extracted.path) as [String]?)
        let items = [recovery, extracted] + inside.map { extracted.appendingPathComponent($0) }
        #expect(items.count > 6)
        for url in items {
            let mode = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
            #expect(mode & 0o077 == 0, "\(url.lastPathComponent) is \(String(mode, radix: 8))")
        }
        let check = try await source.backups.check(extracted)
        #expect(try await check.replayDigest == source.backups.checkEncrypted(backup, passphrase: decomposed).replayDigest)

        // A wrong passphrase leaves an empty folder. Running again stops before reading anything, and
        // never touches a file of the same name outside it.
        let failed = try folder()
        let unrelated = failed.appendingPathComponent("backup.aar")
        try Data("someone else's".utf8).write(to: unrelated)
        let environment = ["BACKUP": backup.path]
        #expect(try run("/bin/zsh", ["-f", "-c", recipe], in: failed, environment: environment, input: "a different passphrase entirely\n") != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: failed.appendingPathComponent("arena-recovery").path).isEmpty)
        #expect(try run("/bin/zsh", ["-f", "-c", recipe], in: failed, environment: environment, input: decomposed + "\n") != 0)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: failed.path)) == ["arena-recovery", "backup.aar"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: failed.appendingPathComponent("arena-recovery").path).isEmpty)
        #expect(try Data(contentsOf: unrelated) == Data("someone else's".utf8))

        // The app keeps spaces at both ends of a passphrase; so does the block.
        let spaced = "  correct horse battery staple  "
        let spacedBackup = try await source.backups.createEncrypted(in: try folder(), passphrase: spaced)
        let spacedWork = try folder()
        #expect(try run("/bin/zsh", ["-f", "-c", recipe], in: spacedWork, environment: ["BACKUP": spacedBackup.path], input: spaced + "\n") == 0)
        #expect(FileManager.default.fileExists(atPath: spacedWork.appendingPathComponent("arena-recovery/backup/backup-manifest.json").path))
    }

    /// The limits are Apple's: its encrypted archives refuse passwords outside 20–256 UTF-8 bytes.
    /// The sheet compares its two entries with Swift's `==`, which treats canonically equivalent
    /// text as equal.
    @Test func theLimitsAreAppleArchives() throws {
        for (words, accepted) in [(String(repeating: "a", count: 19), false), (String(repeating: "a", count: 20), true),
                                  (String(repeating: "a", count: 256), true), (String(repeating: "a", count: 257), false)] {
            let context = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
            #expect(((try? context.setPassword(words)) != nil) == accepted, "\(words.utf8.count) bytes")
        }
        #expect("cr\u{E8}me" == "cre\u{300}me")
    }

    @Test func aSecondBackupInTheSameSecondGetsItsOwnName() async throws {
        let source = try await MaintenanceArchive(conversations: 1)
        let out = try folder(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await source.backups.createEncrypted(in: out, passphrase: passphrase, now: now)
        let firstBytes = try Data(contentsOf: first)
        let second = try await source.backups.createEncrypted(in: out, passphrase: passphrase, now: now)
        #expect(second.lastPathComponent == first.deletingPathExtension().lastPathComponent + " 2.aea")
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)) == [first.lastPathComponent, second.lastPathComponent])
    }

    /// Private folders a crash left behind are removed by the next backup; current ones are not.
    @Test func plainFoldersACrashLeftAreSwept() async throws {
        let temporary = FileManager.default.temporaryDirectory
        let stale = ["arena-suite-plain-backup-", "arena-suite-replay-"].map { temporary.appendingPathComponent($0 + "test-\(UUID().uuidString)") }
        let fresh = temporary.appendingPathComponent("arena-suite-replay-test-\(UUID().uuidString)")
        for url in stale + [fresh] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        defer { try? FileManager.default.removeItem(at: fresh) }
        for url in stale { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: url.path) }
        let out = try folder()
        let partial = out.appendingPathComponent(".arena-suite-backup-\(UUID().uuidString).aea.partial")
        try Data("x".utf8).write(to: partial)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: partial.path)

        let source = try await MaintenanceArchive(conversations: 1)
        let backup = try await source.backups.createEncrypted(in: out, passphrase: passphrase)
        for url in stale + [partial] { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [backup.lastPathComponent])
    }

    /// An account added after a restore was allowed is never removed: the restore is refused.
    @Test func aRestoreNeverRemovesAnAccountAddedMeanwhile() async throws {
        let source = try await MaintenanceArchive(conversations: 1)
        let accounts = source.root.appendingPathComponent("accounts")
        let registry = try Data(contentsOf: accounts.appendingPathComponent("registry.json"))
        let staged = try folder().appendingPathComponent("accounts")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        // Only `registry.json` is there, a name an empty account list also has.
        for account in source.accounts { try FileManager.default.removeItem(at: source.journals.root(for: account).deletingLastPathComponent()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: accounts.path) == ["registry.json"])

        #expect(throws: BackupError.targetNotEmpty) { try BackupService.install(staged, at: accounts) }
        #expect(try Data(contentsOf: accounts.appendingPathComponent("registry.json")) == registry)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.root.path).filter { $0.hasPrefix(".previous-accounts-") }.isEmpty)

        // An empty list is replaced, and nothing set aside is left.
        try AccountRegistryStore(url: accounts.appendingPathComponent("registry.json")).save([])
        try BackupService.install(staged, at: accounts)
        #expect(try FileManager.default.contentsOfDirectory(atPath: accounts.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.root.path).filter { $0.hasPrefix(".previous-accounts-") }.isEmpty)
    }

    @Test func otherFilesAndArchivesAreRefusedForWhatTheyAre() async throws {
        let source = try await MaintenanceArchive(conversations: 1)
        // A pipe is not read (it could block).
        let pipe = try folder().appendingPathComponent("pipe.aea")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        await #expect(throws: BackupError.notABackup) { try await source.backups.checkEncrypted(pipe, passphrase: passphrase) }
        // Another kind of encrypted archive.
        let symmetric = ArchiveEncryptionContext(profile: .hkdf_sha256_aesctr_hmac__symmetric__none, compressionAlgorithm: .lzfse)
        try symmetric.setSymmetricKey(SymmetricKey(size: .bits256))
        let other = try craft([("a.json", .regularFile, Data("1".utf8))], context: symmetric)
        await #expect(performing: { try await source.backups.checkEncrypted(other, passphrase: passphrase) }, throws: { error in
            if case .unsupportedFormat = error as? BackupError { true } else { false }
        })
        // An empty archive, and one with a file but no manifest.
        for entries: [(path: String, type: ArchiveHeader.EntryType, data: Data?)] in [[], [("notes.txt", .regularFile, Data("1".utf8))]] {
            let file = try craft(entries)
            await #expect(throws: BackupError.notABackup) { try await source.backups.checkEncrypted(file, passphrase: passphrase) }
        }
        // Percent signs are part of a name, never decoded into a path.
        let percent = try craft([("%2E%2E/a.json", .regularFile, Data("1".utf8)), ("%2F", .regularFile, Data("2".utf8))])
        let root = try folder()
        _ = try BackupService.open(percent, passphrase: passphrase, into: root)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["%2E%2E", "%2F"])
        #expect(try Data(contentsOf: root.appendingPathComponent("%2E%2E").appendingPathComponent("a.json")) == Data("1".utf8))
    }

    /// A restore that crashed between its renames left the account list set aside: it is put back,
    /// and restore is refused while a list that holds anything stays aside.
    @Test func anAccountListACrashSetAsideIsPutBack() async throws {
        let source = try await MaintenanceArchive(conversations: 1)
        let accounts = source.root.appendingPathComponent("accounts")
        let registry = try Data(contentsOf: accounts.appendingPathComponent("registry.json"))
        let aside = source.root.appendingPathComponent(".previous-accounts-crash")
        try FileManager.default.moveItem(at: accounts, to: aside)
        #expect(!source.backups.canRestore, "the archive only looks empty")

        BackupService.recoverSetAsideAccounts(in: source.root)
        #expect(try Data(contentsOf: accounts.appendingPathComponent("registry.json")) == registry)
        #expect(Set(source.journals.accountsOnDisk()) == Set(source.accounts))
        #expect(!FileManager.default.fileExists(atPath: aside.path))

        // With an account list in place, a set-aside list that holds accounts is kept, and one that
        // is empty is removed.
        let empty = try folder()
        try AccountRegistryStore(url: empty.appendingPathComponent("accounts/registry.json")).save([])
        let full = source.root.appendingPathComponent(".previous-accounts-full")
        try FileManager.default.copyItem(at: accounts, to: full)
        let spare = source.root.appendingPathComponent(".previous-accounts-empty")
        try FileManager.default.moveItem(at: empty.appendingPathComponent("accounts"), to: spare)
        BackupService.recoverSetAsideAccounts(in: source.root)
        #expect(FileManager.default.fileExists(atPath: full.path))
        #expect(!FileManager.default.fileExists(atPath: spare.path))

        // An empty archive with a set-aside list that holds accounts cannot be restored over.
        let emptyRoot = try folder()
        try FileManager.default.moveItem(at: full, to: emptyRoot.appendingPathComponent(".previous-accounts-full"))
        try AccountRegistryStore(url: emptyRoot.appendingPathComponent("accounts/registry.json")).save([])
        let target = BackupService(archiveRoot: emptyRoot, decoder: ArenaArchiveDecoder(), appVersion: "test")
        #expect(!target.canRestore)
        let backup = try await source.backups.createEncrypted(in: try folder(), passphrase: passphrase)
        await #expect(throws: BackupError.targetNotEmpty) { try await target.restoreEncrypted(from: backup, passphrase: passphrase) }
        #expect(FileManager.default.fileExists(atPath: emptyRoot.appendingPathComponent(".previous-accounts-full/registry.json").path))
    }

    /// Several lists set aside: one that holds accounts is put back before an empty one, whatever
    /// their names. A file or link of such a name is never put back. What is kept is named.
    @Test func severalSetAsideListsAndOneThatIsNotAFolder() async throws {
        for fullName in [".previous-accounts-a", ".previous-accounts-b"] {
            let source = try await MaintenanceArchive(conversations: 1)
            let accounts = source.root.appendingPathComponent("accounts")
            let registry = try Data(contentsOf: accounts.appendingPathComponent("registry.json"))
            try FileManager.default.moveItem(at: accounts, to: source.root.appendingPathComponent(fullName))
            let emptyName = fullName.hasSuffix("a") ? ".previous-accounts-b" : ".previous-accounts-a"
            try AccountRegistryStore(url: source.root.appendingPathComponent("\(emptyName)/registry.json")).save([])

            BackupService.recoverSetAsideAccounts(in: source.root)
            #expect(try Data(contentsOf: accounts.appendingPathComponent("registry.json")) == registry, "\(fullName)")
            #expect(Set(source.journals.accountsOnDisk()) == Set(source.accounts))
            #expect(source.backups.keptAccountLists().isEmpty)
        }

        let root = try folder()
        let stray = root.appendingPathComponent(".previous-accounts-file")
        try Data("not a folder".utf8).write(to: stray)
        let target = BackupService(archiveRoot: root, decoder: ArenaArchiveDecoder(), appVersion: "test")
        BackupService.recoverSetAsideAccounts(in: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts").path))
        #expect(try Data(contentsOf: stray) == Data("not a folder".utf8))
        #expect(target.keptAccountLists() == [".previous-accounts-file"])
        #expect(!target.canRestore)
    }

    /// Apple Archive's own encoder, as `seal` uses it, writes empty files so that they open.
    @Test func anEmptyFileWrittenByAppleArchiveOpens() throws {
        let plain = try folder()
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("journals"), withIntermediateDirectories: false)
        try Data().write(to: plain.appendingPathComponent("journals/empty.asj"))
        try Data("x".utf8).write(to: plain.appendingPathComponent("one.json"))
        let file = try folder().appendingPathComponent("sealed.aea")
        try BackupService.seal(folder: plain, passphrase: passphrase, to: file)
        let root = try folder()
        _ = try BackupService.open(file, passphrase: passphrase, into: root)
        #expect(try Data(contentsOf: root.appendingPathComponent("journals/empty.asj")).isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("one.json")) == Data("x".utf8))
    }

    /// The file is looked at before the passphrase; names longer than a file name may be are refused.
    @Test func whatIsCheckedFirstAndNameLengths() async throws {
        let source = try await MaintenanceArchive(conversations: 1)
        let text = try folder().appendingPathComponent("notes.txt")
        try Data("not an archive".utf8).write(to: text)
        await #expect(throws: BackupError.notABackup) { try await source.backups.checkEncrypted(text, passphrase: "abc") }
        #expect(BackupService.safeComponents(String(repeating: "a", count: 255)) != nil)
        #expect(BackupService.safeComponents(String(repeating: "a", count: 256)) == nil)
        let long = try craft([(String(repeating: "a", count: 256), .regularFile, Data("1".utf8))])
        #expect(throws: BackupError.unsafeEntry(String(repeating: "a", count: 256))) {
            try BackupService.open(long, passphrase: passphrase, into: try folder())
        }
    }

    /// The decoder reports a failed read like damage; a file that cannot be read again is this Mac's.
    @Test func aFileThatCannotBeReadIsNotCalledDamaged() throws {
        let file = try folder().appendingPathComponent("unreadable.aea")
        try Data(repeating: 7, count: 3 << 20).write(to: file)
        #expect(BackupService.readsToTheEnd(file))
        #expect(chmod(file.path, 0o000) == 0)
        defer { chmod(file.path, 0o600) }
        #expect(!BackupService.readsToTheEnd(file))
    }
}
