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

// Batch collision protection must match standalone checks without remote listings.
let batch = UploadDirectoryCache(parent: 42, entries: entries)
do { try batch.check("BOOK.EPUB", parent: 42); fatalError("Existing destination collision accepted") } catch { checks += 1 }
try batch.check("Fonts", parent: 42)
batch.record("Fonts", parent: 42, folderID: 100)
try batch.check("Font.ttf", parent: 100)
batch.record("Font.ttf", parent: 100)
do { try batch.check("font.TTF", parent: 100); fatalError("Uploaded file collision accepted") } catch { checks += 1 }
do { try batch.check("fonts", parent: 42); fatalError("Created folder collision accepted") } catch { checks += 1 }
do { try batch.check("a.ttf", parent: 999); fatalError("Unknown destination accepted") } catch { checks += 1 }
try batch.check("Font.ttf", parent: 42) // Names remain scoped to their parent.
let freshBatch = UploadDirectoryCache(parent: 42, entries: [])
try freshBatch.check("Fonts", parent: 42) // No state leaks between batches.
print("Passed batch duplicate protection and destination isolation checks")

// Source descriptors reject links and detect both in-place changes and replacements.
let reliableSource = temporary.appendingPathComponent("stable.ttf")
try Data("font".utf8).write(to: reliableSource)
let opened = try UploadSource(reliableSource)
try opened.checkUnchanged()
try Data("font changed".utf8).write(to: reliableSource, options: [])
do { try opened.checkUnchanged(); fatalError("In-place source change accepted") } catch { checks += 1 }
do { _ = try UploadSource(reliableSource, expected: opened.stamp); fatalError("Changed source stamp accepted") } catch { checks += 1 }
let sourceLink = temporary.appendingPathComponent("source-link.ttf")
try fm.createSymbolicLink(at: sourceLink, withDestinationURL: reliableSource)
do { _ = try UploadSource(sourceLink); fatalError("Upload followed a source link") } catch { checks += 1 }
let fifo = temporary.appendingPathComponent("fifo")
check(mkfifo(fifo.path, 0o600) == 0, "Cannot create test FIFO")
do { _ = try UploadSource(fifo); fatalError("Non-regular source accepted") } catch { checks += 1 }

try BatchPreflight.space(required: 20, available: 20)
try BatchPreflight.space(required: 20, available: nil)
do { try BatchPreflight.space(required: 21, available: 20); fatalError("Insufficient space accepted") } catch { checks += 1 }
do { _ = try BatchPreflight.bytes([UInt64.max, 1]); fatalError("Batch byte overflow accepted") } catch { checks += 1 }
let downloadDirectory = temporary.appendingPathComponent("downloads")
try fm.createDirectory(at: downloadDirectory, withIntermediateDirectories: false)
let downloadable = Entry(id: 10, name: "font.ttf", size: 4, folder: false)
try BatchPreflight.downloads([downloadable], to: downloadDirectory, cancelled: { false })
check(try fm.contentsOfDirectory(atPath: downloadDirectory.path).isEmpty, "Preflight left temporary files")
try Data().write(to: downloadDirectory.appendingPathComponent("FONT.TTF"))
do { try BatchPreflight.downloads([downloadable], to: downloadDirectory, cancelled: { false }); fatalError("Existing download name accepted") } catch { checks += 1 }
try fm.removeItem(at: downloadDirectory.appendingPathComponent("FONT.TTF"))
do { try BatchPreflight.downloads([downloadable, downloadable], to: downloadDirectory, cancelled: { false }); fatalError("Duplicate batch download names accepted") } catch { checks += 1 }
try fm.createSymbolicLink(atPath: downloadDirectory.appendingPathComponent("font.ttf").path, withDestinationPath: "/nonexistent-kindle-test-target")
do { try BatchPreflight.downloads([downloadable], to: downloadDirectory, cancelled: { false }); fatalError("Dangling destination link accepted") } catch { checks += 1 }

var overall = BatchProgress()
overall.configure(sizes: [100, 900, 0], completedSizes: [100])
check(overall.fraction() > 0.09 && overall.fraction() < 0.11, "Resume progress lost completed files")
overall.begin(size: 900)
check(overall.fraction(sent: 450, expected: 900) > 0.54, "Byte progress is not aggregated")
overall.finish(size: 900)
check(overall.fraction() < 1, "Pending empty item ignored")
overall.begin(size: 0); overall.finish(size: 0)
check(overall.fraction() == 1, "Completed batch did not reach 100 percent")

