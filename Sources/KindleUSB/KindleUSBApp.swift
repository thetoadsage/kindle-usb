import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrowserModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true {
            let alert = NSAlert(); alert.messageText = "USB operation in progress"
            alert.informativeText = "Wait for completion, or cancel the transfer and wait for it to stop before quitting."
            alert.runModal()
            return .terminateCancel
        }
        guard let model else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
}
@main struct KindleUSBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = BrowserModel()
    var body: some Scene {
        WindowGroup("Kindle USB") { BrowserView(model: model).onAppear { delegate.model = model }.frame(minWidth: 760, minHeight: 480) }
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @State private var dropTarget = false
    @State private var editName = ""
    @State private var editing: Entry?
    @State private var showName = false
    @State private var showDelete = false
    @State private var showForgetUpload = false
    @State private var showTransferDetails = false
    private var folderTitle: String { model.path.last?.name ?? model.storages.first(where: { $0.id == model.storageID })?.name ?? "Kindle" }
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("LOCATIONS")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 10)
                    HStack(spacing: 9) {
                        Image(systemName: "book.closed.fill").foregroundStyle(model.connected ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kindle").fontWeight(.medium)
                            Text(model.connected ? "Connected" : "Not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(.horizontal, 18).padding(.vertical, 9)
                    if model.connected {
                        ForEach(model.storages) { storage in
                            Button { model.navigate([], storage: storage.id) } label: {
                                Label(storage.name, systemImage: "internaldrive")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 18).padding(.vertical, 7)
                                    .background(model.storageID == storage.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }
                .frame(minWidth: 180, idealWidth: 205, maxWidth: 260)
                .background(Color(nsColor: .underPageBackgroundColor))
                .disabled(model.busy)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button { model.navigate(Array(model.path.dropLast())) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.borderless)
                            .help("Back to parent folder")
                            .disabled(!model.connected || model.busy || model.path.isEmpty)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folderTitle).font(.title2.weight(.semibold)).lineLimit(1)
                            Text(model.path.isEmpty ? "On your Kindle" : model.path.map(\.name).joined(separator: " / "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if model.connected {
                            Text("\(model.entries.count) items")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                    Divider()
                    Table(model.entries, selection: $model.selection) {
                        TableColumn("Name") { entry in
                            Label(entry.name, systemImage: entry.folder ? "folder.fill" : "doc")
                                .labelStyle(.titleAndIcon)
                        }
                        TableColumn("Size") { entry in Text(entry.folder ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)).foregroundStyle(.secondary) }.width(90)
                        TableColumn("Kind") { entry in Text(entry.folder ? "Folder" : (entry.name as NSString).pathExtension.uppercased()).foregroundStyle(.secondary) }.width(65)
                    }
                    .contextMenu(forSelectionType: UInt32.self) { ids in
                        Button("Open Folder") {
                            if let entry = model.entries.first(where: { ids.contains($0.id) }) { model.open(entry) }
                        }.disabled(model.busy || ids.count != 1 || !model.entries.contains(where: { ids.contains($0.id) && $0.folder }))
                        Button("Rename…") {
                            model.selection = ids
                            editing = model.selected.first
                            editName = editing?.name ?? ""
                            showName = true
                        }.disabled(model.busy || ids.count != 1)
                        Button("Delete…", role: .destructive) {
                            model.selection = ids
                            showDelete = true
                        }.disabled(model.busy || ids.isEmpty)
                    } primaryAction: { ids in
                        guard !model.busy, ids.count == 1,
                              let entry = model.entries.first(where: { ids.contains($0.id) }) else { return }
                        model.open(entry)
                    }
                    .disabled(model.busy)
                    .overlay {
                        if model.entries.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: model.connected ? "tray.and.arrow.down" : "cable.connector").font(.system(size: 36)).foregroundStyle(.secondary)
                                Text(model.connected ? "This folder is empty" : "Connect your Kindle") .font(.headline)
                                Text(model.connected ? "Drag files or folders here, or use Add in the toolbar." : "Connect and unlock it with a USB cable.")
                                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.allowsHitTesting(false)
                        }
                    }
                    .overlay { if dropTarget { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
                        guard model.connected, !model.busy else { return false }
                        // Capture the destination and reject a late drop if navigation changed.
                        let path = model.path, storage = model.storageID
                        Task { @MainActor in
                            var urls: [URL] = []
                            for provider in providers {
                                let url: URL? = await withCheckedContinuation { continuation in
                                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                        if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                                        else { continuation.resume(returning: item as? URL) }
                                    }
                                }
                                if let url, url.isFileURL { urls.append(url) }
                            }
                            guard model.path == path, model.storageID == storage, !model.busy else { model.error = "The destination changed while reading the drop. Drop the files again."; return }
                            model.upload(urls)
                        }
                        return true
                    }
                }.frame(minWidth: 480)
            }
            Divider()
            HStack(spacing: 8) {
                Circle().fill(model.connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let progress = model.progress {
                    ProgressView(value: progress).frame(width: 140)
                    Text("\(Int(progress * 100))%") .font(.caption.monospacedDigit())
                    Button("Cancel") { model.cancel() }
                } else if model.busy { ProgressView().controlSize(.small) }
                if model.transferDetails != nil {
                    Button { showTransferDetails.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).help("Last transfer timings")
                        .popover(isPresented: $showTransferDetails) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Last transfer timings").font(.headline)
                                Text(model.transferDetails ?? "").font(.caption).textSelection(.enabled)
                            }.padding().frame(width: 340)
                        }
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .toolbar {
            if model.hasUnfinishedUpload {
                Button { model.continueUpload() } label: { Label("Continue Upload", systemImage: "play.fill") }
                    .help("Check the unfinished upload and send its remaining files")
                    .disabled(!model.connected || model.busy)
                Button { showForgetUpload = true } label: { Label("Forget Upload", systemImage: "xmark.circle") }
                    .help("Forget the local checkpoint; Kindle files stay in place")
                    .disabled(model.busy)
            }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.busy)
            Button { model.chooseUpload() } label: { Label("Add", systemImage: "plus") }.help("Add files or folders to this Kindle folder").disabled(!model.connected || model.busy || model.hasUnfinishedUpload)
            Button { model.save() } label: { Label("Save to Mac", systemImage: "square.and.arrow.down") }.disabled(model.busy || model.selected.filter { !$0.folder }.isEmpty)
            Menu {
                Button("New Folder…") { editing = nil; editName = ""; showName = true }
                Button("Rename…") { editing = model.selected.first; editName = editing?.name ?? ""; showName = true }.disabled(model.selected.count != 1)
                Button("Delete…", role: .destructive) { showDelete = true }.disabled(model.selected.isEmpty)
            } label: { Label("Manage", systemImage: "ellipsis.circle") }.disabled(!model.connected || model.busy)
            Button { model.disconnect() } label: { Label("Disconnect", systemImage: "eject") }.disabled(!model.connected || model.busy)
        }
        .alert("Forget unfinished upload?", isPresented: $showForgetUpload) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { model.forgetUpload() }
        } message: { Text("This removes the local recovery record. Files and folders already on your Kindle stay in place; inspect them before starting another upload with the same names.") }
        .alert("USB operation", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert(editing == nil ? "New Folder" : "Rename", isPresented: $showName) {
            TextField("Name", text: $editName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let editing { model.rename(editing, name: editName) } else { model.createFolder(editName) } }
        }
        .alert("Delete \(model.selected.count) item(s)?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.deleteSelected() }
        } message: { Text("This permanently deletes the selected items from your Kindle. Selected folders and everything inside them will be deleted. There is no Trash or Undo.") }
    }
}
