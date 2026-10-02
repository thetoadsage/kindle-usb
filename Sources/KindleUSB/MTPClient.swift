import Foundation
import CMTP
import CryptoKit
import Darwin

// Mutable progress/timings belong to the USB queue; only atomic cancellation crosses queues.
final class TransferContext: @unchecked Sendable {
    let cancellation = k_cancel_new()!
    let update: (Double) -> Void
    let timings = TransferTimings()
    private var last: UInt64 = 0
    private var batch = BatchProgress()
    init(update: @escaping (Double) -> Void) { self.update = update }
    func configure(sizes: [UInt64], completedSizes: [UInt64] = []) {
        batch.configure(sizes: sizes, completedSizes: completedSizes); update(batch.fraction())
    }
    func begin(size: UInt64) { batch.begin(size: size); update(batch.fraction()) }
    func complete(size: UInt64) { batch.finish(size: size); update(batch.fraction()) }
    func progress(_ sent: UInt64, _ total: UInt64) -> Int32 {
        if k_cancelled(cancellation) != 0 { return 1 }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - last >= 100_000_000 { last = now; update(batch.fraction(sent: sent, expected: total)) }
        return 0
    }
    func cancel() { k_cancel_set(cancellation) }
    var cancelled: Bool { k_cancelled(cancellation) != 0 }
    func checkCancellation() throws {
        guard !cancelled else { throw USBError(message: "Transfer cancelled. Completed items were kept.") }
    }
    deinit { k_cancel_free(cancellation) }
}
private let progressCallback: LIBMTP_progressfunc_t = { sent, total, pointer in
    guard let pointer else { return 0 }
    return Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue().progress(sent, total)
}

