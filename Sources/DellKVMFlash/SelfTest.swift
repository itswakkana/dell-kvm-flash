import AppKit
import Carbon.HIToolbox
import Foundation

/// `--selftest` prints the DDC, USB, config and hotkey paths the popover can't prove, then exits.
enum SelfTest {
    static func run() {
        print("display: \(DDC.displayName() ?? "nil")")
        print("input:   \(DDC.currentInput().map(String.init) ?? "nil")")
        print("bright:  \(DDC.luminance().map(String.init) ?? "nil")")
        print("usb:     \(USBDevices.connected().map(\.name).joined(separator: ", "))")

        let config = Config.default
        let decoded = try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        print("config:  \(decoded == config ? "round-trip ok" : "FAILED")")

        // Cycle hotkey: visible ports only, wrapping past greyed ones, unknown input starts at the first.
        let store = MonitorStore()
        store.config.inputs = [
            InputPort(code: 15, name: "DP1"), InputPort(code: 16, name: "DP2"),
            InputPort(code: 17, name: "HDMI1"), InputPort(code: 18, name: "HDMI2", visible: false),
        ]
        let steps = [15: 16, 16: 17, 17: 15, 99: 15] // 18 is greyed, so 17 wraps to 15
        let cycleOK = steps.allSatisfy { current, next in
            store.currentInput = current
            return store.nextPort?.code == next
        }
        print("cycle:   \(cycleOK ? "ok" : "FAILED")")

        var fired = false
        // ⌃⌥F19: unlikely to be taken, so an empty result means registration itself is broken.
        let ids = HotkeyCenter.shared.register([
            HotkeyBinding(keyCode: 80, modifiers: UInt(controlKey) | UInt(optionKey)) { fired = true }
        ])
        print("hotkey:  \(ids.count)/1 registered")
        deliver(ids.first)
        print("fire:    \(fired ? "handler ran" : "handler did NOT run")")
    }

    /// `--render <png> [--settings]` draws the panel offscreen: layout can be checked, and
    /// README screenshots taken, without a display.
    static func render(to path: String, settings: Bool) {
        let store = MonitorStore()
        store.refresh {
            // `--sample-usb` fakes the USB section so its icons can be checked without the hardware.
            if CommandLine.arguments.contains("--sample-usb") {
                store.usbDevices = [
                    USBDevice(id: "sample-1", name: "MX Keys", kind: .keyboard),
                    USBDevice(id: "sample-2", name: "MX Master 3S", kind: .mouse),
                ]
            }
            // `--sample-config` fixes ports and hotkeys so README screenshots show no real machine setup.
            if CommandLine.arguments.contains("--sample-config") {
                let cmdOption = UInt(cmdKey) | UInt(optionKey)
                store.config.inputs = [
                    InputPort(code: 15, name: "DisplayPort 1",
                              hotkey: Hotkey(keyCode: 18, modifiers: cmdOption, label: "⌘⌥1")),
                    InputPort(code: 16, name: "DisplayPort 2",
                              hotkey: Hotkey(keyCode: 19, modifiers: cmdOption, label: "⌘⌥2")),
                    InputPort(code: 17, name: "HDMI 1"),
                    InputPort(code: 18, name: "HDMI 2", visible: false),
                    InputPort(code: 25, name: "Thunderbolt 4 (USB-C)"),
                ]
                store.config.hideUnavailable = false
                store.config.cycleHotkey = Hotkey(
                    keyCode: 45, modifiers: UInt(controlKey) | UInt(optionKey), label: "⌃⌥N"
                )
            }
            // `--sample-hidden` greys the second port: the render then also proves greyed ports sink.
            if CommandLine.arguments.contains("--sample-hidden"), store.config.inputs.count > 1 {
                store.config.inputs[1].visible = false
            }
            if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            let controller = PopoverController(store: store)
            if settings { controller.startInSettings() }
            _ = controller.view // triggers loadView
            controller.rebuild()

            let size = controller.preferredContentSize
            let view = controller.view
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()

            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { exit(1) }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
            if let context = NSGraphicsContext.current {
                view.displayIgnoringOpacity(view.bounds, in: context)
            }
            NSGraphicsContext.restoreGraphicsState()

            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("rendered \(path) at \(Int(size.width))x\(Int(size.height))")
            exit(0)
        }
    }

    /// Send the event Carbon itself sends on a hotkey press, so the handler is exercised
    /// without switching the monitor.
    private static func deliver(_ id: UInt32?) {
        guard let id else { return }
        var event: EventRef?
        guard CreateEvent(
            nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
            EventAttributes(kEventAttributeNone), &event
        ) == noErr, let event else { return }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: OSType(0x444B4D46), id: id)
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &hotKeyID
        )
        SendEventToEventTarget(event, GetApplicationEventTarget())
    }
}
