import AppleArchive
import Foundation
import System

/// Encrypted backups (`Docs/encrypted-backup-2026-10-20.md`): the plain backup folder sealed into
/// one Apple Encrypted Archive (AEA) file, keyed by a passphrase. The profile derives the key with
/// scrypt, encrypts with AES-CTR and authenticates every segment with HMAC-SHA256. Apple's framework
/// does the cryptography, and macOS's `aea` and `aa` tools open the file without Arena Suite. The
/// passphrase is never stored.
extension BackupService {
    public static let encryptedExtension = "aea"
    /// macOS's encrypted archives take a password of 20 to 256 bytes in UTF-8. Twenty characters
    /// always make at least 20 bytes.
    public static let minimumPassphraseLength = 20
    public static let maximumPassphraseBytes = 256
    static var encryptedProfile: ArchiveEncryptionContext.Profile { .hkdf_sha256_aesctr_hmac__scrypt__none }
    /// Type, path and data only: no owner, permissions, times or extended attributes.
    static let encryptedFields = "TYP,PAT,DAT"
    static let plainCopyPrefix = "arena-suite-plain-backup-"

    /// The passphrase as used (Unicode NFC), or why it cannot be used.
    public static func usablePassphrase(_ passphrase: String) -> Result<String, BackupError> {
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        if normalized.count < minimumPassphraseLength { return .failure(.passphraseTooShort) }
        if normalized.utf8.count > maximumPassphraseBytes { return .failure(.passphraseTooLong) }
        return .success(normalized)
    }

    // MARK: Create

    /// Writes `Arena Suite Backup <stamp>.aea` into `directory`, never over anything, appearing only
    /// when complete. The plain copy it encrypts is made in a private temporary folder, never in
    /// `directory`, and is removed afterwards whatever happens.
    public func createEncrypted(in directory: URL, passphrase: String, now: Date = Date()) async throws -> URL {
        let passphrase = try Self.usablePassphrase(passphrase).get()
        Self.sweepStale(in: directory, now: now) { $0.hasPrefix(".arena-suite-backup-") && $0.hasSuffix(".aea.partial") }
        let plainRoot = try Self.privatePlainCopy(now: now)
        defer { try? FileManager.default.removeItem(at: plainRoot) }
        let plain = try await create(in: plainRoot, now: now)
        guard !Task.isCancelled else { throw BackupError.cancelled }

        let staging = directory.appendingPathComponent(".arena-suite-backup-\(UUID().uuidString).aea.partial")
        var finished = false
        defer { if !finished { unlink(staging.path) } }
        try Self.seal(folder: plain, passphrase: passphrase, to: staging)
        guard !Task.isCancelled else { throw BackupError.cancelled }
        try Self.fullSync(staging)

        let stamp = Self.stamp(now)
        var name = "Arena Suite Backup \(stamp).\(Self.encryptedExtension)"
        var attempt = 1
        while true {
            let final = directory.appendingPathComponent(name)
            // renamex_np with RENAME_EXCL never replaces an existing file.
            if renamex_np(staging.path, final.path, UInt32(RENAME_EXCL)) == 0 {
                finished = true
                Self.syncDirectory(directory)
                return final
            }
            guard errno == EEXIST, attempt < 100 else { throw BackupError.io("rename backup file (\(errno))") }
            attempt += 1
            name = "Arena Suite Backup \(stamp) \(attempt).\(Self.encryptedExtension)"
        }
    }

    // MARK: Check and restore

    /// Decrypts `file` into a private temporary folder, checks it like a plain backup folder, and
    /// removes the folder.
    public func checkEncrypted(_ file: URL, passphrase: String) async throws -> BackupCheck {
        let plainRoot = try Self.privatePlainCopy(now: Date())
        defer { try? FileManager.default.removeItem(at: plainRoot) }
        return try await check(try Self.open(file, passphrase: passphrase, into: plainRoot))
    }

    /// Decrypts `file` into a private temporary folder, restores from it like a plain backup folder
    /// (only into an empty archive), and removes the folder.
    public func restoreEncrypted(from file: URL, passphrase: String) async throws -> BackupCheck {
        Self.recoverSetAsideAccounts(in: archiveRoot)
        guard canRestore else { throw BackupError.targetNotEmpty }
        let plainRoot = try Self.privatePlainCopy(now: Date())
        defer { try? FileManager.default.removeItem(at: plainRoot) }
        return try await restore(from: try Self.open(file, passphrase: passphrase, into: plainRoot))
    }