// Recovery is tested with a fake remote tree; no USB device is touched.
let recoveryTree = temporary.appendingPathComponent("Fonts")
try fm.createDirectory(at: recoveryTree.appendingPathComponent("Nested"), withIntermediateDirectories: true)
try Data("aaaa".utf8).write(to: recoveryTree.appendingPathComponent("a.ttf"))
try Data("bbbb".utf8).write(to: recoveryTree.appendingPathComponent("b.ttf"))
try Data("cccc".utf8).write(to: recoveryTree.appendingPathComponent("Nested/c.ttf"))
let recoveryPlan = try UploadPlan.scan([recoveryTree], cancelled: { false })
let testStorage = Storage(id: 7, name: "Kindle")
var journal = UploadJournal(deviceIdentity: "test-device", storage: testStorage, destination: [], plan: recoveryPlan)
let store = UploadJournalStore(url: temporary.appendingPathComponent("journal/unfinished.json"))
var remote: [UInt32: [Entry]] = [42: []]
var objectID: UInt32 = 500
var lastFile: Entry?
var writes = 0
var interrupted = false
try store.save(journal)
do {
    try recoveryPlan.execute(parent: 42, cancelled: { interrupted }, progress: { _, _ in }, createFolder: { name, parent in
        objectID += 1
        let entry = Entry(id: objectID, name: name, size: 0, folder: true)
        remote[parent, default: []].append(entry); remote[objectID] = []
        writes += 1; return objectID
    }, sendFile: { url, parent in
        objectID += 1
        lastFile = Entry(id: objectID, name: url.lastPathComponent, size: 4, folder: false)
        remote[parent, default: []].append(lastFile!); writes += 1
    }, beforeWrite: { index in journal.inFlight = index; try store.save(journal) }, didComplete: { index, item, folderID in
        journal.completed[index] = folderID.map { Entry(id: $0, name: item.url.lastPathComponent, size: 0, folder: true) } ?? lastFile!
        journal.inFlight = nil; try store.save(journal)
        if writes == 2 { interrupted = true }
    })
    fatalError("Recovery fixture failed to interrupt")
} catch { check(writes == 2, "Writes continued after interruption") }
journal = try store.load()
check(journal.completed.count == 2, "Confirmed checkpoint objects lost")
try journal.checkTarget(identity: "test-device", storage: testStorage)
do { try journal.checkTarget(identity: "other-device", storage: testStorage); fatalError("Wrong device accepted") } catch { checks += 1 }
do { try journal.checkTarget(identity: "test-device", storage: Storage(id: 8, name: "Kindle")); fatalError("Wrong storage accepted") } catch { checks += 1 }
try journal.plan.checkSources(cancelled: { false })
var reads: [UInt32: Int] = [:]
let recoveryCache = try journal.prepare(parent: 42, list: { parent in
    reads[parent, default: 0] += 1; return remote[parent] ?? []
}, cancelled: { false })
check(reads.values.allSatisfy { $0 == 1 }, "Recovery relisted a destination")
check(recoveryCache.entries(parent: journal.completed[0]!.id) != nil, "Created folder cache not restored")
let originalCompleted = journal.completed
interrupted = false
try recoveryPlan.execute(parent: 42, cancelled: { false }, progress: { _, _ in }, createFolder: { name, parent in
    objectID += 1
    let entry = Entry(id: objectID, name: name, size: 0, folder: true)
    remote[parent, default: []].append(entry); remote[objectID] = []; writes += 1
    return objectID
}, sendFile: { url, parent in
    objectID += 1; lastFile = Entry(id: objectID, name: url.lastPathComponent, size: 4, folder: false)
    remote[parent, default: []].append(lastFile!); writes += 1
}, completed: originalCompleted, beforeWrite: { index in journal.inFlight = index; try store.save(journal) }, didComplete: { index, item, folderID in
    journal.completed[index] = folderID.map { Entry(id: $0, name: item.url.lastPathComponent, size: 0, folder: true) } ?? lastFile!
    journal.inFlight = nil; try store.save(journal)
})
check(writes == recoveryPlan.items.count, "Continue resent a confirmed item")
check(journal.completed.count == recoveryPlan.items.count, "Remaining items not confirmed")
_ = try journal.prepare(parent: 42, list: { remote[$0] ?? [] }, cancelled: { false })
// A changed completed remote file must never be trusted based on its name alone.
let completedFile = journal.completed.first { !$0.value.folder }!
let targetParent = journal.completed[recoveryPlan.items[completedFile.key].parentIndex!]!.id
let file = completedFile.value
remote[targetParent]!.removeAll { $0.id == file.id }
remote[targetParent]!.append(Entry(id: file.id, name: file.name, size: 99, folder: false))
do { _ = try journal.prepare(parent: 42, list: { remote[$0] ?? [] }, cancelled: { false }); fatalError("Changed completed object accepted") } catch { checks += 1 }
// Unknown partial objects, including full-size ones, are not silently skipped.
var partial = journal
partial.completed.removeValue(forKey: completedFile.key); partial.inFlight = completedFile.key
remote[targetParent]!.removeAll { $0.id == file.id }; remote[targetParent]!.append(file)
do { _ = try partial.prepare(parent: 42, list: { remote[$0] ?? [] }, cancelled: { false }); fatalError("Unconfirmed full-size object accepted") } catch { checks += 1 }
try Data("changed".utf8).write(to: recoveryTree.appendingPathComponent("a.ttf"))
do { try journal.plan.checkSources(cancelled: { false }); fatalError("Continue accepted changed source") } catch { checks += 1 }
try Data("broken checkpoint".utf8).write(to: store.url)
do { _ = try store.load(); fatalError("Corrupt checkpoint accepted") } catch { checks += 1 }
try store.clear(); check(!store.exists, "Checkpoint not removed")
print("Passed preflight, source mutation, batch progress and recovery checks (\(checks + 2) total)")

