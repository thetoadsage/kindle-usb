import Foundation
import CMTP

final class TransferContext {
    let cancellation = k_cancel_new()!
    let update: (Double) -> Void
    private var last = Date.distantPast
    init(update: @escaping (Double) -> Void) { self.update = update }
    func progress(_ sent: UInt64, _ total: UInt64) -> Int32 {
        if k_cancelled(cancellation) != 0 { return 1 }
        if Date().timeIntervalSince(last) > 0.1 { last = Date(); update(total == 0 ? 0 : Double(sent) / Double(total)) }
        return 0
    }
    func cancel() { k_cancel_set(cancellation) }
    var cancelled: Bool { k_cancelled(cancellation) != 0 }
    deinit { k_cancel_free(cancellation) }
}
private let progressCallback: LIBMTP_progressfunc_t = { sent, total, pointer in
    guard let pointer else { return 0 }
    return Unmanaged<TransferContext>.fromOpaque(pointer).takeUnretainedValue().progress(sent, total)
}

// Owned exclusively by BrowserModel's serial USB queue, including connection release.
final class MTPClient: @unchecked Sendable {
    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    var connected: Bool { device != nil }
    func close() { if let device { LIBMTP_Release_Device(device) }; device = nil }
    func connect() throws -> [Storage] {
        if device == nil { device = k_open_kindle() }
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
            result.append(Storage(id: s.pointee.id, name: s.pointee.StorageDescription.map { String(cString: $0) } ?? "Kindle")); current = s.pointee.next
        }
        guard !result.isEmpty else { close(); throw USBError(message: "Kindle exposes no storage. Unlock it and reconnect.") }
        return result
    }
    func list(storage: UInt32, parent: UInt32) throws -> [Entry] {
        let d = try start()
        var file = LIBMTP_Get_Files_And_Folders(d, storage, parent == 0 ? UInt32.max : parent)
        var result: [Entry] = []
        while let f = file {
            result.append(Entry(id: f.pointee.item_id, name: f.pointee.filename.map { String(cString: $0) } ?? "Unnamed", size: f.pointee.filesize, folder: f.pointee.filetype == LIBMTP_FILETYPE_FOLDER))
            file = f.pointee.next; f.pointee.next = nil; LIBMTP_destroy_file_t(f)
        }
        try check(false)
        return result.sorted { $0.folder != $1.folder ? $0.folder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func upload(_ url: URL, storage: UInt32, parent: UInt32, context: TransferContext) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw USBError(message: "The source is no longer a regular file, or is a symbolic link.") }
        try FileRules.checkName(url.lastPathComponent, entries: list(storage: storage, parent: parent))
        let d = try start(); let file = LIBMTP_new_file_t()!
        defer { LIBMTP_destroy_file_t(file) }
        file.pointee.filename = strdup(url.lastPathComponent)
        file.pointee.filesize = UInt64(values.fileSize ?? 0)
        file.pointee.parent_id = parent; file.pointee.storage_id = storage
        file.pointee.filetype = url.pathExtension.lowercased() == "txt" ? LIBMTP_FILETYPE_TEXT : LIBMTP_FILETYPE_UNKNOWN
        let code = LIBMTP_Send_File_From_File(d, url.path, file, progressCallback, Unmanaged.passUnretained(context).toOpaque())
        try check(code != 0)
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
        let code = LIBMTP_Get_File_To_File(d, entry.id, temporary.path, progressCallback, Unmanaged.passUnretained(context).toOpaque())
        try check(code != 0)
        guard !context.cancelled else { throw USBError(message: "Transfer cancelled.") }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard UInt64(size ?? 0) == entry.size else { throw USBError(message: "Downloaded size does not match. The incomplete file was removed.") }
        // link is an atomic no-overwrite publish on this same filesystem.
        guard link(temporary.path, destination.path) == 0 else { throw USBError(message: "Could not save ‘\(entry.name)’ (it may already exist). No existing file was replaced.") }
    }
    func delete(_ entry: Entry, storage: UInt32) throws {
        if entry.folder, try !list(storage: storage, parent: entry.id).isEmpty { throw USBError(message: "Only empty folders can be deleted. Remove their contents explicitly first.") }
        let d = try start(); try check(LIBMTP_Delete_Object(d, entry.id) != 0)
    }
    func rename(_ entry: Entry, to name: String, storage: UInt32, parent: UInt32) throws {
        try FileRules.checkName(name, entries: list(storage: storage, parent: parent), excluding: entry.id)
        let d = try start()
        guard let f = LIBMTP_Get_Filemetadata(d, entry.id) else { try check(true); return }
        defer { LIBMTP_destroy_file_t(f) }
        try check(LIBMTP_Set_File_Name(d, f, name) != 0)
    }
    @discardableResult
    func mkdir(_ name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        try FileRules.checkName(name, entries: list(storage: storage, parent: parent))
        let d = try start(); let copy = strdup(name); defer { free(copy) }
        let id = LIBMTP_Create_Folder(d, copy, parent, storage)
        try check(id == 0)
        return id
    }
}
