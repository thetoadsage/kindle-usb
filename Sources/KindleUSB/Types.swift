import Foundation
struct Entry: Identifiable, Hashable, Codable {
    let id: UInt32
    let name: String
    let size: UInt64
    let folder: Bool
}
struct Storage: Identifiable, Hashable {
    let id: UInt32
    let name: String
    var freeBytes: UInt64? = nil
}
struct Location: Hashable, Codable { let id: UInt32; let name: String }
struct USBError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
enum FileRules {
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains(":" ) && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && name.utf8.count <= 240
    }
    static func checkName(_ name: String, entries: [Entry], excluding: UInt32? = nil) throws {
        guard validName(name) else { throw USBError(message: "Use a filename of 1–240 UTF-8 bytes without slashes, colons, or control characters.") }
        guard !entries.contains(where: { $0.id != excluding && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else { throw USBError(message: "An item named ‘\(name)’ already exists. Rename it first; existing files are never overwritten.") }
    }
}

/// ASCII names (the usual font/book filenames) get constant-time lookup.
/// Unicode names retain Foundation's exact comparison behavior, including ligatures.
struct FilenameIndex {
    private var ascii = Set<String>()
    private var unicode: [Entry] = []
    private var all: [Entry] = []
    init(entries: [Entry] = []) { for entry in entries { record(entry.name) } }
    private static func isASCII(_ name: String) -> Bool { name.utf8.allSatisfy { $0 < 128 } }
    func check(_ name: String) throws {
        if Self.isASCII(name) {
            try FileRules.checkName(name, entries: unicode)
            if ascii.contains(name.lowercased()) {
                try FileRules.checkName(name, entries: [Entry(id: 0, name: name, size: 0, folder: false)])
            }
        } else { try FileRules.checkName(name, entries: all) }
    }
    mutating func record(_ name: String) {
        let entry = Entry(id: 0, name: name, size: 0, folder: false)
        all.append(entry)
        if Self.isASCII(name) { ascii.insert(name.lowercased()) } else { unicode.append(entry) }
    }
}

/// Read the whole tree before deleting anything; remove children before parents.
/// Iterative traversal avoids overflowing the stack for deeply nested folders.
enum RecursiveDelete {
    static func execute(_ root: Entry, list: (UInt32) throws -> [Entry], remove: (Entry) throws -> Void) throws {
        var pending: [(Entry, Bool)] = [(root, false)]
        var visited = Set<UInt32>()
        var ordered: [Entry] = []
        while let (entry, expanded) = pending.popLast() {
            if expanded { ordered.append(entry); continue }
            guard entry.id != 0, entry.id != UInt32.max, visited.insert(entry.id).inserted else {
                throw USBError(message: "The folder tree could not be verified. Refresh before deleting.")
            }
            pending.append((entry, true))
            if entry.folder {
                for child in try list(entry.id).reversed() { pending.append((child, false)) }
            }
        }
        for entry in ordered { try remove(entry) }
    }
}

/// Suppress reopening the same USB attachment after eject/error, but allow a
/// new registry identity after unplug/replug, even between timer ticks.
struct ReconnectGate {
    private var blocked: Set<UInt64>?
    mutating func pause(attached: Set<UInt64>?) { blocked = attached }
    mutating func shouldResume(attached: Set<UInt64>?) -> Bool {
        guard let attached else { return false }
        guard let blocked else { self.blocked = attached; return false }
        return !attached.subtracting(blocked).isEmpty
    }
}
