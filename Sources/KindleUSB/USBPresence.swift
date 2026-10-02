import Foundation
import IOKit

/// Read registry identities only: never opens an MTP session or claims USB.
enum USBPresence {
    static func kindleAttachments() -> Set<UInt64>? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return nil }
        // IOKit may return success with a null iterator when nothing matches.
        guard iterator != 0 else { return [] }
        defer { IOObjectRelease(iterator) }
        var result = Set<UInt64>()
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            let vendor = IORegistryEntryCreateCFProperty(device, "idVendor" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            guard vendor?.uint16Value == 0x1949 else { continue }
            var identity: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &identity) == KERN_SUCCESS else { return nil }
            result.insert(identity)
        }
        guard IOIteratorIsValid(iterator) != 0 else { return nil }
        return result
    }
}