    // MARK: Sealing and opening

    static func seal(folder: URL, passphrase: String, to file: URL) throws {
        let context = ArchiveEncryptionContext(profile: encryptedProfile, compressionAlgorithm: .lzfse)
        do { try context.setPassword(passphrase) } catch { throw BackupError.io("the encryption did not accept the passphrase") }
        guard let fields = ArchiveHeader.FieldKeySet(encryptedFields) else { throw BackupError.io("archive fields") }
        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(file.path), mode: .writeOnly, options: [.create, .exclusiveCreate], permissions: [.ownerReadWrite]
            ) { target in
                guard let encrypted = ArchiveByteStream.encryptionStream(writingTo: target, encryptionContext: context) else {
                    throw BackupError.io("open the encryption")
                }
                var closed = false
                defer { if !closed { try? encrypted.close() } }
                try ArchiveStream.withEncodeStream(writingTo: encrypted) { encoder in
                    try encoder.writeDirectoryContents(archiveFrom: FilePath(folder.path), keySet: fields)
                }
                closed = true
                try encrypted.close()
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.io("encrypt the backup (\(error))")
        }
    }

    /// Decrypts `file` into `root` and returns `root`. Only directories and regular files with safe
    /// relative paths are written (no absolute path, `.`/`..` component, duplicate, or path under a
    /// file), each new and owner-only; anything else is refused. Apple Archive's decoder refuses such
    /// paths too.
    ///
    /// AEA authenticates its header with the key derived from the passphrase, so a decryption that
    /// starts proves the passphrase right: a later decoding failure is damaged content. A wrong
    /// passphrase and a damaged header look the same. Failures writing into `root`, or reading
    /// `file` (it is read again to tell), are this Mac's (`io`), never reported as damage. Opening
    /// applies only AEA's own limits (20–256 bytes), which `setPassword` enforces: a passphrase
    /// outside them is `wrongPassphraseOrDamaged`. On a refusal the caller removes `root`.
    static func open(_ file: URL, passphrase: String, into root: URL) throws -> URL {
        // A regular file only (a link to one is followed): a pipe or device could block or never end.
        var info = stat()
        guard stat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw BackupError.notABackup }
        let passphrase = passphrase.precomposedStringWithCanonicalMapping
        do {
            try ArchiveByteStream.withFileStream(path: FilePath(file.path), mode: .readOnly, options: [], permissions: []) { source in
                guard let context = ArchiveEncryptionContext(from: source) else { throw BackupError.notABackup }
                guard context.profile == encryptedProfile else {
                    throw BackupError.unsupportedFormat("encrypted archive profile \(context.profile)")
                }
                do { try context.setPassword(passphrase) } catch { throw BackupError.wrongPassphraseOrDamaged }
                guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: source, encryptionContext: context) else {
                    throw BackupError.wrongPassphraseOrDamaged
                }
                var closed = false
                defer { if !closed { try? decrypted.close() } }
                do {
                    try ArchiveStream.withDecodeStream(readingFrom: decrypted) { try unpack($0, into: root) }
                    closed = true
                    try decrypted.close()
                } catch let error as BackupError {
                    throw error
                } catch {
                    // The decoder and the final close report a failed read and damaged content alike.
                    // A file that cannot be read again to its end is this Mac's problem (a failing
                    // disk), not damage.
                    guard readsToTheEnd(file) else { throw BackupError.io("read \(file.lastPathComponent)") }
                    throw BackupError.encryptedContentDamaged
                }
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.io("read \(file.lastPathComponent) (\(error))")
        }
        return root
    }

    private static func unpack(_ decoder: ArchiveStream, into root: URL) throws {
        let pathKey = ArchiveHeader.FieldKey("PAT"), typeKey = ArchiveHeader.FieldKey("TYP"), dataKey = ArchiveHeader.FieldKey("DAT")
        let directoryType = UInt64(ArchiveHeader.EntryType.directory.rawValue)
        let fileType = UInt64(ArchiveHeader.EntryType.regularFile.rawValue)
        var seen: Set<String> = [], files: Set<String> = []
        while let header = try decoder.readHeader() {
            guard !Task.isCancelled else { throw BackupError.cancelled }
            guard case .string(_, let path)? = header.field(forKey: pathKey) else { throw BackupError.unsafeEntry("an entry without a path") }
            guard case .uint(_, let type)? = header.field(forKey: typeKey), type == directoryType || type == fileType else {
                throw BackupError.unsafeEntry(path)
            }
            // The archive's own root folder.
            if path.isEmpty, type == directoryType { continue }
            guard let components = safeComponents(path) else { throw BackupError.unsafeEntry(path) }
            let joined = components.joined(separator: "/")
            let parents = (1..<components.count).map { components[..<$0].joined(separator: "/") }
            guard seen.insert(joined).inserted, !parents.contains(where: files.contains) else { throw BackupError.unsafeEntry(path) }
            let url = components.reduce(root) { $0.appendingPathComponent($1) }
            if type == directoryType {
                try makeDirectory(url)
                continue
            }
            files.insert(joined)
            let size: UInt64
            // Apple Archive writes a data field for every file, empty ones included.
            guard case .blob(_, let declared, _)? = header.field(forKey: dataKey) else { throw BackupError.encryptedContentDamaged }
            size = declared
            try makeDirectory(url.deletingLastPathComponent())
            try writeEntry(from: decoder, key: dataKey, size: size, to: url)
        }
    }

    private static func makeDirectory(_ url: URL) throws {
        do { try PrivateFile.prepareDirectory(url) } catch { throw BackupError.io("create folder \(url.lastPathComponent) (\(error))") }
    }

    /// Relative path components, or nil for an absolute path, an empty, `.` or `..` component, a
    /// component longer than a file name may be (255 bytes), or a NUL byte.
    static func safeComponents(_ path: String) -> [String]? {
        guard !path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            return nil
        }
        return components
    }

    /// A new owner-only file, its data read in 1 MiB pieces. A path an earlier entry already holds is
    /// refused; other failures are this Mac's.
    private static func writeEntry(from decoder: ArchiveStream, key: ArchiveHeader.FieldKey, size: UInt64, to url: URL) throws {
        let fd = Foundation.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            let code = errno
            if [EEXIST, ELOOP, ENOTDIR, ENAMETOOLONG].contains(code) { throw BackupError.unsafeEntry(url.lastPathComponent) }
            throw BackupError.io("create \(url.lastPathComponent) (\(code))")
        }
        var closed = false
        defer { if !closed { close(fd) } }
        var remaining = size
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while remaining > 0 {
            let count = Int(min(UInt64(buffer.count), remaining))
            try buffer.withUnsafeMutableBytes { try decoder.readBlob(key: key, into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<count])) }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { Foundation.write(fd, $0.baseAddress! + offset, count - offset) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw BackupError.io("write \(url.lastPathComponent) (\(written < 0 ? errno : EIO))") }
                offset += written
            }
            remaining -= UInt64(count)
        }
        closed = true
        guard close(fd) == 0 else { throw BackupError.io("close \(url.lastPathComponent) (\(errno))") }
    }

    // MARK: Helpers

    /// A new owner-only folder in this user's temporary directory. Folders of ours an earlier crash
    /// left behind (older than an hour) are removed first.
    static func privatePlainCopy(now: Date) throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
        sweepStale(in: temporary, now: now) { $0.hasPrefix(plainCopyPrefix) }
        let folder = temporary.appendingPathComponent(plainCopyPrefix + UUID().uuidString, isDirectory: true)
        try makeDirectory(folder)
        return folder
    }

    /// Whether `file` can be read from start to end.
    static func readsToTheEnd(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        do {
            // nil or empty at the end; a failed read throws.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {}
            return true
        } catch {
            return false
        }
    }

    static func sweepStale(in directory: URL, now: Date, matching: (String) -> Bool) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where matching(name) {
            let url = directory.appendingPathComponent(name)
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                now.timeIntervalSince(modified) > 3600
            {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func fullSync(_ file: URL) throws {
        let fd = Foundation.open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw BackupError.io("open \(file.lastPathComponent) (\(errno))") }
        defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw BackupError.io("sync \(file.lastPathComponent) (\(errno))") }
    }

    static func syncDirectory(_ directory: URL) {
        let fd = Foundation.open(directory.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
    }
}
