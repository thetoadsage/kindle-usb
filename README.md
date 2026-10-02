# Kindle USB

A native, account-free macOS file browser for Amazon MTP Kindles. SwiftUI + AppKit, arm64, macOS 13+. Files stay local; the app contains no networking, analytics, Amazon login, conversion, or jailbreak integration.

## Build

Install Apple's Command Line Tools and Homebrew's `pkgconf`. Full Xcode is optional. From the repository root:

```sh
brew install pkgconf
./scripts/build-dependencies.sh
./scripts/test.sh
./scripts/build.sh
open 'dist/Kindle USB.app'
```

If needed, install Command Line Tools with `xcode-select --install`. The scripts keep compiler caches and source builds in `.build`; no admin runtime helper or driver is installed. `--disable-sandbox` affects SwiftPM's build subprocess sandbox, not macOS security settings or the resulting app.

`build-dependencies.sh` downloads official libusb 1.0.30 and libmtp 1.1.23 source archives, verifies pinned SHA-256 hashes, and builds dynamic libraries locally with a macOS 13 deployment target. Build-time downloads are the only network activity. This avoids Homebrew's OS-specific bottles raising the app's runtime requirement. The locally built app bundle includes both libraries and their license texts; Homebrew is not needed to run it. Dependency compilation may take several minutes. Rebuilding dependencies is unnecessary unless `.build/dependencies` is removed or versions change. See [third-party notices](THIRD_PARTY_NOTICES.md).

For development using Homebrew directly:

```sh
MTP_PREFIX="$(brew --prefix)" swift build --build-system native
```

Homebrew libraries may require a newer OS than macOS 13. `MTP_PREFIX` can point at a custom prefix; the Swift package adds its include and library paths explicitly. Swift imports the `CMTP` C target's generated module, which is the SwiftPM equivalent of an Xcode bridging header. If using Xcode, open `Package.swift`; don't enable App Sandbox.

## Use

1. Quit Send to Kindle, Calibre, OpenMTP, and other MTP clients. Connect with a data-capable USB cable and unlock the Kindle. Allow the accessory if macOS asks.
2. The app discovers Amazon MTP devices every four seconds and opens the first accessible one. It selects `documents` when present. Choose a storage root in the sidebar, double-click folders, or use the parent-folder button to navigate.
3. Drop files or folders from Finder into the list, or choose **Add Files or Folders**. Folders are uploaded recursively, including empty folders, preserving their names and structure. The complete local tree is scanned before writing; symbolic links and Finder aliases are rejected. Existing destination folders are not merged or overwritten. The displayed folder is the destination. No file extension filter is imposed: EPUB, PDF, MOBI, AZW3, TXT, DOC, DOCX, and other files are copied byte-for-byte. Transfer acceptance does not imply Kindle reader compatibility. No conversion or DRM removal occurs.
4. Command-click or Shift-click to select files; choose **Save to Mac**, then choose a destination directory. Folder downloads are not implemented. Finder drag-out/file promises are not implemented; Save to Mac provides the requested alternative.
5. **Manage** creates folders, renames a selected item, and deletes selected items after confirmation. Folder deletion includes all files and subfolders inside the selected folders. There is no Trash or Undo. Deletion stops on an error; items already deleted cannot be restored. Firmware can reject management operations, especially on protected objects.
6. Wait for completion, then choose **Disconnect**. After explicit disconnect or a protocol error, the same USB attachment stays paused. Unplugging and plugging the Kindle back in resumes connection checks automatically (within the four-second polling interval); Refresh also resumes them. Quitting is refused while a USB operation is active; cancel or wait first.

Names that collide (including case-insensitive collisions) are refused, rather than overwritten. If a batch fails, earlier successful files remain and later ones are not attempted. The error identifies the item where the batch stopped. Refresh a still-connected session after a partially completed management operation to see the actual device state.

## Architecture and tradeoffs

- `Sources/CMTP`: C interoperability, Amazon vendor-ID filtering, libmtp initialization/opening, and an atomic cancellation token.
- `Sources/KindleUSB/MTPClient.swift`: owns the uncached libmtp session; lists storage and folder objects; pushes/pulls files with progress callbacks; implements delete, rename, and folder creation.
- `BrowserModel.swift`: main-thread UI state and one serial background USB queue. No two libmtp operations overlap. A four-second idle storage query detects disconnects. Polling is suspended during transfers; the active operation reports transport loss. No device pointer is released while another operation uses it.
- `KindleUSBApp.swift`: folder sidebar, multi-select table, Finder drop handling, AppKit file panels, progress, cancellation, and management dialogs.
- `Types.swift`: value objects, local path validation, and indexed ASCII collision checks with the existing Unicode comparisons preserved.
- `TransferSupport.swift`: stable source descriptors, batch preflight, byte progress, monotonic timings, remote metadata checks, and persistent upload checkpoints.
- `UploadPlan.swift`: recursive local scan and sequential upload ordering, with parent object IDs returned by folder creation, cancellation between items, and no writes after a failed item.

