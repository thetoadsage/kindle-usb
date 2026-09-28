import Foundation
var checks = 0
func check(_ condition: Bool, _ message: String) { checks += 1; if !condition { fatalError(message) } }
for name in ["", ".", "..", "../book", "a/b", "a\\b", "a:b", "a\u{0}b", String(repeating: "é", count: 121)] { check(!FileRules.validName(name), "Unsafe filename accepted") }
check(FileRules.validName("A Book — 日本語.epub"), "Unicode name rejected")
let entries = [Entry(id: 1, name: "Book.epub", size: 20, folder: false)]
do { try FileRules.checkName("book.EPUB", entries: entries); fatalError("Collision accepted") } catch { checks += 1 }
try FileRules.checkName("book.epub", entries: entries, excluding: 1)
try FileRules.checkName("Other.pdf", entries: entries)
check(!FileRules.validName(String(repeating: "a", count: 241)), "Overlong filename accepted")
print("Passed \(checks + 2) filename and collision checks")

let fm = FileManager.default
let temporary = fm.temporaryDirectory.appendingPathComponent("kindle-folder-tests-" + UUID().uuidString)
try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: temporary) }
let tree = temporary.appendingPathComponent("Books")
try fm.createDirectory(at: tree.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
try Data("one".utf8).write(to: tree.appendingPathComponent("one.txt"))
try Data("two".utf8).write(to: tree.appendingPathComponent("Nested/two.epub"))
let plan = try UploadPlan.scan([tree], cancelled: { false })
check(plan.fileCount == 2 && plan.folderCount == 3, "Nested files and empty folder missing")
var created: [String: UInt32] = [:]
var destinations: [String: UInt32] = [:]
var nextID: UInt32 = 100
try plan.execute(parent: 42, cancelled: { false }, progress: { _, _ in }, createFolder: { name, parent in
    if name == "Books" { check(parent == 42, "Root destination wrong") }
    if name == "Nested" { check(parent == created["Books"], "Nested destination wrong") }
    if name == "Empty" { check(parent == created["Nested"], "Empty folder destination wrong") }
    nextID += 1; created[name] = nextID; return nextID
}, sendFile: { url, parent in destinations[url.lastPathComponent] = parent })
check(destinations["one.txt"] == created["Books"], "Root file misplaced")
check(destinations["two.epub"] == created["Nested"], "Nested file misplaced")
var operations = 0
var cancel = false
do {
    try plan.execute(parent: 42, cancelled: { cancel }, progress: { _, _ in }, createFolder: { _, _ in operations += 1; cancel = true; return 100 }, sendFile: { _, _ in operations += 1 })
    fatalError("Cancellation ignored")
} catch { check(operations == 1, "Writes continued after cancellation") }
operations = 0
do {
    try plan.execute(parent: 42, cancelled: { false }, progress: { _, _ in }, createFolder: { _, _ in operations += 1; throw USBError(message: "Simulated USB failure") }, sendFile: { _, _ in operations += 1 })
    fatalError("Failure ignored")
} catch { check(operations == 1, "Writes continued after failure") }
do { _ = try UploadPlan.scan([tree, tree], cancelled: { false }); fatalError("Duplicate roots accepted") } catch { checks += 1 }
let linkURL = tree.appendingPathComponent("loop")
try fm.createSymbolicLink(at: linkURL, withDestinationURL: tree)
do { _ = try UploadPlan.scan([tree], cancelled: { false }); fatalError("Symbolic link followed") } catch { checks += 1 }
try fm.removeItem(at: linkURL)
do { _ = try UploadPlan.scan([tree], cancelled: { true }); fatalError("Scan cancellation ignored") } catch { checks += 1 }
// A directory replaced by a symlink between scanning and transfer must not be traversed.
try fm.moveItem(at: tree.appendingPathComponent("Nested"), to: temporary.appendingPathComponent("Moved"))
try fm.createSymbolicLink(at: tree.appendingPathComponent("Nested"), withDestinationURL: temporary.appendingPathComponent("Moved"))
operations = 0
do {
    try plan.execute(parent: 42, cancelled: { false }, progress: { _, _ in }, createFolder: { _, _ in operations += 1; return 100 }, sendFile: { _, _ in operations += 1 })
    fatalError("Source replaced by link was followed")
} catch { check(!error.localizedDescription.isEmpty, "Source change not reported") }
print("Passed folder traversal, destination mapping, empty folders, cancellation, failure, duplicate, and link checks (\(checks + 2) total)")
