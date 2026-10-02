import Foundation

/// Scan before writing so invalid names, unreadable folders, and links fail early.
struct UploadPlan: Codable {
    struct Item: Codable {
        let url: URL
        let relativePath: String
        let parentIndex: Int?
        let folder: Bool
        let stamp: SourceStamp?
    }
    let items: [Item]
    var fileCount: Int { items.filter { !$0.folder }.count }
    var folderCount: Int { items.count - fileCount }

    static func scan(_ urls: [URL], cancelled: () -> Bool) throws -> UploadPlan {
        var items: [Item] = []
        func visit(_ siblings: [URL], parentIndex: Int?, prefix: String) throws {
            var names = FilenameIndex()
            for url in siblings {
                guard !cancelled() else { throw USBError(message: "Upload cancelled before any files were sent.") }
                try names.check(url.lastPathComponent)
                names.record(url.lastPathComponent)
                // Fresh metadata rather than potentially cached URL resource values.
                let source = URL(fileURLWithPath: url.path)
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey])
                let relative = prefix + url.lastPathComponent
                guard values.isSymbolicLink != true, values.isAliasFile != true else {
                    throw USBError(message: "‘\(relative)’ is a symbolic link or Finder alias. Remove it from the upload selection; links are not followed.")
                }
                guard values.isDirectory == true || values.isRegularFile == true else {
                    throw USBError(message: "‘\(relative)’ is not a regular file or folder.")
                }
                let index = items.count
                let folder = values.isDirectory == true
                let stamp = try folder ? nil : UploadSource(source).stamp
                items.append(Item(url: source, relativePath: relative, parentIndex: parentIndex, folder: folder, stamp: stamp))
                if values.isDirectory == true {
                    let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    try visit(children, parentIndex: index, prefix: relative + "/")
                }
            }
        }
        try visit(urls, parentIndex: nil, prefix: "")
        return UploadPlan(items: items)
    }

    var sizes: [UInt64] { items.map { $0.stamp?.size ?? 0 } }
    func checkSources(cancelled: () -> Bool) throws {
        for item in items {
            guard !cancelled() else { throw USBError(message: "Upload cancelled before sending remaining files.") }
            let values = try URL(fileURLWithPath: item.url.path).resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isAliasFile != true, values.isDirectory == item.folder else {
                throw USBError(message: "‘\(item.relativePath)’ changed type or became a link. Continue stopped.")
            }
            if !item.folder { _ = try UploadSource(item.url, expected: item.stamp) }
        }
    }

    /// Parent IDs come from successful MTP folder creation, never from guessed paths.
    func execute(parent: UInt32, cancelled: () -> Bool,
                 progress: (Int, Item) -> Void,
                 createFolder: (String, UInt32) throws -> UInt32,
                 sendFile: (URL, UInt32) throws -> Void,
                 completed: [Int: Entry] = [:],
                 beforeWrite: (Int) throws -> Void = { _ in },
                 didComplete: (Int, Item, UInt32?) throws -> Void = { _, _, _ in }) throws {
        var folders: [Int: UInt32] = [:]
        for (index, item) in items.enumerated() {
            guard !cancelled() else { throw USBError(message: "Upload cancelled. Completed files and folders were kept; remaining items were not transferred.") }
            let destination: UInt32
            if let parentIndex = item.parentIndex {
                guard let id = folders[parentIndex] else { throw USBError(message: "Upload folder mapping is incomplete.") }
                destination = id
            } else { destination = parent }
            if let entry = completed[index] {
                if item.folder { folders[index] = entry.id }
                continue
            }
            progress(index, item)
            do {
                // Do not follow a source folder replaced with a link after the scan.
                var ancestor: Int? = index
                while let current = ancestor {
                    let values = try URL(fileURLWithPath: items[current].url.path).resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
                    guard values.isSymbolicLink != true, values.isAliasFile != true else { throw USBError(message: "Source changed into a link. Upload stopped.") }
                    ancestor = items[current].parentIndex
                }
                try beforeWrite(index)
                guard !cancelled() else { throw USBError(message: "Upload cancelled before the next write.") }
                if item.folder { folders[index] = try createFolder(item.url.lastPathComponent, destination) }
                else { try sendFile(item.url, destination) }
                try didComplete(index, item, folders[index])
            } catch {
                throw USBError(message: "Stopped at \(item.relativePath) (\(index + 1)/\(items.count)). Completed files and folders were kept.\n\n\(error.localizedDescription)")
            }
        }
    }
}

/// Lives only for one serialized upload. Never reuse across batches or reconnects.
final class UploadDirectoryCache {
    private struct Directory {
        var entries: [Entry]
        var names: FilenameIndex
        init(_ entries: [Entry]) { self.entries = entries; names = FilenameIndex(entries: entries) }
    }
    private var directories: [UInt32: Directory]
    init(parent: UInt32, entries: [Entry]) { directories = [parent: Directory(entries)] }

    func entries(parent: UInt32) -> [Entry]? { directories[parent]?.entries }
    func seed(parent: UInt32, entries: [Entry]) { directories[parent] = Directory(entries) }
    func check(_ name: String, parent: UInt32) throws {
        guard let directory = directories[parent] else {
            throw USBError(message: "Upload destination was not checked. Upload stopped.")
        }
        try directory.names.check(name)
    }

    // Record only after the device confirms the write succeeded.
    func record(_ name: String, parent: UInt32, folderID: UInt32? = nil) {
        directories[parent]?.entries.append(Entry(id: 0, name: name, size: 0, folder: folderID != nil))
        directories[parent]?.names.record(name)
        if let folderID { directories[folderID] = Directory([]) }
    }
}
