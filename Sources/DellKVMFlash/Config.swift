import Foundation

struct InputPort: Codable, Identifiable, Equatable {
    var code: Int
    var name: String
    var visible: Bool = true
    var hotkey: Hotkey?

    var id: Int { code }
}

struct Config: Codable, Equatable {
    var inputs: [InputPort]
    /// Main panel lists only the ports marked 有信号.
    var hideUnavailable = false
    /// One combo that steps to the next port with signal; with two ports that is a toggle.
    var cycleHotkey: Hotkey?

    init(inputs: [InputPort], hideUnavailable: Bool = false, cycleHotkey: Hotkey? = nil) {
        self.inputs = inputs
        self.hideUnavailable = hideUnavailable
        self.cycleHotkey = cycleHotkey
    }

    // A config written before these keys existed must keep its ports, so a missing key defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputs = try container.decode([InputPort].self, forKey: .inputs)
        hideUnavailable = try container.decodeIfPresent(Bool.self, forKey: .hideUnavailable) ?? false
        cycleHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .cycleHotkey)
    }

    static let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DellKVMFlash/config.json")

    static let `default` = Config(inputs: [
        InputPort(code: 15, name: "DisplayPort 1"),
        InputPort(code: 16, name: "DisplayPort 2"),
        InputPort(code: 17, name: "HDMI 1"),
        InputPort(code: 18, name: "HDMI 2"),
        InputPort(code: 25, name: "Thunderbolt 4 (USB-C)"), // U2725QE reports 25 here, not the usual 27
    ])

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return .default }
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else {
            // Keep an unreadable file aside: the next save would otherwise overwrite hand-edited ports.
            let backup = url.appendingPathExtension("broken")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return .default
        }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Config.url)
    }
}