Direct linking keeps a persistent session and supplies structured object IDs, errors, and progress. CLI subprocesses such as `mtp-files`, `mtp-sendfile`, and `mtp-getfile` would reduce initial bridging work, but reopen sessions, often enumerate broadly, have tool/version-dependent output and folder syntax, and make progress/cancellation harder to coordinate. They are useful diagnostics, not the chosen backend.

The app currently supports one attached Kindle at a time (first accessible Amazon MTP device), with a choice of exposed storages. Jailbreak status doesn't change the transport; only folders exposed by the Kindle's MTP server are visible. It does not access the root filesystem via SSH or USB networking.

## Transfer checks, progress, and recovery

Uploads scan the entire selection for readable regular files before any remote writes, then check the batch's total bytes against reported free space. The scan records each file's identity, size, and modification/change timestamps. Uploads read from an open descriptor that refuses a final-component symlink and check those timestamps and the source pathname again after sending. Each completed upload also checks the device-reported object ID, name, size, parent, and storage. These metadata checks are not a checksum or byte-for-byte integrity proof.

Folder listings require metadata for every reported object and stop on incomplete results. Names are checked against one initial destination listing and updated in memory after confirmed writes. Newly created folders start empty. All USB work remains serialized; no write is automatically retried. Download preflight checks all destination names (including dangling links), reported local free space, and the ability to publish through hard links before receiving any files. Reported free-space checks cannot guarantee enough space if another process consumes it or the filesystem needs additional metadata space.

The progress bar represents the whole batch by bytes, with a small accounting unit for folders and empty files. The app prevents idle system sleep and App Nap while it checks/transfers files; explicit sleep, power loss, and unplugging can still interrupt a transfer. The info button shows elapsed time and timings for phases such as Scan, Directory, Send/Receive, Verify, Checkpoint, and Refresh. Send/Receive measures the libmtp operation, including its protocol and metadata work. Saving to Mac does not reread an unchanged Kindle directory. A failed final upload refresh is reported separately from successful file transfers.

An interrupted upload exposes **Continue Upload** after reconnecting. The local checkpoint survives app restarts in `~/Library/Application Support/Kindle USB/unfinished-upload.json`, with small append-only `.events` records. The files contain source paths, source metadata, destination paths, and confirmed object IDs. They are private local files; the device identifier is hashed and the raw serial is not saved or logged. **Forget Upload** deletes the local recovery record and leaves Kindle contents in place. Finish or forget an existing checkpoint before starting another upload.

Continue opens a fresh connection to discard old metadata, checks the device/storage identity and original destination IDs, checks source files for changes, and lists existing batch destinations once to verify previously confirmed objects. It skips only those confirmed objects and sends the remaining items. A changed/missing completed object or an unconfirmed same-named object (even one with the expected size) stops continuation before writes. Inspect and explicitly delete any partial object before continuing. If the Kindle does not report a stable identity, continuation across connections is unavailable. Recovery is for uploads; interrupted downloads keep their completed local files, and the remaining files can be selected for a new Save to Mac batch.

## Interrupted transfers

Downloads go into a private temporary directory beside the destination. The app checks the byte count and publishes using a same-filesystem hard link that cannot overwrite an existing path, then removes the temporary copy. Destination filesystems must support hard links (APFS/HFS+ do; FAT/exFAT do not). Downloads to unsupported filesystems fail without replacing an existing file. Force-killing the process can leave a hidden `.kindle-transfer-*` directory; normal cancellation/error paths clean it up.

Uploads never intentionally overwrite a same-named object. libmtp writes directly through MTP; neither MTP nor this app guarantees an atomic upload, rollback, or a corruption-free device database if power/USB is removed mid-write. The app stops the batch, discards a failed session, and never retries writes automatically. A partial remote file may remain; inspect it after reconnecting and delete it explicitly. Cancellation uses libmtp callbacks and may wait for a blocking USB call to return. No unsafe concurrent close or automatic remote cleanup is attempted.

## Signing and distribution

For your own Mac, the script ad-hoc signs the executable and bundled dylibs. It uses **no App Sandbox entitlement**, USB sandbox entitlement, privileged helper, root privileges, or kernel extension. A non-sandboxed process accesses USB through libusb/IOKit, subject to macOS accessory authorization and exclusive access held by other apps. Ordinary macOS privacy prompts can still apply to protected local folders.

The local ad-hoc build does not enable Hardened Runtime: its library validation rejects ad-hoc third-party dylibs without a signing team. There is no need to disable Gatekeeper or SIP. A local build is not a trusted downloadable release; a quarantined copy on another Mac can be blocked by Gatekeeper.

For later outside-App-Store distribution, use a paid Apple Developer **Developer ID Application** identity:

