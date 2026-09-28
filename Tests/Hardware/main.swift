import Foundation
func runHardwareTest() throws {
let client = MTPClient()
let context = TransferContext { _ in }
let fm = FileManager.default
let scratch = fm.temporaryDirectory.appendingPathComponent("kindle-usb-test-" + UUID().uuidString)
try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
defer { client.close(); try? fm.removeItem(at: scratch) }
let stores = try client.connect()
let sid = stores[0].id
let root = try client.list(storage: sid, parent: 0)
guard let documents = root.first(where: { $0.name == "documents" && $0.folder }) else { fatalError("Missing documents folder") }
let name = "KindleUSB-Test-" + UUID().uuidString
try client.mkdir(name, storage: sid, parent: documents.id)
guard let folder = try client.list(storage: sid, parent: documents.id).first(where: { $0.name == name && $0.folder }) else { fatalError("New test folder not found") }
print("Created isolated test folder: \(name)")
let source = scratch.appendingPathComponent("roundtrip.txt")
let payload = Data("Kindle USB isolated round-trip test.\nUnicode: café 日本語\n".utf8)
try payload.write(to: source)
try client.upload(source, storage: sid, parent: folder.id, context: context)
guard let file = try client.list(storage: sid, parent: folder.id).first(where: { $0.name == "roundtrip.txt" }) else { fatalError("Upload not listed") }
print("Upload and listing passed")
do { try client.upload(source, storage: sid, parent: folder.id, context: context); fatalError("Duplicate upload was not rejected") } catch { guard client.connected else { throw error }; print("Duplicate upload refused") }
let output = scratch.appendingPathComponent("download")
try fm.createDirectory(at: output, withIntermediateDirectories: false)
try client.download(file, to: output, context: context)
guard try Data(contentsOf: output.appendingPathComponent(file.name)) == payload else { fatalError("Round-trip data mismatch") }
print("Download byte-for-byte comparison passed")
do { try client.download(file, to: output, context: context); fatalError("Duplicate local download was not rejected") } catch { guard client.connected else { throw error }; print("Duplicate download refused") }
try client.rename(file, to: "renamed.txt", storage: sid, parent: folder.id)
guard let renamed = try client.list(storage: sid, parent: folder.id).first(where: { $0.name == "renamed.txt" }) else { fatalError("Rename not reflected") }
print("Rename passed")
try client.delete(renamed, storage: sid)
guard try client.list(storage: sid, parent: folder.id).isEmpty else { fatalError("Test folder unexpectedly nonempty; left intact") }
try client.delete(folder, storage: sid)
guard try !client.list(storage: sid, parent: documents.id).contains(where: { $0.id == folder.id }) else { fatalError("Test folder still present") }
print("Test file and folder deleted; hardware test passed")

}
do { try runHardwareTest() } catch {
    fputs("Hardware test stopped: \(error.localizedDescription)\nIf a test folder was created, it was left for inspection unless cleanup had already completed.\n", stderr)
    exit(1)
}
