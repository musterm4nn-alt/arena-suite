import Foundation

/// Owner-only files for app state outside the journal (plan v3 §2): directories `0700`, files `0600`,
/// symlinks refused, permissions re-applied on every access so restored or pre-existing paths are
/// tightened too. Writes are atomic (temp file, full sync, rename, directory sync).
public enum PrivateFile {
    public enum Failure: Error, Equatable, Sendable {
        case symlink(String)
        case io(String, Int32)
    }

    /// Creates `directory` (and parents) if needed and enforces `0700` on it.
    public static func prepareDirectory(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try enforce(directory.path, mode: 0o700, directory: true)
    }

    /// Reads `url` after enforcing `0600` on it and `0700` on its directory. Returns nil if absent.
    public static func read(_ url: URL) throws -> Data? {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try enforce(directory.path, mode: 0o700, directory: true)
        guard try enforce(url.path, mode: 0o600, directory: false) else { return nil }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw Failure.io("read \(url.lastPathComponent)", EIO)
        }
        return data
    }

    /// `exclusive`: fail with `EEXIST` instead of replacing an existing file.
    public static func write(_ data: Data, to url: URL, exclusive: Bool = false) throws {
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory)
        if exclusive, FileManager.default.fileExists(atPath: url.path) { throw Failure.io("exists \(url.lastPathComponent)", EEXIST) }
        _ = try enforce(url.path, mode: 0o600, directory: false)
        let temporary = directory.appendingPathComponent(
            exclusive ? ".\(url.lastPathComponent).\(UUID().uuidString).tmp" : url.lastPathComponent + ".tmp")
        unlink(temporary.path)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.io("create \(temporary.lastPathComponent)", errno) }
        var failure: Failure?
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Foundation.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = .io("write \(temporary.lastPathComponent)", errno)
                    return
                }
                offset += written
            }
        }
        if failure == nil && fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 {
            failure = .io("sync \(temporary.lastPathComponent)", errno)
        }
        close(fd)
        if let failure {
            unlink(temporary.path)
            throw failure
        }
        let renamed = exclusive
            ? renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) : rename(temporary.path, url.path)
        guard renamed == 0 else {
            let code = errno
            unlink(temporary.path)
            throw Failure.io("rename \(url.lastPathComponent)", code)
        }
        let directoryFD = open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw Failure.io("open directory", errno) }
        defer { close(directoryFD) }
        guard fcntl(directoryFD, F_FULLFSYNC) == 0 || fsync(directoryFD) == 0 else {
            throw Failure.io("sync directory", errno)
        }
    }

    /// Returns false if the path does not exist. Throws on symlinks or wrong file types.
    @discardableResult
    private static func enforce(_ path: String, mode: mode_t, directory: Bool) throws -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw Failure.io("stat \((path as NSString).lastPathComponent)", errno)
        }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { throw Failure.symlink((path as NSString).lastPathComponent) }
        guard type == (directory ? S_IFDIR : S_IFREG) else {
            throw Failure.io("unexpected file type \((path as NSString).lastPathComponent)", EFTYPE)
        }
        if info.st_mode & 0o7777 != mode {
            guard chmod(path, mode) == 0 else { throw Failure.io("chmod \((path as NSString).lastPathComponent)", errno) }
        }
        return true
    }
}
