import Foundation
import Darwin

/// Metadata of the opened file, not a separately resolved pathname.
struct SourceStamp: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    init(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw USBError(message: "The source is not an accessible regular file.")
        }
        device = info.st_dev; inode = info.st_ino; size = UInt64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanos = Int64(info.st_ctimespec.tv_nsec)
    }
}

final class UploadSource {
    let descriptor: Int32
    let stamp: SourceStamp
    init(_ url: URL, expected: SourceStamp? = nil) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw USBError(message: "Cannot open ‘\(url.lastPathComponent)’ for reading. Links are not followed.") }
        do {
            let stamp = try SourceStamp(descriptor: fd)
            guard expected == nil || expected == stamp else { throw USBError(message: "‘\(url.lastPathComponent)’ changed since the upload was scanned. Start a new upload with the updated source.") }
            descriptor = fd; self.stamp = stamp
        } catch { close(fd); throw error }
    }
    func checkUnchanged() throws {
        guard try SourceStamp(descriptor: descriptor) == stamp else {
            throw USBError(message: "Source changed during transfer. The remote file was not confirmed; inspect it before continuing.")
        }
    }
    deinit { close(descriptor) }
}

final class TransferTimings {
    private let started = DispatchTime.now().uptimeNanoseconds
    private var durations: [String: Double] = [:]
    func measure<T>(_ phase: String, _ operation: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { durations[phase, default: 0] += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000 }
        return try operation()
    }
    var summary: String {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let phases = durations.keys.sorted().map { "\($0): \(String(format: "%.2f", durations[$0]!))s" }
        return (["Elapsed: \(String(format: "%.2f", elapsed))s"] + phases).joined(separator: " • ")
    }
}

struct BatchProgress {
    private(set) var total: Double = 1
    private(set) var completed: Double = 0
    private var current: Double = 0
    static func weight(size: UInt64) -> Double { max(1, Double(size)) }
    mutating func configure(sizes: [UInt64], completedSizes: [UInt64] = []) {
        total = max(1, sizes.reduce(0) { $0 + Self.weight(size: $1) })
        completed = completedSizes.reduce(0) { $0 + Self.weight(size: $1) }; current = 0
    }
    mutating func begin(size: UInt64) { current = Self.weight(size: size) }
    mutating func finish(size: UInt64) { completed += Self.weight(size: size); current = 0 }
    func fraction(sent: UInt64 = 0, expected: UInt64 = 0) -> Double {
        // Leave the final fraction for verification and successful completion.
        let part = expected == 0 ? 0 : min(0.99, Double(sent) / Double(expected))
        return min(1, (completed + current * part) / total)
    }
}

struct RemoteObject {
    let entry: Entry
    let parent: UInt32
    let storage: UInt32
    func check(name: String, size: UInt64, folder: Bool, parent: UInt32, storage: UInt32) throws {
        guard entry.id != 0, entry.name == name, entry.folder == folder,
              folder || entry.size == size, self.parent == parent, self.storage == storage else {
            throw USBError(message: "Transferred object does not match its expected size, name, type, or destination. Inspect it before continuing.")
        }
    }
}

enum BatchPreflight {
    static func bytes(_ sizes: [UInt64]) throws -> UInt64 {
        try sizes.reduce(0) { total, size in
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { throw USBError(message: "The batch is too large to count safely.") }
            return sum.partialValue
        }
    }
    static func space(required: UInt64, available: UInt64?) throws {
        guard let available, required > available else { return }
        throw USBError(message: "Not enough free space for this batch. It needs \(ByteCountFormatter.string(fromByteCount: Int64(clamping: required), countStyle: .file)).")
    }
    static func downloads(_ entries: [Entry], to directory: URL, cancelled: () -> Bool) throws {
        let fm = FileManager.default
        let existing = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .enumerated().map { Entry(id: UInt32(clamping: $0.offset), name: $0.element.lastPathComponent, size: 0, folder: false) }
        var names = FilenameIndex(entries: existing)
        for entry in entries {
            guard !cancelled() else { throw USBError(message: "Download cancelled before any files were saved.") }
            guard !entry.folder else { throw USBError(message: "Choose files to save.") }
            try names.check(entry.name)
            names.record(entry.name)
        }
        let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        try space(required: bytes(entries.map(\.size)), available: available.flatMap { $0 >= 0 ? UInt64($0) : nil })
        // Exercise atomic publication before downloading anything; catches read-only
        // destinations and filesystems without hard links using disposable local files.
        let probe = directory.appendingPathComponent(".kindle-preflight-" + UUID().uuidString)
        try fm.createDirectory(at: probe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: probe) }
        let source = probe.appendingPathComponent("source"), destination = probe.appendingPathComponent("link")
        try Data().write(to: source)
        guard link(source.path, destination.path) == 0 else {
            throw USBError(message: "This destination cannot safely publish downloads. Choose a writable APFS or HFS+ folder.")
        }
    }
}

