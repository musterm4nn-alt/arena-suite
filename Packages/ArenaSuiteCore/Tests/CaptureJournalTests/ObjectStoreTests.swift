import CryptoKit
import Darwin
import Foundation
import Testing

@_spi(JournalTesting) @testable import CaptureJournal

private func storeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("objects-tests-\(UUID().uuidString)/objects")
}

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func mode(_ url: URL) -> mode_t {
    var info = stat()
    lstat(url.path, &info)
    return info.st_mode & 0o7777
}

@Test func putStoresBytesUnderTheirDigestPrivately() throws {
    let store = ObjectStore(root: storeRoot(), durability: .fsync)
    let bytes = Data("image bytes".utf8)
    let stored = try store.put(bytes)
    #expect(stored == ObjectStore.Stored(sha256: hex(bytes), size: bytes.count))
    let file = store.root.appendingPathComponent("sha256/\(hex(bytes))")
    #expect(try Data(contentsOf: file) == bytes)
    #expect(mode(file) == 0o600)
    #expect(mode(store.root) == 0o700 && mode(store.root.appendingPathComponent("sha256")) == 0o700)
    #expect(try store.read(stored.sha256) == bytes)
    #expect(store.state(stored.sha256, size: bytes.count) == .present)
    #expect(try store.names() == [stored.sha256])
    #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [stored.sha256])
}

@Test func theSameBytesTwiceKeepOneFile() throws {
    let store = ObjectStore(root: storeRoot(), durability: .fsync)
    let bytes = Data(repeating: 7, count: 4096)
    let first = try store.put(bytes)
    let file = try #require(store.url(for: first.sha256))
    let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
    #expect(try store.put(bytes) == first)
    let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
    #expect(inode == after, "an intact object is kept, not rewritten")
    #expect(try store.names().count == 1)
}

@Test func aDamagedObjectIsReportedAndReplacedByTheRightBytes() throws {
    let store = ObjectStore(root: storeRoot(), durability: .fsync)
    let bytes = Data("the right bytes".utf8)
    let stored = try store.put(bytes)
    let file = try #require(store.url(for: stored.sha256))
    try Data("the wrong bytes".utf8).write(to: file)
    #expect(store.state(stored.sha256) == .damaged)
    #expect(throws: ObjectStoreError.damaged) { try store.read(stored.sha256) }
    #expect(try store.put(bytes) == stored)
    #expect(try store.read(stored.sha256) == bytes)
    #expect(store.state(stored.sha256, size: bytes.count + 1) == .damaged, "a size that differs is damage too")
}

@Test func missingAndInvalidNamesAreMissing() throws {
    let store = ObjectStore(root: storeRoot(), durability: .fsync)
    let absent = String(repeating: "a", count: 64)
    #expect(store.state(absent) == .missing)
    #expect(!store.contains(absent))
    #expect(throws: ObjectStoreError.missing) { try store.read(absent) }
    for name in ["../x", String(repeating: "A", count: 64), "abc", String(repeating: "g", count: 64)] {
        #expect(!ObjectStore.isObjectName(name))
        #expect(store.url(for: name) == nil)
        #expect(throws: ObjectStoreError.missing) { try store.read(name) }
    }
    #expect(try store.names().isEmpty, "a store never written lists nothing")
}

@Test func aFailedWriteLeavesNoFileAndOpenRemovesTemporaryLeftovers() throws {
    let root = storeRoot()
    let failing = JournalIO(write: { _, _, _ in errno = ENOSPC; return -1 }, sync: { _, _ in 0 }, observe: { _ in })
    let broken = ObjectStore(root: root, durability: .fsync, io: failing)
    #expect(throws: JournalError.self) { _ = try broken.put(Data("x".utf8)) }
    let folder = root.appendingPathComponent("sha256")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

    let leftover = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
    try Data("partial".utf8).write(to: leftover)
    let store = ObjectStore(root: root, durability: .fsync)
    #expect(try store.names().isEmpty, "temporary files are never objects")
    try store.open()
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
}

@Test func openTightensFoldersAndRefusesAFileInPlaceOfOne() throws {
    let root = storeRoot()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sha256"), withIntermediateDirectories: true)
    chmod(root.path, 0o755)
    let store = ObjectStore(root: root, durability: .fsync)
    try store.open()
    #expect(mode(root) == 0o700)

    let other = storeRoot()
    try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: other)
    #expect(throws: JournalError.self) { try ObjectStore(root: other, durability: .fsync).open() }
}

@Test func aSymlinkInPlaceOfAnObjectIsNotRead() throws {
    let store = ObjectStore(root: storeRoot(), durability: .fsync)
    let bytes = Data("target".utf8)
    try store.open()
    let elsewhere = store.root.deletingLastPathComponent().appendingPathComponent("elsewhere")
    try bytes.write(to: elsewhere)
    let name = hex(bytes)
    try FileManager.default.createSymbolicLink(
        at: store.root.appendingPathComponent("sha256/\(name)"), withDestinationURL: elsewhere)
    #expect(store.state(name) == .missing)
    #expect(try store.names().isEmpty)
}

@Test func openMakesObjectFilesPrivateAgain() throws {
    let store = ObjectStore(root: storeRoot(), durability: .fsync)
    let stored = try store.put(Data("restored by hand".utf8))
    let file = try #require(store.url(for: stored.sha256))
    chmod(file.path, 0o644)
    // Not an object name: left alone.
    let other = store.root.appendingPathComponent("sha256/notes.txt")
    try Data("x".utf8).write(to: other)
    chmod(other.path, 0o644)
    try store.open()
    #expect(mode(file) == 0o600)
    #expect(mode(other) == 0o644)
    #expect(store.state(stored.sha256, size: stored.size) == .present)
}
