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
    @Published var hasUnfinishedUpload = false
    @Published var transferDetails: String?
    private let journalStore = UploadJournalStore()
    private let queue = DispatchQueue(label: "KindleUSB.MTP", qos: .userInitiated)
    private let client = MTPClient()
    private var timer: Timer?
    private var context: TransferContext?
    private var paused = false
    private var reconnectGate = ReconnectGate()
    private var connectedAttachments: Set<UInt64>?
    var parent: UInt32 { path.last?.id ?? 0 }
    var selected: [Entry] { entries.filter { selection.contains($0.id) } }
    init() {
        hasUnfinishedUpload = journalStore.exists
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        reconnect()
    }
    private func setConnection(_ live: Bool, pauseWhenDisconnected: Bool = true) {
        let wasConnected = connected
        if live && !wasConnected { connectedAttachments = USBPresence.kindleAttachments() }
        connected = live
        if !live {
            entries = []; selection = []; path = []; storages = []; paused = pauseWhenDisconnected
            if paused {
                // Keep the old identity on cable loss, so a quick replug that
                // happens during protocol cleanup is still recognized as new.
                reconnectGate.pause(attached: wasConnected ? connectedAttachments : USBPresence.kindleAttachments())
            }
            connectedAttachments = nil
        }
    }
    private func run(_ label: String, transfer: Bool = false, quiet: Bool = false,
                     work: @escaping (MTPClient) throws -> (() -> Void)) {
        guard !busy else { return }
        busy = true
        if !quiet { status = label }
        if transfer { transferDetails = nil }
        let client = self.client, store = journalStore, ctx = context
        queue.async { [self] in
            let activity = transfer ? ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Kindle USB file transfer") : nil
            defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
            do {
                let completion = try work(client)
                let live = client.connected, unfinished = store.exists
                let details = transfer ? ctx?.timings.summary : nil
                DispatchQueue.main.async {
                    self.setConnection(live, pauseWhenDisconnected: self.connected || self.paused); self.busy = false; self.progress = nil; self.context = nil
                    self.hasUnfinishedUpload = unfinished
                    if let details { self.transferDetails = details }
                    completion()
                }
            } catch {
                let live = client.connected, unfinished = store.exists
                let details = transfer ? ctx?.timings.summary : nil
                DispatchQueue.main.async {
                    self.busy = false; self.progress = nil; self.context = nil; self.setConnection(live)
                    self.hasUnfinishedUpload = unfinished
                    if let details { self.transferDetails = details }
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
        guard !busy else { return }
        if paused {
            guard reconnectGate.shouldResume(attached: USBPresence.kindleAttachments()) else { return }
            paused = false
        }
        if !connected { reconnect(); return }
        // A serialized storage request detects idle disconnects without concurrent USB access.
        run("Checking connection…", quiet: true) { client in
            _ = try client.storages()
            return {}
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
        guard !busy, connected else { return }
        paused = true
        run("Disconnecting…") { client in
            client.close()
            return {
                // Intentional reset can re-enumerate USB. Suppress that resulting
                // attachment too; only a later plug-in should reopen it.
                self.reconnectGate.pause(attached: USBPresence.kindleAttachments())
                self.entries = []; self.storages = []; self.selection = []; self.path = []
                self.status = "Disconnected — safe to unplug"
            }
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
        guard !hasUnfinishedUpload else { error = "Continue or forget the unfinished upload before starting another batch."; return }
        startUpload(urls: urls, continuing: false)
    }
    func continueUpload() {
        guard connected, !busy, hasUnfinishedUpload else { return }
        startUpload(urls: [], continuing: true)
    }
    func forgetUpload() {
        guard !busy else { return }
        let store = journalStore
        run("Forgetting upload checkpoint…") { _ in
            try store.clear()
            return { self.status = "Upload checkpoint forgotten" }
        }
    }
    private func startUpload(urls: [URL], continuing: Bool) {
        let sid = storageID, destination = path, store = journalStore
        let ctx = TransferContext { value in DispatchQueue.main.async { self.progress = value } }
        context = ctx; progress = 0
        run(continuing ? "Checking unfinished upload…" : "Scanning files and folders…", transfer: true) { client in
            var journal: UploadJournal
            let cache: UploadDirectoryCache
            let pid: UInt32
            let storage: Storage
            if continuing {
                do { journal = try ctx.timings.measure("Checkpoint") { try store.load() } }
                catch { throw USBError(message: "The local upload checkpoint could not be read. Forget it to start a new upload; existing Kindle files will stay in place.\n\n\(error.localizedDescription)") }
                guard !journal.deviceIdentity.hasPrefix("session-") else {
                    throw USBError(message: "This Kindle did not provide a stable device identity, so the upload cannot safely continue after reconnecting. Forget the checkpoint and inspect the existing Kindle files before starting again.")
                }
                // Discard metadata cached before interruption. Continue is the explicit
                // user action allowing a new connection; no writes are retried here.
                client.close()
                let stores = try ctx.timings.measure("Connect") { try client.connect() }
                guard let target = stores.first(where: { $0.id == journal.storageID }) else { throw USBError(message: "The original upload storage is unavailable.") }
                storage = target
                do { try journal.checkTarget(identity: client.identity, storage: storage) }
                catch { client.close(); throw error }
                var current: UInt32 = 0
                for folder in journal.destination {
                    try ctx.checkCancellation()
                    let entries = try ctx.timings.measure("Directory") { try client.list(storage: storage.id, parent: current) }
                    guard entries.contains(where: { $0.id == folder.id && $0.folder && $0.name == folder.name }) else {
                        throw USBError(message: "The original destination folder changed. Continue stopped without writing anything.")
                    }
                    current = folder.id
                }
                pid = current
                try ctx.timings.measure("Sources") { try journal.plan.checkSources(cancelled: { ctx.cancelled }) }
                cache = try journal.prepare(parent: pid, list: { parent in
                    try ctx.timings.measure("Directory") { try client.list(storage: storage.id, parent: parent) }
                }, cancelled: { ctx.cancelled })
            } else {
                let plan = try ctx.timings.measure("Scan") { try UploadPlan.scan(urls, cancelled: { ctx.cancelled }) }
                try ctx.checkCancellation()
                let stores = try ctx.timings.measure("Space") { try client.storages() }
                guard let target = stores.first(where: { $0.id == sid }) else { throw USBError(message: "Upload storage is unavailable.") }
                storage = target; pid = destination.last?.id ?? 0
                let existing = try ctx.timings.measure("Directory") { try client.list(storage: sid, parent: pid) }
                cache = UploadDirectoryCache(parent: pid, entries: existing)
                for item in plan.items where item.parentIndex == nil {
                    try cache.check(item.url.lastPathComponent, parent: pid)
                }
                journal = UploadJournal(deviceIdentity: client.identity, storage: storage, destination: destination, plan: plan)
            }
            let plan = journal.plan, alreadyCompleted = journal.completed
            let remainingSizes = plan.items.enumerated().filter { alreadyCompleted[$0.offset] == nil }.map { $0.element.stamp?.size ?? 0 }
            try BatchPreflight.space(required: BatchPreflight.bytes(remainingSizes), available: storage.freeBytes)
            try ctx.checkCancellation()
            try ctx.timings.measure("Checkpoint") { try store.save(journal) }
            let sizes = plan.sizes
            ctx.configure(sizes: sizes, completedSizes: alreadyCompleted.keys.sorted().map { sizes[$0] })
            let stamps = Dictionary(plan.items.compactMap { item in item.stamp.map { (item.url, $0) } }, uniquingKeysWith: { first, _ in first })
            var lastFile: Entry?
            do {
                try plan.execute(parent: pid, cancelled: { ctx.cancelled }, progress: { index, item in
                    ctx.begin(size: item.stamp?.size ?? 0)
                    DispatchQueue.main.async { self.status = "Sending \(index + 1)/\(plan.items.count): \(item.relativePath)" }
                }, createFolder: { name, parent in
                    try ctx.checkCancellation()
                    return try ctx.timings.measure("Folders") { try client.mkdir(name, storage: storage.id, parent: parent, batch: cache) }
                }, sendFile: { url, parent in
                    lastFile = try client.upload(url, storage: storage.id, parent: parent, context: ctx, batch: cache, expected: stamps[url])
                }, completed: alreadyCompleted, beforeWrite: { index in
                    lastFile = nil; journal.inFlight = index
                    try ctx.timings.measure("Checkpoint") { try store.save(journal) }
                }, didComplete: { index, item, folderID in
                    let entry: Entry
                    if let folderID { entry = Entry(id: folderID, name: item.url.lastPathComponent, size: 0, folder: true) }
                    else {
                        guard let file = lastFile else { throw USBError(message: "Upload confirmation is missing. Inspect the remote item before continuing.") }
                        entry = file
                    }
                    journal.completed[index] = entry; journal.inFlight = nil
                    try ctx.timings.measure("Checkpoint") { try store.save(journal) }
                    ctx.complete(size: item.stamp?.size ?? 0)
                })
            } catch {
                // Best-effort read only. The checkpoint remains available; partial
                // remote objects are never deleted or accepted as completed.
                if client.connected, let current = try? ctx.timings.measure("Refresh", { try client.list(storage: storage.id, parent: pid) }) {
                    DispatchQueue.main.async { self.entries = current; self.selection = [] }
                }
                throw error
            }
            var notices: [String] = []
            do { try ctx.timings.measure("Checkpoint") { try store.clear() } }
            catch { notices.append("Files were transferred, but the local checkpoint could not be cleared. Continue can retry clearing it.") }
            var files: [Entry]?
            do { files = try ctx.timings.measure("Refresh") { try client.list(storage: storage.id, parent: pid) } }
            catch { notices.append("Files were transferred, but the folder could not be refreshed. Reconnect and Refresh; do not resend the batch.") }
            let notice = notices.isEmpty ? nil : notices.joined(separator: "\n\n")
            let finishedDestination = journal.destination
            return {
                if let files { self.storageID = storage.id; self.path = finishedDestination; self.entries = files; self.selection = [] }
                self.status = "Sent \(plan.fileCount) file(s) and \(plan.folderCount) folder(s)" + (notice == nil ? "" : " • See notice")
                self.error = notice
            }
        }
    }
    func save() {
        guard connected, !busy else { return }
        let files = selected.filter { !$0.folder }
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let directory = panel.url, !busy, connected else { return }
        let ctx = TransferContext { value in DispatchQueue.main.async { self.progress = value } }
        context = ctx; progress = 0
        run("Checking download destination…", transfer: true) { client in
            try ctx.timings.measure("Preflight") { try BatchPreflight.downloads(files, to: directory, cancelled: { ctx.cancelled }) }
            ctx.configure(sizes: files.map(\.size))
            for (index, entry) in files.enumerated() {
                try ctx.checkCancellation()
                ctx.begin(size: entry.size)
                DispatchQueue.main.async { self.status = "Saving \(index + 1)/\(files.count): \(entry.name)" }
                do { try client.download(entry, to: directory, context: ctx) }
                catch { throw USBError(message: "Stopped at \(entry.name) (\(index + 1)/\(files.count)). Earlier completed files were kept.\n\n\(error.localizedDescription)") }
                ctx.complete(size: entry.size)
            }
            // Saving to Mac does not modify the Kindle directory.
            return { self.status = "Saved \(files.count) file(s) to Mac" }
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