```sh
SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' ./scripts/build.sh
```

That path enables Hardened Runtime and secure timestamps and signs both dylibs with the same identity before signing the enclosing app. No `get-task-allow` or `disable-library-validation` entitlement is added. Then create a ZIP, notarize, and staple using full Xcode's tools:

```sh
ditto -c -k --keepParent 'dist/Kindle USB.app' dist/KindleUSB.zip
xcrun notarytool submit dist/KindleUSB.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple 'dist/Kindle USB.app'
xcrun stapler validate 'dist/Kindle USB.app'
# Recreate the ZIP after stapling if distributing a ZIP.
```

This GitHub project publishes source only; it does not provide prebuilt app downloads. The app links dynamically to libmtp and libusb under LGPL 2.1. Their license texts and pinned source download details are included in this repository. If prebuilt app downloads are added later, provide the corresponding library sources and meet the LGPL requirements for those binaries. Notarization is only needed if trusted downloadable app bundles are offered; it is a release-time submission to Apple, never app runtime networking.

References: [libmtp source/API](https://github.com/libmtp/libmtp), [libusb releases](https://github.com/libusb/libusb/releases), [Apple distribution guidance](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Prioritized build plan and validation

1. **v1 foundation, implemented:** detection/session ownership, storage/folder browsing, single-file push and pull, Finder drop, Save to Mac, disconnect handling.
2. **v2 usability, implemented:** multi-select, sequential multi-file batches, per-file progress with batch position, cancellation, delete confirmation, rename, folder creation, and collision protection.
3. **Hardware acceptance:** read-only connection/storage/documents listing; then test upload/download with a disposable TXT and compare SHA-256, test duplicate refusal and management in an isolated folder, then test cancellation and cable removal using disposable files only. Repeat on stock firmware and macOS 13 before claiming broad support.
4. **Later, optional:** Finder file-promise drag-out, recursive folder downloads, device picker, and notarized releases.

`./scripts/test.sh` runs filename traversal/control-character/length and collision checks with plain Swift, so it does not require XCTest/full Xcode. Folder tests also cover nested destination mapping, empty folders, cancellation, failure propagation, duplicate roots, and symbolic links. Additional local checks cover source changes, free-space and destination preflight, aggregate progress, metadata mismatches, checkpoint failures/corruption, interrupted checkpoint appends, wrong-device recovery, and continuation using a fake remote tree. These checks do not simulate USB hardware or prove transfer integrity.

The checked-in `scripts/probe.c` provides a read-only hardware test while all other MTP clients are closed:

```sh
mkdir -p .build
clang -I"$(brew --prefix)/include" -ISources/CMTP/include scripts/probe.c Sources/CMTP/CMTP.c -L"$(brew --prefix)/lib" -lmtp -o .build/probe
.build/probe
```

Hardware testing has been completed on a 12th-generation Kindle Paperwhite Signature Edition. Browsing, folder navigation, upload and download round trips, collision refusal, rename, and deletion of files and empty folders were verified. Finder drag-and-drop, multi-file UI batches, cancellation under load, cable removal during transfer, stock firmware, and execution on macOS 13 still need hands-on validation. The app targets macOS 13; that declared minimum is not a substitute for testing on macOS 13.

For the opt-in disposable hardware test (writes only a uniquely named test folder/file), close or disconnect the GUI and run:

```sh
./scripts/hardware-test.sh --allow-test-writes
```

It checks folder creation, upload, duplicate refusal, byte-for-byte download, rename, and cleanup. If a protocol failure interrupts the test, it leaves any remaining test objects for inspection rather than attempting cleanup through a failed session.

Recursive folder uploads are built and covered by local traversal/execution tests; a real recursive folder transfer has not yet been verified on the Kindle. Cancellation or failure retains already-created remote folders/files. The upload list includes hidden files; file contents are copied unchanged.

The transfer preflight, metadata verification, checkpoint continuation, sleep protection, and timing UI have passed local checks and compilation. They have not yet been exercised in a real Kindle transfer; no measured device speedup is claimed.

### Kindle disconnect cleanup

The bundled libmtp includes `scripts/patches/libmtp-kindle-close-timeout.patch`.
After a successful Amazon device session close, it skips the two best-effort
USB endpoint status probes because the Kindle may already have left USB mode.
The forced USB reset is retained: this Kindle needs it to leave USB mode.
macOS may take about ten seconds to finish that reset. The app waits for release
to finish before confirming disconnect.
If session closing fails, the probes still run with a 500 ms timeout each.
Session-close and transfer timeouts are unchanged, and interface release
still completes before the app reports that it is safe to unplug. This does not
bound the entire disconnect operation. Custom `MTP_PREFIX` libraries need the same
patch to receive this behavior.

`python3 scripts/test-disconnect.py` checks the patched disconnect paths with fake
USB calls after building dependencies; it does not access a device.