// Faster name lookup must preserve the existing Unicode comparison semantics.
let collisionNames = ["Font.ttf", "FONT.TTF", "café.ttf", "cafe\u{301}.ttf", "cafe.ttf", "Straße.ttf", "STRASSE.TTF", "İ.ttf", "i.ttf", "ı.ttf", "I.ttf", "Σ.ttf", "σ.ttf", "ς.ttf", "ﬀ.ttf", "ff.ttf", "Ｋ.ttf", "K.ttf", "K.ttf", "ﬁ.ttf", "fi.ttf", "Æ.ttf", "AE.ttf", "œ.ttf", "oe.ttf", "Å.ttf", "A.ttf", "日本語.ttf"]
for existing in collisionNames {
    let entries = [Entry(id: 1, name: existing, size: 0, folder: false)]
    let index = FilenameIndex(entries: entries)
    for candidate in collisionNames {
        let baseline: Bool, indexed: Bool
        do { try FileRules.checkName(candidate, entries: entries); baseline = true } catch { baseline = false }
        do { try index.check(candidate); indexed = true } catch { indexed = false }
        check(baseline == indexed, "Indexed name comparison changed collision behavior")
    }
}
// Simulate a torn checkpoint append: prior confirmations survive, tail is removed.
let tornStore = UploadJournalStore(url: temporary.appendingPathComponent("torn/unfinished.json"))
var tornJournal = UploadJournal(deviceIdentity: "test-device", storage: testStorage, destination: [], plan: recoveryPlan)
try tornStore.save(tornJournal)
tornJournal.inFlight = 0; try tornStore.save(tornJournal)
tornJournal.completed[0] = Entry(id: 1000, name: "Fonts", size: 0, folder: true)
tornJournal.inFlight = nil; try tornStore.save(tornJournal)
let eventsURL = tornStore.url.appendingPathExtension("events")
let eventsBefore = try Data(contentsOf: eventsURL)
let appendHandle = try FileHandle(forWritingTo: eventsURL)
try appendHandle.seekToEnd(); try appendHandle.write(contentsOf: Data("{incomplete".utf8)); try appendHandle.close()
let restartedStore = UploadJournalStore(url: tornStore.url)
let recovered = try restartedStore.load()
check(recovered.completed[0]?.id == 1000, "Torn append lost previous confirmations")
check(try Data(contentsOf: eventsURL) == eventsBefore, "Interrupted checkpoint tail was not trimmed")
try restartedStore.clear()
print("Passed indexed Unicode collision and torn checkpoint checks (\(checks + 2) total)")

