import CaptureJournal
import Foundation
import SuiteDomain

/// `backup-manifest.json`. Lists every file in the backup with its SHA-256 and the content digest of
/// the index the backed-up journals replay to.
public struct BackupManifest: Codable, Sendable, Equatable {
    public struct Journal: Codable, Sendable, Equatable {
        public let account: String
        public let segments: [CopiedSegment]
    }

    public static let currentFormat = "arena-suite-backup/1"
    public let format: String
    public let createdAt: String
    public let appVersion: String
    public let decoderVersion: String
    /// nil if there was no account registry.
    public let registrySHA256: String?
    public let journals: [Journal]
    /// Digest of an index replayed from exactly these journals.
    public let replayDigest: String

    private enum CodingKeys: String, CodingKey {
        case format, journals
        case createdAt = "created_at"
        case appVersion = "app_version"
        case decoderVersion = "decoder_version"
        case registrySHA256 = "registry_sha256"
        case replayDigest = "replay_digest"
    }
}

public enum BackupError: Error, Equatable, Sendable {
    case notABackup
    case unsupportedFormat(String)
    /// A file is missing, extra, or differs from the manifest.
    case fileMismatch(String)
    case journalDamaged(account: String, issue: String)
    case replayMismatch
    /// Restore only goes into an archive with no accounts and no journals.
    case targetNotEmpty
    /// Accounts were added or removed while the backup ran.
    case archiveChanged
    case cancelled
    case io(String)
}

/// Result of checking a backup folder end to end.
public struct BackupCheck: Sendable, Equatable {
    public let manifest: BackupManifest
    public let accounts: Int
    public let records: Int
    public let replayDigest: String
}

/// Backups (plan v3 §13, Phase 7): a folder holding a copy of every account journal (sealed segments
/// byte for byte with their seal manifests, the active segment up to its last complete record), the
/// account registry, and a manifest. No Keychain items, no index, no diagnostics: after restoring on
/// another Mac each account signs in again, and the index is rebuilt from the journals.
///
/// "Equal archive" means: identical journal bytes (per-segment SHA-256) and an index replayed from
/// the restored journals with the same content digest as one replayed at backup time.
public struct BackupService: Sendable {
    private let archiveRoot: URL
    private let decoder: any ArchiveDecoding
    private let appVersion: String

    public init(archiveRoot: URL, decoder: any ArchiveDecoding, appVersion: String) {
        self.archiveRoot = archiveRoot
        self.decoder = decoder
        self.appVersion = appVersion
    }

    static let manifestName = "backup-manifest.json"

    // MARK: Create

