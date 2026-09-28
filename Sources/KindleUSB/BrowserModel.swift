import SwiftUI
import AppKit

@MainActor final class BrowserModel: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var storages: [Storage] = []
    @Published var storageID: UInt32 = 0
    @Published var path: [Location] = []
    @Published var selection = Set<UInt32>()
    @Published var busy = false
    @Published var connected = false
    @Published var status = "Connect your Kindle via USB"
    @Published var error: String?
    @Published var progress: Double?
    private let queue = DispatchQueue(label: "KindleUSB.MTP", qos: .userInitiated)
    private let client = MTPClient()
    private var timer: Timer?
    private var context: TransferContext?
    private var paused = false
    var parent: UInt32 { path.last?.id ?? 0 }
    var selected: [Entry] { entries.filter { selection.contains($0.id) } }
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        reconnect()
    }
    private func run(_ label: String, work: @escaping (MTPClient) throws -> (() -> Void)) {
        guard !busy else { return }
        busy = true; status = label
        let client = self.client
        queue.async { [self] in
            do {
                let completion = try work(client)
                let live = client.connected
                DispatchQueue.main.async { self.connected = live; self.busy = false; self.progress = nil; self.context = nil; completion() }
            } catch {
                let live = client.connected
                DispatchQueue.main.async {
                    self.busy = false; self.progress = nil; self.context = nil; self.connected = live
                    if !live { self.entries = []; self.selection = []; self.path = []; self.storages = []; self.paused = true }
                    self.status = live ? "Operation stopped" : "Connection lost — reconnect to retry"
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func reconnect() {
        paused = false
        run("Looking for Kindle…") { client in
            // Absence is a normal state: allow polling without an alert every four seconds.
            guard let stores = try? client.connect() else {
                client.close()
                return { self.connected = false; self.status = "Connect and unlock Kindle; close other MTP apps" }
            }
            let store = stores[0]
            let root = try client.list(storage: store.id, parent: 0)
            let documents = root.first { $0.folder && $0.name.lowercased() == "documents" }
            let files = try documents.map { try client.list(storage: store.id, parent: $0.id) } ?? root
            return {
                self.storages = stores; self.storageID = store.id
                self.path = documents.map { [Location(id: $0.id, name: $0.name)] } ?? []
                self.entries = files; self.selection = []; self.status = "Connected • Files transfer unchanged"
            }
        }
    }
    private func poll() {
        guard !busy, !paused else { return }
        if !connected { reconnect(); return }
        // A serialized storage request detects idle disconnects without concurrent USB access.
        run("Checking connection…") { client in
            _ = try client.storages()
            return { self.status = "Connected • \(self.entries.count) items" }
        }
    }
    func navigate(_ newPath: [Location], storage: UInt32? = nil) {
        let sid = storage ?? storageID
        run("Loading folder…") { client in
            let files = try client.list(storage: sid, parent: newPath.last?.id ?? 0)
            return { self.storageID = sid; self.path = newPath; self.entries = files; self.selection = []; self.status = "\(files.count) items" }
        }
    }
    func open(_ entry: Entry) { if entry.folder { navigate(path + [Location(id: entry.id, name: entry.name)]) } }
    func refresh() { if connected { navigate(path) } else { reconnect() } }
    func disconnect() {
        paused = true
        run("Disconnecting…") { client in
            client.close()
            return { self.entries = []; self.storages = []; self.selection = []; self.path = []; self.status = "Disconnected — safe to unplug" }
        }
    }
    func shutdown(_ completion: @escaping () -> Void) {
        timer?.invalidate()
        let client = self.client
        queue.async { client.close(); DispatchQueue.main.async(execute: completion) }
    }
    func cancel() { context?.cancel(); status = "Cancelling — waiting for USB operation to return…" }
    func chooseUpload() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.resolvesAliases = false
        if panel.runModal() == .OK { upload(panel.urls) }
    }
    func upload(_ urls: [URL]) {
        guard connected, !busy, !urls.isEmpty else { return }
        let sid = storageID, pid = parent
        let ctx = TransferContext { value in DispatchQueue.main.async { self.progress = value } }
        context = ctx; progress = 0
        run("Scanning files and folders…") { client in
            let plan = try UploadPlan.scan(urls, cancelled: { ctx.cancelled })
            let existing = try client.list(storage: sid, parent: pid)
            // Refuse collisions before creating any root; existing folders are never merged.
            for item in plan.items where item.parentIndex == nil {
                try FileRules.checkName(item.url.lastPathComponent, entries: existing)
            }
            do {
                try plan.execute(parent: pid, cancelled: { ctx.cancelled }, progress: { index, item in
                    DispatchQueue.main.async {
                        self.status = "Sending \(index + 1)/\(plan.items.count): \(item.relativePath)"
                        self.progress = 0
                    }
                }, createFolder: { name, parent in
                    try client.mkdir(name, storage: sid, parent: parent)
                }, sendFile: { url, parent in
                    try client.upload(url, storage: sid, parent: parent, context: ctx)
                })
            } catch {
                if client.connected, let current = try? client.list(storage: sid, parent: pid) {
                    DispatchQueue.main.async { self.entries = current; self.selection = [] }
                }
                throw error
            }
            let files = try client.list(storage: sid, parent: pid)
            return {
                self.entries = files; self.selection = []
                self.status = "Sent \(plan.fileCount) file(s) and \(plan.folderCount) folder(s)"
            }
        }
    }
    func save() {
        let files = selected.filter { !$0.folder }; guard !files.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        transfer(label: "Saving", names: files.map(\.name)) { client, index, ctx, _, _ in try client.download(files[index], to: directory, context: ctx) }
    }
    private func transfer(label: String, names: [String], operation: @escaping (MTPClient, Int, TransferContext, UInt32, UInt32) throws -> Void) {
        guard !busy else { return }
        let sid = storageID, pid = parent
        let ctx = TransferContext { value in DispatchQueue.main.async { self.progress = value } }
        context = ctx; progress = 0
        run("\(label)…") { client in
            for index in names.indices {
                guard !ctx.cancelled else { throw USBError(message: "Transfer cancelled. Completed files were kept; remaining files were not transferred.") }
                DispatchQueue.main.async { self.status = "\(label) \(index + 1)/\(names.count): \(names[index])"; self.progress = 0 }
                do { try operation(client, index, ctx, sid, pid) }
                catch { throw USBError(message: "Stopped at \(names[index]) (\(index + 1)/\(names.count)). Earlier completed files were kept.\n\n\(error.localizedDescription)") }
            }
            let files = try client.list(storage: sid, parent: pid)
            return { self.entries = files; self.selection = []; self.status = "Transferred \(names.count) file(s)" }
        }
    }
    func createFolder(_ name: String) { mutate("Creating folder…") { c, s, p in try c.mkdir(name, storage: s, parent: p) } }
    func rename(_ entry: Entry, name: String) { mutate("Renaming…") { c, s, p in try c.rename(entry, to: name, storage: s, parent: p) } }
    func deleteSelected() {
        let items = selected
        mutate("Deleting…") { c, s, _ in for item in items { try c.delete(item, storage: s) } }
    }
    private func mutate(_ label: String, work: @escaping (MTPClient, UInt32, UInt32) throws -> Void) {
        let sid = storageID, pid = parent
        run(label) { client in
            try work(client, sid, pid)
            let files = try client.list(storage: sid, parent: pid)
            return { self.entries = files; self.selection = []; self.status = "\(files.count) items" }
        }
    }
}
