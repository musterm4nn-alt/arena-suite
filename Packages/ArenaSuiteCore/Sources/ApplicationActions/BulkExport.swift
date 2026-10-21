import CryptoKit
import Foundation
import SuiteDomain

/// Exports many conversations at once (Docs/bulk-export-2026-10-21.md): each one's latest snapshot,
/// frozen when the export starts, rendered exactly as a single export renders it, into one new folder
/// with a `manifest.json`. The folder is built hidden and appears under its name only when complete;
/// a cancelled or failed export leaves nothing behind.
public struct BulkExportService: Sendable {
    public static let manifestSchema = "arena-suite-bulk-export/1"
    static let stagingPrefix = ".arena-suite-bulk-"
    static let stagingSuffix = ".partial"

    public struct Target: Sendable, Hashable {
        public let account: AccountID
        public let remoteID: String
        public init(account: AccountID, remoteID: String) {
            self.account = account
            self.remoteID = remoteID
        }
    }

    /// Why a conversation has no file. Recorded in the manifest by raw value.
    public enum SkipReason: String, Sendable, Equatable, CaseIterable {
        case notInArchive = "not_in_archive"
        /// Listed on Arena only: there is no transcript to export.
        case noSnapshot = "no_snapshot"
        case noLastAnswer = "no_last_answer"
        case lastMessageNotInSnapshot = "last_message_not_in_snapshot"
        case lastMessagesUnreadable = "last_messages_unreadable"
        case rawRecordUnavailable = "raw_record_unavailable"
    }

    public struct Skipped: Sendable, Equatable {
        public let target: Target
        public let reason: SkipReason
        public init(target: Target, reason: SkipReason) {
            self.target = target
            self.reason = reason
        }
    }

    public struct Result: Sendable, Equatable {
        public let folder: URL
        public let exported: Int
        public let skipped: [Skipped]
        public let bytes: Int
    }

    private let archive: ArchiveService

    public init(archive: ArchiveService) { self.archive = archive }

    /// `progress` gets (conversations handled, total) after each one. Throws `ExportError.cancelled`
    /// or `.writeFailed` after removing the unfinished folder; skips never throw.
    public func export(
        _ targets: [Target], options: ExportOptions, into destination: URL, now: Date = Date(),
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Result {
        guard options.scope == .wholeConversation || options.format.supportsLastAnswer else { throw ExportError.scopeNotAvailable }
        var unique: [Target] = []
        var seen = Set<Target>()
        for target in targets where seen.insert(target).inserted { unique.append(target) }

        // Frozen first: a sync while the export runs doesn't change which snapshot is exported.
        var planned: [(Target, UInt64)] = []
        var skipped: [Skipped] = []
        for target in unique {
            guard let held = try archive.conversation(account: target.account, remoteID: target.remoteID, snapshot: nil) else {
                skipped.append(Skipped(target: target, reason: .notInArchive))
                continue
            }
            guard let latest = held.summary.latestSnapshotSequence else {
                skipped.append(Skipped(target: target, reason: .noSnapshot))
                continue
            }
            planned.append((target, latest))
        }

        let staging = try Self.makeStaging(in: destination)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: staging) } }
        let single = ExportService(archive: archive)
        var files: [[String: Any]] = []
        var bytes = 0
        progress(unique.count - planned.count, unique.count)
        for (index, (target, sequence)) in planned.enumerated() {
            guard !Task.isCancelled else { throw ExportError.cancelled }
            do {
                let result = try await single.export(
                    account: target.account, remoteID: target.remoteID, snapshot: sequence, options: options, to: staging)
                bytes += result.byteCount
                files.append([
                    "account": target.account.rawValue.uuidString, "remote_id": target.remoteID,
                    "snapshot_sequence": String(sequence), "file": result.url.lastPathComponent,
                    "bytes": result.byteCount, "sha256": result.sha256,
                ])
            } catch let error as ExportError {
                switch error {
                case .noLastAnswer: skipped.append(Skipped(target: target, reason: .noLastAnswer))
                case .lastMessageNotInSnapshot: skipped.append(Skipped(target: target, reason: .lastMessageNotInSnapshot))
                case .lastMessagesUnreadable: skipped.append(Skipped(target: target, reason: .lastMessagesUnreadable))
                case .rawRecordUnavailable: skipped.append(Skipped(target: target, reason: .rawRecordUnavailable))
                case .conversationNotFound, .snapshotNotInConversation: skipped.append(Skipped(target: target, reason: .notInArchive))
                default: throw error
                }
            }
            progress(unique.count - planned.count + index + 1, unique.count)
        }
        guard !Task.isCancelled else { throw ExportError.cancelled }

        let manifest: [String: Any] = [
            "schema": Self.manifestSchema,
            "created_at": ISO8601DateFormatter().string(from: now),
            "format": options.format.rawValue, "scope": options.scope.rawValue,
            "redaction_policy": ExportService.redactionPolicy, "exact_raw_bodies": options.includeExactRawBodies,
            "conversations_requested": unique.count, "files": files,
            "skipped": skipped.map {
                ["account": $0.target.account.rawValue.uuidString, "remote_id": $0.target.remoteID, "reason": $0.reason.rawValue]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        _ = try ExportService.write(data, baseName: "manifest", extension: "json", into: staging)
        let folder = try Self.publish(staging, in: destination, named: Self.folderName(now))
        finished = true
        return Result(folder: folder, exported: files.count, skipped: skipped, bytes: bytes)
    }

    static func folderName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Arena Suite export \(formatter.string(from: date))"
    }

    /// A new owner-only hidden folder; leftovers of a killed bulk export are removed first.
    private static func makeStaging(in destination: URL) throws -> URL {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch { throw ExportError.writeFailed("create the destination folder") }
        for name in (try? manager.contentsOfDirectory(atPath: destination.path)) ?? []
        where name.hasPrefix(stagingPrefix) && name.hasSuffix(stagingSuffix) {
            try? manager.removeItem(at: destination.appendingPathComponent(name))
        }
        let staging = destination.appendingPathComponent(stagingPrefix + UUID().uuidString + stagingSuffix)
        guard mkdir(staging.path, 0o700) == 0 else { throw ExportError.writeFailed("create the export folder (errno \(errno))") }
        return staging
    }

    /// Renames the finished folder to `name` (or `name 2`, …) without replacing anything.
    private static func publish(_ staging: URL, in destination: URL, named name: String) throws -> URL {
        for attempt in 1...1_000 {
            let target = destination.appendingPathComponent(attempt == 1 ? name : "\(name) \(attempt)")
            if renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                let fd = open(destination.path, O_RDONLY)
                if fd >= 0 {
                    _ = fsync(fd)
                    close(fd)
                }
                return target
            }
            guard errno == EEXIST else { throw ExportError.writeFailed("rename the export folder (errno \(errno))") }
        }
        throw ExportError.writeFailed("no free folder name")
    }
}