/// One upload checkpoint. Only confirmed objects may be skipped on Continue.
struct UploadJournal: Codable {
    let version: Int
    let batchID: UUID
    let deviceIdentity: String
    let storageID: UInt32
    let storageName: String
    let destination: [Location]
    let plan: UploadPlan
    var completed: [Int: Entry] = [:]
    var inFlight: Int? = nil

    init(deviceIdentity: String, storage: Storage, destination: [Location], plan: UploadPlan) {
        version = 1; batchID = UUID(); self.deviceIdentity = deviceIdentity; storageID = storage.id
        storageName = storage.name; self.destination = destination; self.plan = plan
    }
    func checkTarget(identity: String, storage: Storage) throws {
        guard version == 1, identity == deviceIdentity, storage.id == storageID, storage.name == storageName else {
            throw USBError(message: "The unfinished upload belongs to a different Kindle or storage. Connect the original Kindle, or forget the checkpoint to start a new upload.")
        }
    }
    func validate() throws {
        guard version == 1, !plan.items.isEmpty else { throw USBError(message: "Unsupported or empty upload checkpoint.") }
        for (index, item) in plan.items.enumerated() {
            guard item.url.isFileURL, FileRules.validName(item.url.lastPathComponent),
                  item.folder || item.stamp != nil else { throw USBError(message: "Invalid upload checkpoint item.") }
            if let parent = item.parentIndex {
                guard parent >= 0, parent < index, plan.items[parent].folder,
                      item.url.deletingLastPathComponent().standardizedFileURL == plan.items[parent].url.standardizedFileURL else {
                    throw USBError(message: "Invalid upload checkpoint folder mapping.")
                }
            }
            if let entry = completed[index] {
                guard entry.id != 0, entry.name == item.url.lastPathComponent, entry.folder == item.folder,
                      item.folder || entry.size == item.stamp?.size,
                      item.parentIndex == nil || completed[item.parentIndex!] != nil else {
                    throw USBError(message: "Invalid completed upload checkpoint.")
                }
            }
        }
        guard completed.keys.allSatisfy({ plan.items.indices.contains($0) }),
              inFlight == nil || (plan.items.indices.contains(inFlight!) && completed[inFlight!] == nil),
              destination.allSatisfy({ $0.id != 0 && FileRules.validName($0.name) }) else {
            throw USBError(message: "Invalid upload checkpoint state.")
        }
    }

    /// Reads each existing destination once. Rejects unknown/partial names before writes.
    func prepare(parent: UInt32, list: (UInt32) throws -> [Entry], cancelled: () -> Bool) throws -> UploadDirectoryCache {
        try validate()
        let cache = UploadDirectoryCache(parent: parent, entries: try list(parent))
        var folders: [Int: UInt32] = [:]
        for (index, item) in plan.items.enumerated() {
            guard !cancelled() else { throw USBError(message: "Continue cancelled before any files were sent.") }
            let target: UInt32
            if let ancestor = item.parentIndex {
                guard let id = folders[ancestor] else { continue } // A new, not-yet-created folder.
                target = id
            } else { target = parent }
            if let entry = completed[index] {
                guard cache.entries(parent: target)?.contains(where: {
                    $0.id == entry.id && $0.name == entry.name && $0.folder == entry.folder && (entry.folder || $0.size == entry.size)
                }) == true else {
                    throw USBError(message: "‘\(item.relativePath)’ no longer matches the confirmed object. Continue stopped without overwriting it.")
                }
                if item.folder {
                    folders[index] = entry.id
                    cache.seed(parent: entry.id, entries: try list(entry.id))
                }
            } else {
                do { try cache.check(item.url.lastPathComponent, parent: target) }
                catch { throw USBError(message: "‘\(item.relativePath)’ exists but was not confirmed by this upload. Inspect or remove that partial item explicitly, then Continue.\n\n\(error.localizedDescription)") }
            }
        }
        return cache
    }
}

