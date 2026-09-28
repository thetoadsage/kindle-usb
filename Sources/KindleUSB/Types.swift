import Foundation
struct Entry: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let size: UInt64
    let folder: Bool
}
struct Storage: Identifiable, Hashable { let id: UInt32; let name: String }
struct Location: Hashable { let id: UInt32; let name: String }
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