let verifiedEntry = Entry(id: 17, name: "font.ttf", size: 4, folder: false)
try RemoteObject(entry: verifiedEntry, parent: 42, storage: 7).check(name: "font.ttf", size: 4, folder: false, parent: 42, storage: 7)
for object in [
    RemoteObject(entry: Entry(id: 0, name: "font.ttf", size: 4, folder: false), parent: 42, storage: 7),
    RemoteObject(entry: Entry(id: 17, name: "other.ttf", size: 4, folder: false), parent: 42, storage: 7),
    RemoteObject(entry: Entry(id: 17, name: "font.ttf", size: 3, folder: false), parent: 42, storage: 7),
    RemoteObject(entry: Entry(id: 17, name: "font.ttf", size: 4, folder: true), parent: 42, storage: 7),
    RemoteObject(entry: verifiedEntry, parent: 43, storage: 7),
    RemoteObject(entry: verifiedEntry, parent: 42, storage: 8)
] {
    do { try object.check(name: "font.ttf", size: 4, folder: false, parent: 42, storage: 7); fatalError("Incorrect upload metadata accepted") } catch { checks += 1 }
}
var writesAfterCheckpointFailure = 0
do {
    try recoveryPlan.execute(parent: 42, cancelled: { false }, progress: { _, _ in }, createFolder: { _, _ in writesAfterCheckpointFailure += 1; return 50 }, sendFile: { _, _ in writesAfterCheckpointFailure += 1 }, beforeWrite: { _ in throw USBError(message: "Checkpoint cannot be saved") })
    fatalError("Failed checkpoint allowed writes")
} catch { check(writesAfterCheckpointFailure == 0, "Device writes happened after checkpoint failure") }
print("Passed upload metadata and checkpoint failure checks (\(checks + 2) total)")

// Recursive deletion: nested/empty folders, complete preflight, and stop on failure.
let deleteRoot = Entry(id: 700, name: "Root", size: 0, folder: true)
let deleteNested = Entry(id: 701, name: "Nested", size: 0, folder: true)
let deleteFile = Entry(id: 702, name: "File", size: 1, folder: false)
let deleteEmpty = Entry(id: 703, name: "Empty", size: 0, folder: true)
let deleteTree: [UInt32: [Entry]] = [700: [deleteNested, deleteEmpty], 701: [deleteFile], 703: []]
var deleted: [UInt32] = []
try RecursiveDelete.execute(deleteRoot, list: { deleteTree[$0]! }, remove: { deleted.append($0.id) })
check(deleted == [702, 701, 703, 700], "Delete must remove children before parents")
deleted = []
do {
    try RecursiveDelete.execute(deleteRoot, list: { id in
        if id == 703 { throw USBError(message: "Listing failed") }
        return deleteTree[id]!
    }, remove: { deleted.append($0.id) })
    fatalError("Listing failure ignored")
} catch { check(deleted.isEmpty, "Deleted before all folder listings succeeded") }
do {
    try RecursiveDelete.execute(deleteRoot, list: { deleteTree[$0]! }, remove: {
        if $0.id == 701 { throw USBError(message: "Delete failed") }
        deleted.append($0.id)
    })
    fatalError("Delete failure ignored")
} catch { check(deleted == [702], "Deletion continued after failure") }
deleted = []
do {
    try RecursiveDelete.execute(deleteRoot, list: { _ in [deleteRoot] }, remove: { deleted.append($0.id) })
    fatalError("Cycle accepted")
} catch { check(deleted.isEmpty, "Malformed tree caused deletion") }
try RecursiveDelete.execute(deleteFile, list: { _ in fatalError("Listed a file") }, remove: { deleted.append($0.id) })
check(deleted == [702], "Standalone file deletion failed")
print("Passed recursive deletion checks (\(checks + 2) total)")

var reconnectGate = ReconnectGate()
reconnectGate.pause(attached: [100])
check(!reconnectGate.shouldResume(attached: [100]), "Reopened explicitly disconnected attachment")
check(!reconnectGate.shouldResume(attached: []), "Tried connecting with no USB device")
check(!reconnectGate.shouldResume(attached: nil), "Registry failure triggered reconnect")
check(reconnectGate.shouldResume(attached: [101]), "Replug failed to resume connection")
reconnectGate.pause(attached: [101])
check(reconnectGate.shouldResume(attached: [102]), "Missed replug between timer ticks")
reconnectGate.pause(attached: [])
check(reconnectGate.shouldResume(attached: [103]), "New attachment after cable loss ignored")
reconnectGate.pause(attached: nil)
check(!reconnectGate.shouldResume(attached: [103]), "Unknown baseline reopened existing device")
check(reconnectGate.shouldResume(attached: [104]), "New attachment after registry recovery ignored")
print("Passed reconnect attachment checks (\(checks + 2) total)")