// Checkpoint mutations are owned by BrowserModel’s serial USB queue.
// The immutable URL / file-existence check may also be read during initialization.
final class UploadJournalStore: @unchecked Sendable {
    private enum Event: Codable {
        case begin(Int)
        case complete(Int, Entry)
    }
    let url: URL
    private var eventsURL: URL { url.appendingPathExtension("events") }
    // Keep only transition markers; retaining the completed dictionary here would
    // force a growing copy on every confirmation through Swift copy-on-write.
    private struct SavedState {
        let batchID: UUID
        let completedCount: Int
        let inFlight: Int?
        init(_ journal: UploadJournal) {
            batchID = journal.batchID; completedCount = journal.completed.count; inFlight = journal.inFlight
        }
    }
    private var saved: SavedState?
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kindle USB/unfinished-upload.json")
    }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    func load() throws -> UploadJournal {
        var journal = try JSONDecoder().decode(UploadJournal.self, from: Data(contentsOf: url))
        try journal.validate()
        if FileManager.default.fileExists(atPath: eventsURL.path) {
            let data = try Data(contentsOf: eventsURL)
            // A crash may interrupt the last append. Only newline-terminated records
            // count; their predecessors remain valid. Trim that tail before continuing.
            let end = data.lastIndex(of: 10).map { data.index(after: $0) } ?? data.startIndex
            for line in data[..<end].split(separator: 10) {
                let event = try JSONDecoder().decode(Event.self, from: Data(line))
                switch event {
                case .begin(let index):
                    guard journal.plan.items.indices.contains(index), journal.completed[index] == nil else {
                        throw USBError(message: "Invalid upload checkpoint event.")
                    }
                    journal.inFlight = index
                case .complete(let index, let entry):
                    guard journal.inFlight == index, journal.completed[index] == nil else {
                        throw USBError(message: "Invalid upload confirmation event.")
                    }
                    journal.completed[index] = entry; journal.inFlight = nil
                }
            }
            try journal.validate()
            if end < data.endIndex {
                let fd = open(eventsURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw USBError(message: "Could not repair the interrupted local checkpoint append.") }
                defer { close(fd) }
                guard ftruncate(fd, off_t(end)) == 0, fsync(fd) == 0 else { throw USBError(message: "Could not repair the local checkpoint.") }
            }
        }
        saved = SavedState(journal); return journal
    }
    func save(_ journal: UploadJournal) throws {
        let fm = FileManager.default
        if !exists {
            try journal.validate()
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: eventsURL.path) { try fm.removeItem(at: eventsURL) }
            try JSONEncoder().encode(journal).write(to: url, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Persist the manifest before any device writes.
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw USBError(message: "Could not open the local upload checkpoint.") }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw USBError(message: "Could not persist the local upload checkpoint.") }
            saved = SavedState(journal); return
        }
        if saved == nil { _ = try load() }
        guard let previous = saved, journal.batchID == previous.batchID else {
            throw USBError(message: "An unfinished upload already has a checkpoint.")
        }
        let event: Event
        if journal.completed.count == previous.completedCount {
            if journal.inFlight == previous.inFlight { return }
            guard let index = journal.inFlight, journal.plan.items.indices.contains(index), journal.completed[index] == nil else {
                throw USBError(message: "Invalid upload checkpoint transition.")
            }
            event = .begin(index)
        } else {
            guard journal.completed.count == previous.completedCount + 1, journal.inFlight == nil,
                  let index = previous.inFlight, let entry = journal.completed[index] else {
                throw USBError(message: "Invalid upload confirmation transition.")
            }
            let item = journal.plan.items[index]
            guard entry.id != 0, entry.name == item.url.lastPathComponent, entry.folder == item.folder,
                  item.folder || entry.size == item.stamp?.size,
                  item.parentIndex == nil || journal.completed[item.parentIndex!] != nil else {
                throw USBError(message: "Invalid confirmed upload object.")
            }
            event = .complete(index, entry)
        }
        // Constant-size records avoid serializing the whole manifest for every file.
        var data = try JSONEncoder().encode(event); data.append(10)
        let fd = open(eventsURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw USBError(message: "Could not write the local upload checkpoint.") }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw USBError(message: "Could not append the local upload checkpoint.") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw USBError(message: "Could not persist the local upload confirmation.") }
        saved = SavedState(journal)
    }
    func clear() throws {
        // Remove the manifest first: an interrupted cleanup must not resurrect an
        // empty manifest after deleting its completed-object records.
        if exists { try FileManager.default.removeItem(at: url) }
        saved = nil
        if FileManager.default.fileExists(atPath: eventsURL.path) { try FileManager.default.removeItem(at: eventsURL) }
    }
}
