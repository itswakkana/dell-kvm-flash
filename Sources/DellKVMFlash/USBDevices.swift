import Foundation
import IOKit
import IOKit.usb

struct USBDevice: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case keyboard, mouse, other

        var symbol: String {
            switch self {
            case .keyboard: return "keyboard"
            case .mouse: return "computermouse"
            case .other: return "cable.connector"
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind
}

/// USB keyboards and mice this Mac can see. Read straight from the IORegistry: unlike
/// IOHIDManager this needs no Input Monitoring permission. The monitor's KVM only moves
/// devices on its own hub, and macOS gives no reliable way to tell which hub that is,
/// so hubs, Ethernet and other internal chips are filtered out instead.
enum USBDevices {
    static func connected() -> [USBDevice] {
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var seen = Set<String>()
        var devices: [USBDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            if let deviceClass = property(service, "bDeviceClass") as? Int, deviceClass == 9 { continue }
            if let vendor = property(service, "idVendor") as? Int, vendor == 0x05ac { continue }
            guard let name = property(service, "USB Product Name") as? String, !name.isEmpty else { continue }
            if name.localizedCaseInsensitiveContains("hub") { continue }
            guard let kind = hidKind(service) else { continue }

            let vendor = property(service, "idVendor") as? Int ?? 0
            let key = "\(vendor)-\(name)"
            if seen.insert(key).inserted {
                devices.append(USBDevice(id: key, name: name, kind: kind))
            }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// nil means "not a HID device". A composite device reports several interfaces, so a
    /// keyboard/mouse interface wins over a vendor-specific one.
    private static func hidKind(_ service: io_registry_entry_t) -> USBDevice.Kind? {
        if let deviceClass = property(service, "bDeviceClass") as? Int, deviceClass == 3 {
            return kind(subClass: property(service, "bDeviceSubClass") as? Int,
                        protocolNumber: property(service, "bDeviceProtocol") as? Int)
        }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var found: USBDevice.Kind?
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            defer { IOObjectRelease(child) }
            guard let interfaceClass = property(child, "bInterfaceClass") as? Int, interfaceClass == 3 else { continue }
            let kind = kind(subClass: property(child, "bInterfaceSubClass") as? Int,
                            protocolNumber: property(child, "bInterfaceProtocol") as? Int)
            if kind != .other { return kind }
            found = .other
        }
        return found
    }

    /// Only the boot interface (subclass 1) declares what the device is.
    private static func kind(subClass: Int?, protocolNumber: Int?) -> USBDevice.Kind {
        guard subClass == 1 else { return .other }
        switch protocolNumber {
        case 1: return .keyboard
        case 2: return .mouse
        default: return .other
        }
    }

    private static func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
