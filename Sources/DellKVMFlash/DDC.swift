import AppKit
import IOKit

/// DDC/CI straight over the private IOAVService I2C bridge — the same path m1ddc uses, so no helper
/// binary and no HID device is involved. Only external panels answer DDC.
enum DDC {
    private static let host: UInt8 = 0x51
    private static let display: UInt8 = 0x6E
    // shortcut: MCDP29XX panels route DDC at 0xB7; add that fallback if such a Mac ever shows up.
    private static let chip: UInt32 = 0x37

    private typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias Transfer = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> kern_return_t

    /// IOAVService is private API, so the symbols are resolved at runtime instead of linked.
    private static let iokit: (create: CreateWithService, read: Transfer, write: Transfer)? = {
        let path = "/System/Library/Frameworks/IOKit.framework/IOKit"
        guard let handle = dlopen(path, RTLD_LAZY),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C")
        else { return nil }
        return (unsafeBitCast(create, to: CreateWithService.self),
                unsafeBitCast(read, to: Transfer.self),
                unsafeBitCast(write, to: Transfer.self))
    }()

    /// One external display's DDC channel, closed when the call that opened it returns.
    private final class Channel {
        let service: UnsafeMutableRawPointer
        init(service: UnsafeMutableRawPointer) { self.service = service }
        deinit { Unmanaged<AnyObject>.fromOpaque(service).release() }
    }

    static var isAvailable: Bool { channel() != nil }

    /// shortcut: names the first external screen, which is the one this app drives.
    static func displayName() -> String? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) == 0
        }?.localizedName
    }

    /// VCP 0x60. Dell puts the active input in the low byte; the high byte is not the input
    /// (it reads 0x0F while the panel is on Thunderbolt 4 = 25).
    static func currentInput() -> Int? {
        guard let channel = channel(), let value = read(0x60, from: channel) else { return nil }
        let code = value & 0xFF
        return (1...30).contains(code) ? code : nil
    }

    @discardableResult
    static func setInput(_ code: Int) -> Bool {
        write(0x60, value: code)
    }

    static func luminance() -> Int? {
        guard let channel = channel() else { return nil }
        return read(0x10, from: channel)
    }

    // MARK: - Wire

    private static func channel() -> Channel? {
        guard let iokit, let matching = IOServiceMatching("DCPAVServiceProxy") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { return nil }
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntrySearchCFProperty(
                entry, "IOService", "Location" as CFString, nil, IOOptionBits(kIORegistryIterateRecursively)
            ) as? String
            guard location == "External", let service = iokit.create(nil, entry) else { continue }
            return Channel(service: service)
        }
    }

    /// Reply frame: 0x6E, length, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, checksum.
    /// A panel that is still settling after a switch drops requests, so ask twice.
    private static func read(_ vcp: UInt8, from channel: Channel) -> Int? {
        guard let iokit else { return nil }
        for _ in 0..<2 {
            var request: [UInt8] = [0x82, 0x01, vcp, 0]
            request[3] = checksum(request[0..<3], source: host)
            for _ in 0..<2 {
                usleep(10_000)
                if iokit.write(channel.service, chip, UInt32(host), &request, 4) == 0 { break }
            }
            var reply = [UInt8](repeating: 0, count: 11)
            usleep(40_000)
            if iokit.read(channel.service, chip, UInt32(host), &reply, 11) == 0,
               reply[0] == display, reply[2] == 0x02, reply[3] == 0, reply[4] == vcp,
               reply[10] == checksum(reply[1..<10], source: 0x50) { // the panel's replies count the host as 0x50
                return Int(reply[8]) << 8 | Int(reply[9])
            }
        }
        return nil
    }

    @discardableResult
    private static func write(_ vcp: UInt8, value: Int) -> Bool {
        guard let iokit, let channel = channel() else { return false }
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value), 0]
        packet[5] = checksum(packet[0..<5], source: host)
        for _ in 0..<3 {
            usleep(10_000)
            if iokit.write(channel.service, chip, UInt32(host), &packet, 6) == 0 { return true }
        }
        return false
    }

    private static func checksum(_ bytes: ArraySlice<UInt8>, source: UInt8) -> UInt8 {
        bytes.reduce(display ^ source, ^)
    }
}