    /// Writes a new backup folder inside `directory` (never overwriting anything) and returns its URL.
    /// The folder appears only when complete; on failure or cancellation nothing is left behind.
    public func create(in directory: URL, now: Date = Date()) async throws -> URL {
        let stamp = Self.stamp(now)
        // Staging folders of our own that an earlier crash left behind (older than an hour).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(".arena-suite-backup-") && name.hasSuffix(".partial") {
            let url = directory.appendingPathComponent(name)
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                now.timeIntervalSince(modified) > 3600
            {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let staging = directory.appendingPathComponent(".arena-suite-backup-\(UUID().uuidString).partial", isDirectory: true)
        try PrivateFile.prepareDirectory(staging)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: staging) } }

        let source = JournalStore(archiveRoot: archiveRoot)
        let registry = archiveRoot.appendingPathComponent("accounts/registry.json")
        // Read before and after the journals: an account added or removed meanwhile would pair a
        // registry with the wrong journals, so the backup is refused instead.
        let registryBefore = try PrivateFile.read(registry)
        let accountsBefore = source.accountsOnDisk()
        var journals: [BackupManifest.Journal] = []
        for account in accountsBefore {
            guard !Task.isCancelled else { throw BackupError.cancelled }
            let target = staging.appendingPathComponent("accounts/\(account.rawValue.uuidString)/journal", isDirectory: true)
            try PrivateFile.prepareDirectory(target)
            do {
                let segments = try JournalCopy.copy(from: source.root(for: account), to: target)
                journals.append(.init(account: account.rawValue.uuidString, segments: segments))
            } catch {
                throw BackupError.journalDamaged(
                    account: account.rawValue.uuidString, issue: VerificationService.describe(error))
            }
        }
        guard try PrivateFile.read(registry) == registryBefore, source.accountsOnDisk() == accountsBefore else {
            throw BackupError.archiveChanged
        }
        var registryDigest: String?
        if let data = registryBefore {
            try PrivateFile.write(data, to: staging.appendingPathComponent("accounts/registry.json"))
            registryDigest = try JournalCopy.sha256(of: staging.appendingPathComponent("accounts/registry.json"))
        }
        guard !Task.isCancelled else { throw BackupError.cancelled }
        let replay = try await Self.replayDigest(root: staging, journals: journals, decoder: decoder)
        let manifest = BackupManifest(
            format: BackupManifest.currentFormat, createdAt: ISO8601DateFormatter().string(from: now),
            appVersion: appVersion, decoderVersion: decoder.version, registrySHA256: registryDigest,
            journals: journals, replayDigest: replay)
        try PrivateFile.write(try Self.encode(manifest), to: staging.appendingPathComponent(Self.manifestName))
        guard !Task.isCancelled else { throw BackupError.cancelled }

        var name = "Arena Suite Backup \(stamp)"
        var attempt = 1
        while true {
            let final = directory.appendingPathComponent(name, isDirectory: true)
            // renamex_np with RENAME_EXCL never replaces an existing folder.
            if renamex_np(staging.path, final.path, UInt32(RENAME_EXCL)) == 0 {
                finished = true
                return final
            }
            guard errno == EEXIST, attempt < 100 else { throw BackupError.io("rename backup folder (\(errno))") }
            attempt += 1
            name = "Arena Suite Backup \(stamp) \(attempt)"
        }
    }

    // MARK: Check

    /// Re-hashes every file against the manifest, rejects extra or missing files, verifies each
    /// journal, and replays the journals to the manifest's digest. Read-only.
    public func check(_ backup: URL) async throws -> BackupCheck {
        let manifest = try Self.loadManifest(backup)
        guard manifest.format == BackupManifest.currentFormat else { throw BackupError.unsupportedFormat(manifest.format) }
        var expected: [String: String] = [:]
        for journal in manifest.journals {
            guard let uuid = UUID(uuidString: journal.account), uuid.uuidString == journal.account else {
                throw BackupError.fileMismatch("account \(journal.account)")
            }
            for segment in journal.segments {
                let name = String(format: "%06d", segment.segment)
                expected["accounts/\(journal.account)/journal/segments/\(name).asj"] = segment.sha256
                if segment.sealed { expected["accounts/\(journal.account)/journal/segments/\(name).seal.json"] = "" }
            }
        }
        if let registry = manifest.registrySHA256 { expected["accounts/registry.json"] = registry }
        let present = try Self.regularFiles(under: backup).filter { $0 != Self.manifestName }
        for path in present where expected[path] == nil { throw BackupError.fileMismatch("unexpected \(path)") }
        for (path, digest) in expected.sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled else { throw BackupError.cancelled }
            guard present.contains(path) else { throw BackupError.fileMismatch("missing \(path)") }
            // Seal manifests are checked by the journal verifier below.
            if !digest.isEmpty, try JournalCopy.sha256(of: backup.appendingPathComponent(path)) != digest {
                throw BackupError.fileMismatch("changed \(path)")
            }
        }
        var records = 0
        for journal in manifest.journals {
            let root = backup.appendingPathComponent("accounts/\(journal.account)/journal", isDirectory: true)
            let check = VerificationService.checkJournal(
                account: AccountID(rawValue: UUID(uuidString: journal.account)!), root: root)
            if let issue = check.issues.first { throw BackupError.journalDamaged(account: journal.account, issue: issue) }
            guard UInt64(check.records) == journal.segments.reduce(0, { $0 + $1.recordCount }) else {
                throw BackupError.fileMismatch("record count of \(journal.account)")
            }
            records += check.records
        }
        let replay = try await Self.replayDigest(root: backup, journals: manifest.journals, decoder: decoder)
        guard replay == manifest.replayDigest else { throw BackupError.replayMismatch }
        return BackupCheck(manifest: manifest, accounts: manifest.journals.count, records: records, replayDigest: replay)
    }

    // MARK: Restore

    /// Checks `backup`, then copies its journals and registry into this archive root. Only allowed
    /// when the archive has no accounts and no journals, so a restore can never overwrite or mix with
    /// existing evidence. The caller reloads accounts and rebuilds the index afterwards.
    public func restore(from backup: URL) async throws -> BackupCheck {
        let check = try await self.check(backup)
        let accounts = archiveRoot.appendingPathComponent("accounts", isDirectory: true)
        guard canRestore else { throw BackupError.targetNotEmpty }

        try PrivateFile.prepareDirectory(archiveRoot)
        // Staging left by an interrupted restore holds only copies.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: archiveRoot.path)) ?? []
        where name.hasPrefix(".restore-") {
            try? FileManager.default.removeItem(at: archiveRoot.appendingPathComponent(name))
        }
        let staging = archiveRoot.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        try PrivateFile.prepareDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedAccounts = staging.appendingPathComponent("accounts", isDirectory: true)
        for journal in check.manifest.journals {
            let from = backup.appendingPathComponent("accounts/\(journal.account)/journal", isDirectory: true)
            let to = stagedAccounts.appendingPathComponent("\(journal.account)/journal", isDirectory: true)
            try PrivateFile.prepareDirectory(to)
            let copied: [CopiedSegment]
            do { copied = try JournalCopy.copy(from: from, to: to) } catch {
                throw BackupError.journalDamaged(account: journal.account, issue: VerificationService.describe(error))
            }
            guard copied == journal.segments else { throw BackupError.fileMismatch("restored journal \(journal.account)") }
        }
        if let digest = check.manifest.registrySHA256 {
            // Re-read and re-hash: the backup folder may have changed since it was checked.
            let staged = stagedAccounts.appendingPathComponent("registry.json")
            // Plain read: the backup may live on a drive where permissions cannot be changed.
            guard let data = try? Data(contentsOf: backup.appendingPathComponent("accounts/registry.json")) else {
                throw BackupError.fileMismatch("missing accounts/registry.json")
            }
            try PrivateFile.write(data, to: staged)
            guard try JournalCopy.sha256(of: staged) == digest else { throw BackupError.fileMismatch("changed accounts/registry.json") }
        }
        // Install with one rename. An existing `accounts` folder may only hold an empty account list
        // (all accounts removed, no journals kept; checked above), so it is removed first. A crash
        // in between leaves an empty archive, never a partial one; the staging folder is swept on
        // the next restore.
        if FileManager.default.fileExists(atPath: accounts.path) {
            let names = try FileManager.default.contentsOfDirectory(atPath: accounts.path)
            guard names.allSatisfy(Self.disposableAccountFiles.contains) else { throw BackupError.targetNotEmpty }
            try FileManager.default.removeItem(at: accounts)
        }
        guard renamex_np(stagedAccounts.path, accounts.path, UInt32(RENAME_EXCL)) == 0 else {
            throw BackupError.io("install restored accounts (\(errno))")
        }
        return check
    }

    /// True while the archive has no accounts and no journals: the only state a restore may target.
    public var canRestore: Bool {
        let accounts = archiveRoot.appendingPathComponent("accounts", isDirectory: true)
        let registry = AccountRegistryStore(url: accounts.appendingPathComponent("registry.json"))
        return ((try? registry.load())?.isEmpty ?? false) && JournalStore(archiveRoot: archiveRoot).accountsOnDisk().isEmpty
    }

    static let disposableAccountFiles: Set<String> = ["registry.json", "registry.json.tmp", ".DS_Store"]

    // MARK: Helpers

    static func replayDigest(root: URL, journals: [BackupManifest.Journal], decoder: any ArchiveDecoding) async throws
        -> String
    {
        let accounts = journals.compactMap { UUID(uuidString: $0.account) }.map { AccountID(rawValue: $0) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arena-suite-replay-\(UUID().uuidString)", isDirectory: true)
        return try await ArchiveService.replay(
            journals: JournalStore(archiveRoot: root), accounts: accounts, decoder: decoder, scratch: scratch
        ).digest
    }

    static func loadManifest(_ backup: URL) throws -> BackupManifest {
        guard let data = try? Data(contentsOf: backup.appendingPathComponent(manifestName)) else {
            throw BackupError.notABackup
        }
        guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            throw BackupError.notABackup
        }
        return manifest
    }

    static func encode(_ manifest: BackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    /// Relative paths of all regular files under `root`. Symlinks and other types are rejected.
    static func regularFiles(under root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        else { throw BackupError.notABackup }
        let base = root.standardizedFileURL.path + "/"
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true { continue }
            if url.lastPathComponent == ".DS_Store" { continue }  // Finder may add these when the folder is viewed
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw BackupError.fileMismatch("not a regular file: \(url.lastPathComponent)")
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { throw BackupError.fileMismatch(url.lastPathComponent) }
            paths.append(String(path.dropFirst(base.count)))
        }
        return paths.sorted()
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: date)
    }
}
