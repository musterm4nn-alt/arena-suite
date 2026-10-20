import CryptoKit
import Darwin
import Foundation

/// Content-addressed files beside an account's journal (plan v3 §9.4): `<root>/sha256/<hex>`, each
/// named by the SHA-256 of its bytes. It knows nothing about what the bytes are. A journal record
/// that stores its body here names it with `object_sha256` and `object_size` and declares the
/// payload representation `object_reference` (`Docs/journal-format-v1.md`).
///
/// `put` returns only after the file is renamed into place and its directory synced, so a record
/// appended afterwards never names a file that isn't there. A file written without its record (the
/// app stopped in between) is harmless: nothing names it.
public struct ObjectStore: Sendable {
    /// Metadata keys of a record whose body is stored as an object.
    public static let digestKey = "object_sha256"
    public static let sizeKey = "object_size"
    public static let representation = "object_reference"

    public struct Stored: Sendable, Equatable {
        public let sha256: String
        public let size: Int

        public init(sha256: String, size: Int) {
            self.sha256 = sha256
            self.size = size
        }
    }

    public enum State: Sendable, Equatable {
        case present
        case missing
        /// The file's bytes don't hash to its name, or its size differs from the expected one.
        case damaged
    }

    public let root: URL
    private let io: JournalIO
    private let fullSync: Bool

    public init(root: URL, durability: JournalOptions.Durability = .fullSync) {
        self.init(root: root, durability: durability, io: .system)
    }

    @_spi(JournalTesting) public init(root: URL, durability: JournalOptions.Durability, io: JournalIO) {
        self.root = root
        self.io = io
        fullSync = durability == .fullSync
    }

    var directory: URL { root.appendingPathComponent("sha256", isDirectory: true) }

    /// Lowercase hex SHA-256: the only names this store reads or writes.
    public static func isObjectName(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Creates the folders (0700), removes temporary files an interrupted `put` left behind, and
    /// makes object files private (0600) again, as the journal does on open (files copied or
    /// restored by hand). Call before a job's first `put`; one job per account runs at a time, so
    /// no temporary file is in use.
    public func open() throws {
        try prepare()
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let path = directory.appendingPathComponent(name).path
            if name.hasPrefix(".") && name.hasSuffix(".tmp") {
                unlink(path)
                continue
            }
            var info = stat()
            guard Self.isObjectName(name), lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_mode & 0o7777 != 0o600
            else { continue }
            if chmod(path, 0o600) != 0 { throw JournalError.io(operation: "chmod object", errno: errno) }
        }
    }

    /// Stores `data` under its SHA-256. An object already there with these bytes is kept; one whose
    /// bytes differ (damaged) is replaced.
    public func put(_ data: Data) throws -> Stored {
        let digest = sha256Hex(data)
        let stored = Stored(sha256: digest, size: data.count)
        try prepare()
        if state(digest, size: data.count) == .present { return stored }
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { unlink(temporary.path) }  // gone after the rename; removes it after a failure
        try io.writeAtomically(
            data, to: directory.appendingPathComponent(digest), temporary: temporary, full: fullSync, beforeRename: {})
        return stored
    }

    /// The object's bytes, checked against its name.
    public func read(_ sha256: String) throws -> Data {
        guard Self.isObjectName(sha256) else { throw ObjectStoreError.missing }
        let url = directory.appendingPathComponent(sha256)
        guard isRegularFile(url) else { throw ObjectStoreError.missing }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw ObjectStoreError.unreadable
        }
        guard sha256Hex(data) == sha256 else { throw ObjectStoreError.damaged }
        return data
    }

    /// Whether the object is present with the right bytes (and size, when given). Read-only.
    public func state(_ sha256: String, size: Int? = nil) -> State {
        guard Self.isObjectName(sha256), isRegularFile(directory.appendingPathComponent(sha256)) else { return .missing }
        guard let data = try? read(sha256) else { return .damaged }
        return size.map { $0 == data.count } == false ? .damaged : .present
    }

    /// Whether a file with this name exists, without reading it.
    public func contains(_ sha256: String) -> Bool {
        Self.isObjectName(sha256) && isRegularFile(directory.appendingPathComponent(sha256))
    }

    /// Names of every object file, sorted. Temporary files and anything else are left out.
    public func names() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { Self.isObjectName($0) && isRegularFile(directory.appendingPathComponent($0)) }
            .sorted()
    }

    /// URL of an object file, for copying it whole. nil for a name this store never writes.
    public func url(for sha256: String) -> URL? {
        Self.isObjectName(sha256) ? directory.appendingPathComponent(sha256) : nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// `root` and `root/sha256`, private. A new folder's parent is synced so the folder survives a
    /// power loss along with the file renamed into it.
    private func prepare() throws {
        let parent = root.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw JournalError.io(operation: "create \(parent.lastPathComponent)", errno: EIO)
            }
        }
        for folder in [root, directory] {
            var info = stat()
            if lstat(folder.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw JournalError.io(operation: "refuse non-folder \(folder.lastPathComponent)", errno: ENOTDIR)
                }
                if info.st_mode & 0o7777 != 0o700, chmod(folder.path, 0o700) != 0 {
                    throw JournalError.io(operation: "chmod \(folder.lastPathComponent)", errno: errno)
                }
                continue
            }
            guard mkdir(folder.path, 0o700) == 0 || errno == EEXIST else {
                throw JournalError.io(operation: "create \(folder.lastPathComponent)", errno: errno)
            }
            try io.synchronizeDirectory(folder.deletingLastPathComponent(), full: fullSync, operation: "sync directory")
        }
    }
}

/// A journal record that names an object (`object_sha256`, `object_size`).
public struct ObjectReference: Sendable, Equatable {
    public let sequence: UInt64
    /// nil when the record's digest is not an object name.
    public let sha256: String?
    /// nil when the record states no valid size.
    public let size: Int?
}

extension ObjectStore {
    /// Every record of the journal at `root` that names an object, in sequence order.
    public static func references(inJournalAt root: URL) throws -> [ObjectReference] {
        var references: [ObjectReference] = []
        try JournalReader(root: root).forEach { record in
            let metadata = record.envelope.metadata
            guard let named = metadata[digestKey] else { return }
            var sha256: String?
            if case .string(let value) = named, isObjectName(value) { sha256 = value }
            var size: Int?
            if case .integer(let value) = metadata[sizeKey], value >= 0 { size = Int(value) }
            references.append(ObjectReference(sequence: record.envelope.sequence, sha256: sha256, size: size))
        }
        return references
    }
}

public enum ObjectStoreError: Error, Equatable, Sendable {
    case missing
    case damaged
    case unreadable
}