// Owned exclusively by BrowserModel's serial USB queue, including connection release.
final class MTPClient: @unchecked Sendable {
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private(set) var identity: String = ""
    var connected: Bool { device != nil }
    func close() { if let device { LIBMTP_Release_Device(device) }; device = nil; identity = "" }
    func connect() throws -> [Storage] {
        if device == nil {
            device = k_open_kindle()
            if let device, let serial = LIBMTP_Get_Serialnumber(device) {
                defer { free(serial) }
                let value = String(cString: serial)
                if !value.isEmpty { identity = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
            }
            // Without a stable identity, continuation must not cross a connection.
            if identity.isEmpty { identity = "session-" + UUID().uuidString }
        }
        guard device != nil else { throw USBError(message: "Connect and unlock your Kindle. Close Send to Kindle, Calibre, and other MTP apps, then retry.") }
        return try storages()
    }
    private func start() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let device else { throw USBError(message: "Kindle disconnected.") }
        LIBMTP_Clear_Errorstack(device)
        return device
    }
    private func check(_ failed: Bool) throws {
        guard let device else { throw USBError(message: "Kindle disconnected.") }
        if failed || LIBMTP_Get_Errorstack(device) != nil {
            var messages: [String] = []
            var error = LIBMTP_Get_Errorstack(device)
            while let e = error { if let text = e.pointee.error_text { messages.append(String(cString: text)) }; error = e.pointee.next }
            // Conservatively discard the session on any protocol error. Never retry a write.
            close()
            throw USBError(message: messages.isEmpty ? "USB operation failed. Reconnect your Kindle and refresh. An interrupted upload may leave a partial file." : messages.joined(separator: "\n") + "\nReconnect and refresh before retrying. An interrupted upload may leave a partial file.")
        }
    }
    func storages() throws -> [Storage] {
        let d = try start()
        try check(LIBMTP_Get_Storage(d, 0) != 0)
        var result: [Storage] = []; var current = d.pointee.storage
        while let s = current {
            result.append(Storage(id: s.pointee.id, name: s.pointee.StorageDescription.map { String(cString: $0) } ?? "Kindle", freeBytes: s.pointee.FreeSpaceInBytes == UInt64.max ? nil : s.pointee.FreeSpaceInBytes)); current = s.pointee.next
        }
        guard !result.isEmpty else { close(); throw USBError(message: "Kindle exposes no storage. Unlock it and reconnect.") }
        return result
    }
    func list(storage: UInt32, parent: UInt32) throws -> [Entry] {
        let d = try start()
        var children: UnsafeMutablePointer<UInt32>?
        let count = LIBMTP_Get_Children(d, storage, parent == 0 ? UInt32.max : parent, &children)
        defer { if let children { free(children) } }
        try check(count < 0)
        guard count > 0 else { return [] }
        guard let children else { close(); throw USBError(message: "The Kindle returned an incomplete folder listing. Reconnect and refresh.") }
        var result: [Entry] = []
        // libmtp's convenience listing silently skips objects whose metadata cannot
        // be read. A collision check / recovery check must never trust that subset.
        for index in 0..<Int(count) {
            let remote = try metadata(children[index])
            guard remote.entry.id == children[index], !remote.entry.name.isEmpty,
                  remote.parent == parent, remote.storage == storage else {
                close(); throw USBError(message: "The folder listing changed or could not be verified. Reconnect and refresh before transferring files.")
            }
            result.append(remote.entry)
        }
        return result.sorted { $0.folder != $1.folder ? $0.folder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func metadata(_ id: UInt32) throws -> RemoteObject {
        let d = try start()
        guard let f = LIBMTP_Get_Filemetadata(d, id) else { try check(true); throw USBError(message: "Could not verify uploaded object.") }
        defer { LIBMTP_destroy_file_t(f) }
        try check(false)
        let entry = Entry(id: f.pointee.item_id, name: f.pointee.filename.map { String(cString: $0) } ?? "", size: f.pointee.filesize, folder: f.pointee.filetype == LIBMTP_FILETYPE_FOLDER)
        return RemoteObject(entry: entry, parent: f.pointee.parent_id == UInt32.max ? 0 : f.pointee.parent_id, storage: f.pointee.storage_id)
    }
    @discardableResult
    func upload(_ url: URL, storage: UInt32, parent: UInt32, context: TransferContext, batch: UploadDirectoryCache? = nil, expected: SourceStamp? = nil) throws -> Entry {
        try context.checkCancellation()
        let source = try UploadSource(url, expected: expected)
        if let batch { try batch.check(url.lastPathComponent, parent: parent) }
        else { try FileRules.checkName(url.lastPathComponent, entries: context.timings.measure("Directory") { try list(storage: storage, parent: parent) }) }
        let d = try start(); let file = LIBMTP_new_file_t()!
        defer { LIBMTP_destroy_file_t(file) }
        file.pointee.filename = strdup(url.lastPathComponent)
        file.pointee.filesize = source.stamp.size
        file.pointee.parent_id = parent; file.pointee.storage_id = storage
        file.pointee.filetype = url.pathExtension.lowercased() == "txt" ? LIBMTP_FILETYPE_TEXT : LIBMTP_FILETYPE_UNKNOWN
        try context.checkCancellation()
        let code = context.timings.measure("Send") {
            LIBMTP_Send_File_From_File_Descriptor(d, source.descriptor, file, progressCallback, Unmanaged.passUnretained(context).toOpaque())
        }
        try check(code != 0)
        let entry = try context.timings.measure("Verify") {
            try source.checkUnchanged()
            _ = try UploadSource(url, expected: source.stamp)
            let remote = try metadata(file.pointee.item_id)
            try remote.check(name: url.lastPathComponent, size: source.stamp.size, folder: false, parent: parent, storage: storage)
            return remote.entry
        }
        // A successful, verified final file remains confirmed even if Cancel arrived
        // after SendObject completed. Cancellation stops the next item.
        batch?.record(url.lastPathComponent, parent: parent)
        return entry
    }
    func download(_ entry: Entry, to directory: URL, context: TransferContext) throws {
        guard !entry.folder, FileRules.validName(entry.name) else { throw USBError(message: "This item cannot be saved as a local file.") }
        let fm = FileManager.default; let destination = directory.appendingPathComponent(entry.name)
        guard !fm.fileExists(atPath: destination.path) else { throw USBError(message: "‘\(entry.name)’ already exists on your Mac. Choose another folder.") }
        // A private directory avoids predictable temporary paths and symlink races.
        let scratch = directory.appendingPathComponent(".kindle-transfer-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent("payload")
        let d = try start()
        try context.checkCancellation()
        let code = context.timings.measure("Receive") {
            LIBMTP_Get_File_To_File(d, entry.id, temporary.path, progressCallback, Unmanaged.passUnretained(context).toOpaque())
        }
        try check(code != 0)
        guard !context.cancelled else { throw USBError(message: "Transfer cancelled.") }
        try context.timings.measure("Verify") {
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard UInt64(size ?? 0) == entry.size else { throw USBError(message: "Downloaded size does not match. The incomplete file was removed.") }
        }
        // link is an atomic no-overwrite publish on this same filesystem.
        guard link(temporary.path, destination.path) == 0 else { throw USBError(message: "Could not save ‘\(entry.name)’ (it may already exist). No existing file was replaced.") }
    }
    func delete(_ entry: Entry, storage: UInt32) throws {
        do {
            try RecursiveDelete.execute(entry, list: { try self.list(storage: storage, parent: $0) }, remove: { item in
                // Do not let a device-side addition be implicitly deleted with its parent.
                if item.folder, try !self.list(storage: storage, parent: item.id).isEmpty {
                    throw USBError(message: "‘\(item.name)’ is no longer empty. Refresh before retrying.")
                }
                let d = try self.start()
                try self.check(LIBMTP_Delete_Object(d, item.id) != 0)
            })
        } catch {
            throw USBError(message: "Deletion stopped. Some items may already have been permanently deleted. Refresh to see what remains.\n" + error.localizedDescription)
        }
    }
    func rename(_ entry: Entry, to name: String, storage: UInt32, parent: UInt32) throws {
        try FileRules.checkName(name, entries: list(storage: storage, parent: parent), excluding: entry.id)
        let d = try start()
        guard let f = LIBMTP_Get_Filemetadata(d, entry.id) else { try check(true); return }
        defer { LIBMTP_destroy_file_t(f) }
        try check(LIBMTP_Set_File_Name(d, f, name) != 0)
    }
    @discardableResult
    func mkdir(_ name: String, storage: UInt32, parent: UInt32, batch: UploadDirectoryCache? = nil) throws -> UInt32 {
        if let batch { try batch.check(name, parent: parent) }
        else { try FileRules.checkName(name, entries: list(storage: storage, parent: parent)) }
        let d = try start(); let copy = strdup(name); defer { free(copy) }
        let id = LIBMTP_Create_Folder(d, copy, parent, storage)
        try check(id == 0)
        let remote = try metadata(id)
        try remote.check(name: name, size: 0, folder: true, parent: parent, storage: storage)
        guard remote.entry.id == id else { throw USBError(message: "Created folder ID does not match. Inspect it before continuing.") }
        batch?.record(name, parent: parent, folderID: id)
        return id
    }
}
