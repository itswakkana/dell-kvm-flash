import AppKit
import Foundation

final class MonitorStore {
    var displayName = "正在读取…"
    var screenInfo = ""
    var isRefreshing = false
    var currentInput: Int?
    var ddcAvailable = true
    var usbDevices: [USBDevice] = []
    var config = Config.load()
    var lastError: String?
    var hotkeyWarning: String?
    var onUpdate: (() -> Void)?

    var currentPort: InputPort? { config.inputs.first { $0.code == currentInput } }
    var currentIsUnlisted: Bool { currentInput != nil && currentPort == nil }

    /// Ports with signal first, config order inside each group: switching never moves a row, only
    /// changing a port's 有信号 mark does.
    var orderedInputs: [InputPort] { config.inputs.filter(\.visible) + config.inputs.filter { !$0.visible } }

    /// What the panel lists: `orderedInputs`, minus the greyed ports when the user asked to hide them.
    var listedInputs: [InputPort] {
        let ordered = orderedInputs
        guard config.hideUnavailable else { return ordered }
        let withSignal = ordered.filter(\.visible)
        // Hiding every port would leave nothing to click, so show them all instead.
        return withSignal.isEmpty ? ordered : withSignal
    }

    /// DDC writes block ~50ms each while the panel digests them, so they run off the main thread.
    func refresh(completion: (() -> Void)? = nil) {
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let available = DDC.isAvailable
            let input = DDC.currentInput()
            let luminance = DDC.luminance()
            let usb = USBDevices.connected()
            DispatchQueue.main.async {
                guard let self else { return }
                // NSScreen is main-thread only.
                let name = DDC.displayName() ?? (available ? "未检测到显示器" : "未找到可控制的外接显示器")
                self.displayName = name
                // Keep the last known input when the monitor is unreachable (KVM on the other machine).
                self.currentInput = input ?? self.currentInput
                self.ddcAvailable = available
                self.lastError = !available
                    ? "DDC 不可用：未找到通过 USB-C/雷雳连接的外接显示器"
                    : (self.currentInput == nil ? "无法通过 DDC 读取显示器" : nil)
                self.screenInfo = Self.screenInfo(matching: name, luminance: luminance)
                self.usbDevices = usb
                self.isRefreshing = false
                completion?()
            }
        }
    }

    /// The port the cycle hotkey picks next: the next one with signal, wrapping. An unknown current
    /// input (or one that is greyed) starts the walk at the first port.
    var nextPort: InputPort? {
        let ports = orderedInputs.filter(\.visible)
        guard !ports.isEmpty else { return nil }
        let index = ports.firstIndex { $0.code == currentInput }
        return ports[((index ?? -1) + 1) % ports.count]
    }

    func selectNext() {
        if let next = nextPort { select(next) }
    }

    func select(_ port: InputPort, completion: ((Bool) -> Void)? = nil) {
        guard port.code != currentInput else { return }
        guard ddcAvailable else {
            lastError = "DDC 不可用：未找到通过 USB-C/雷雳连接的外接显示器"
            onUpdate?()
            completion?(false)
            return
        }
        // Optimistic: the cycle hotkey reads currentInput, so it must see the new port before the
        // monitor confirms it — otherwise a quick second press re-sends the same input.
        let previous = currentInput
        currentInput = port.code
        isRefreshing = true
        lastError = nil
        onUpdate?() // spinner right away: the monitor takes a moment to report the new input
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = DDC.setInput(port.code)
            DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.2 : 0)) {
                guard let self else { return }
                guard ok else {
                    self.currentInput = previous
                    self.isRefreshing = false
                    self.lastError = "切换到 \(port.name) 失败（DDC 无响应）"
                    self.onUpdate?()
                    completion?(false)
                    return
                }
                // The monitor needs a moment before the new input is reported back.
                self.refresh {
                    self.onUpdate?()
                    completion?(true)
                }
            }
        }
    }

    func saveConfig() {
        config.save()
    }

    func registerHotkeys() {
        var bindings = config.inputs.filter(\.visible).compactMap { port -> HotkeyBinding? in
            guard let hotkey = port.hotkey else { return nil }
            return HotkeyBinding(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers) { [weak self] in
                self?.select(port)
            }
        }
        if let hotkey = config.cycleHotkey {
            bindings.append(HotkeyBinding(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers) { [weak self] in
                self?.selectNext()
            })
        }
        // A combo another app owns fails silently otherwise.
        let warning = HotkeyCenter.shared.register(bindings).count < bindings.count
            ? "有热键被其他应用占用，未能生效" : nil
        guard warning != hotkeyWarning else { return }
        hotkeyWarning = warning
        onUpdate?()
    }

    private static func screenInfo(matching name: String, luminance: Int?) -> String {
        // Never fall back to NSScreen.main: another display's resolution under this monitor's name is a lie.
        guard let screen = NSScreen.screens.first(where: { $0.localizedName == name }) else {
            return luminance.map { "亮度 \($0)" } ?? ""
        }
        // Logical points, not physical pixels: a 5K panel scaled to 2560×1440 reads as "2560×1440 HiDPI".
        var parts = ["\(Int(screen.frame.width))×\(Int(screen.frame.height))"]
        if screen.backingScaleFactor >= 2 { parts.append("HiDPI") }
        if screen.maximumFramesPerSecond > 0 { parts.append("\(screen.maximumFramesPerSecond)Hz") }
        if let luminance { parts.append("亮度 \(luminance)") }
        return parts.joined(separator: " · ")
    }
}
