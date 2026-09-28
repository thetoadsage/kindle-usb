import Foundation

/// Scan before writing so invalid names, unreadable folders, and links fail early.
struct UploadPlan {
    struct Item {
        let url: URL
        let relativePath: String
        let parentIndex: Int?
        let folder: Bool
    }
    let items: [Item]
    var fileCount: Int { items.filter { !$0.folder }.count }
    var folderCount: Int { items.count - fileCount }

    static func scan(_ urls: [URL], cancelled: () -> Bool) throws -> UploadPlan {
        var items: [Item] = []
        func visit(_ siblings: [URL], parentIndex: Int?, prefix: String) throws {
            var names: [Entry] = []
            for url in siblings {
                guard !cancelled() else { throw USBError(message: "Upload cancelled before any files were sent.") }
                try FileRules.checkName(url.lastPathComponent, entries: names)
                names.append(Entry(id: UInt32(names.count), name: url.lastPathComponent, size: 0, folder: false))
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
                items.append(Item(url: source, relativePath: relative, parentIndex: parentIndex, folder: values.isDirectory == true))
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

    /// Parent IDs come from successful MTP folder creation, never from guessed paths.
    func execute(parent: UInt32, cancelled: () -> Bool,
                 progress: (Int, Item) -> Void,
                 createFolder: (String, UInt32) throws -> UInt32,
                 sendFile: (URL, UInt32) throws -> Void) throws {
        var folders: [Int: UInt32] = [:]
        for (index, item) in items.enumerated() {
            guard !cancelled() else { throw USBError(message: "Upload cancelled. Completed files and folders were kept; remaining items were not transferred.") }
            let destination: UInt32
            if let parentIndex = item.parentIndex {
                guard let id = folders[parentIndex] else { throw USBError(message: "Upload folder mapping is incomplete.") }
                destination = id
            } else { destination = parent }
            progress(index, item)
            do {
                // Do not follow a source folder replaced with a link after the scan.
                var ancestor: Int? = index
                while let current = ancestor {
                    let values = try URL(fileURLWithPath: items[current].url.path).resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
                    guard values.isSymbolicLink != true, values.isAliasFile != true else { throw USBError(message: "Source changed into a link. Upload stopped.") }
                    ancestor = items[current].parentIndex
                }
                if item.folder { folders[index] = try createFolder(item.url.lastPathComponent, destination) }
                else { try sendFile(item.url, destination) }
            } catch {
                throw USBError(message: "Stopped at \(item.relativePath) (\(index + 1)/\(items.count)). Completed files and folders were kept.\n\n\(error.localizedDescription)")
            }
        }
    }
}
