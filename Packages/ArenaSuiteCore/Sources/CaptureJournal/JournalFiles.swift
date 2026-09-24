import CryptoKit
import Darwin
import Foundation

struct JournalLayout: Sendable {
    let root: URL
    var segments: URL { root.appendingPathComponent("segments", isDirectory: true) }
    var quarantine: URL { root.appendingPathComponent("quarantine", isDirectory: true) }
    var lockFile: URL { root.appendingPathComponent("journal.lock") }

    static func name(_ segment: Int) -> String { String(format: "%06d", segment) }
    func segmentURL(_ segment: Int) -> URL { segments.appendingPathComponent(Self.name(segment) + ".asj") }
    func manifestURL(_ segment: Int) -> URL { segments.appendingPathComponent(Self.name(segment) + ".seal.json") }
    func temporaryManifestURL(_ segment: Int) -> URL {
        segments.appendingPathComponent(Self.name(segment) + ".seal.json.tmp")
    }

    /// Segment numbers present on disk, ascending.
    func segmentNumbers() throws -> [Int] {
        let names = try FileManager.default.contentsOfDirectory(atPath: segments.path)
        return names.compactMap { name -> Int? in
            guard name.hasSuffix(".asj"), name.count == 10 else { return nil }
            return Int(name.prefix(6))
        }.sorted()
    }

    /// Leftover atomic-write temp files in `segments/` and `quarantine/`.
    func temporaryFiles() throws -> [URL] {
        try [segments, quarantine].flatMap { directory -> [URL] in
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".tmp") }
                .map { directory.appendingPathComponent($0) }
        }
    }

    /// Owner-only access (plan v3 §2): directories 0700, files 0600. Applied on every open, so
    /// directories restored from a backup or created by other tools are tightened too. Fails closed.
    func enforcePrivatePermissions() throws {
        func tighten(_ path: String, to mode: mode_t) throws {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT { return }
                throw JournalError.io(operation: "stat \((path as NSString).lastPathComponent)", errno: errno)
            }
            guard (info.st_mode & S_IFMT) != S_IFLNK else {
                throw JournalError.io(operation: "refuse symlink \((path as NSString).lastPathComponent)", errno: ELOOP)
            }
            guard info.st_mode & 0o7777 != mode else { return }
            guard chmod(path, mode) == 0 else {
                throw JournalError.io(operation: "chmod \((path as NSString).lastPathComponent)", errno: errno)
            }
        }
        for directory in [root, segments, quarantine] {
            try tighten(directory.path, to: 0o700)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let path = directory.appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                if !isDirectory.boolValue { try tighten(path, to: 0o600) }
            }
        }
    }
}

/// Seal manifest. Integers that can exceed 2^53 are strings, as in envelopes.
struct SealManifest: Codable, Equatable, Sendable {
    let format: Int
    let segment: Int
    let byteSize: UInt64
    let firstSequence: UInt64
    let lastSequence: UInt64
    let recordCount: UInt64
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case format, segment
        case byteSize = "byte_size"
        case firstSequence = "first_sequence"
        case lastSequence = "last_sequence"
        case recordCount = "record_count"
        case sha256
    }

    init(segment: Int, byteSize: UInt64, firstSequence: UInt64, lastSequence: UInt64, recordCount: UInt64, sha256: String) {
        self.format = 1
        self.segment = segment
        self.byteSize = byteSize
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.recordCount = recordCount
        self.sha256 = sha256
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) throws -> UInt64 {
            guard let value = UInt64(try c.decode(String.self, forKey: key)) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not a decimal UInt64")
            }
            return value
        }
        format = try c.decode(Int.self, forKey: .format)
        segment = try c.decode(Int.self, forKey: .segment)
        byteSize = try number(.byteSize)
        firstSequence = try number(.firstSequence)
        lastSequence = try number(.lastSequence)
        recordCount = try number(.recordCount)
        sha256 = try c.decode(String.self, forKey: .sha256)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(segment, forKey: .segment)
        try c.encode(String(byteSize), forKey: .byteSize)
        try c.encode(String(firstSequence), forKey: .firstSequence)
        try c.encode(String(lastSequence), forKey: .lastSequence)
        try c.encode(String(recordCount), forKey: .recordCount)
        try c.encode(sha256, forKey: .sha256)
    }

    static func load(_ url: URL, segment: Int) throws -> SealManifest {
        guard let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(SealManifest.self, from: data),
            manifest.format == 1, manifest.segment == segment
        else { throw JournalError.invalidManifest(segment: segment) }
        return manifest
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Where a write is about to happen. Exposed to tests and the crash harness so they can
/// inject faults or terminate the process at exact boundaries.
public struct JournalWritePoint: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case header, envelope
        case payloadChunk(offset: Int)
        case digest
        /// Record fully written, before `append` returns.
        case appended
        /// Sync completed, before `synchronize` returns.
        case synchronized
        /// Seal manifest temp file written and synced, before rename.
        case sealTemporaryWritten
        /// Seal manifest renamed into place, before the next segment exists.
        case sealRenamed
    }
    public let sequence: UInt64
    public let stage: Stage
}

/// System-call seam. Production uses `.system`; tests inject faults.
@_spi(JournalTesting) public struct JournalIO: Sendable {
    public var write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    /// Returns 0 on success, -1 with `errno` set on failure.
    public var sync: @Sendable (Int32, _ full: Bool) -> Int32
    public var observe: @Sendable (JournalWritePoint) -> Void

    public init(
        write: @escaping @Sendable (Int32, UnsafeRawPointer, Int) -> Int,
        sync: @escaping @Sendable (Int32, Bool) -> Int32,
        observe: @escaping @Sendable (JournalWritePoint) -> Void
    ) {
        self.write = write
        self.sync = sync
        self.observe = observe
    }

    public static let system = JournalIO(
        write: { Darwin.write($0, $1, $2) },
        sync: { fd, full in
            if full && fcntl(fd, F_FULLFSYNC) == 0 { return 0 }
            return fsync(fd)
        },
        observe: { _ in })
}

extension JournalIO {
    func writeAll(_ fd: Int32, _ data: Data, operation: String) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw JournalError.io(operation: operation, errno: code)
                }
                if written == 0 { throw JournalError.io(operation: operation, errno: EIO) }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    func synchronize(_ fd: Int32, full: Bool, operation: String) throws {
        while sync(fd, full) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw JournalError.io(operation: operation, errno: code)
        }
    }

    /// `full` requests F_FULLFSYNC; the system seam falls back to fsync where a directory
    /// descriptor does not support it.
    func synchronizeDirectory(_ url: URL, full: Bool, operation: String) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw JournalError.io(operation: operation, errno: errno) }
        defer { close(fd) }
        try synchronize(fd, full: full, operation: operation)
    }

    /// Temp file → sync → rename → directory sync.
    func writeAtomically(_ data: Data, to url: URL, temporary: URL, full: Bool, beforeRename: () -> Void) throws {
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw JournalError.io(operation: "create \(temporary.lastPathComponent)", errno: errno) }
        do {
            try writeAll(fd, data, operation: "write \(temporary.lastPathComponent)")
            try synchronize(fd, full: full, operation: "sync \(temporary.lastPathComponent)")
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        beforeRename()
        guard rename(temporary.path, url.path) == 0 else {
            throw JournalError.io(operation: "rename \(url.lastPathComponent)", errno: errno)
        }
        try synchronizeDirectory(url.deletingLastPathComponent(), full: full, operation: "sync directory")
    }
}
