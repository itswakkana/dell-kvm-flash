import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = MonitorStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render"),
           CommandLine.arguments.count > index + 1 {
            SelfTest.render(
                to: CommandLine.arguments[index + 1],
                settings: CommandLine.arguments.contains("--settings")
            )
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusIcon.make()
            button.setAccessibilityLabel("Dell KVM")
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover = NSPopover()
        // .transient closes itself when the app isn't active yet, which forces a delayed show
        // (and the status icon visibly un-highlights in between). Close on resign instead.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(appResignedActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        let controller = PopoverController(store: store)
        controller.onContentSizeChange = { [weak self] size in self?.popover.contentSize = size }
        // A successful switch or Escape closes the panel; the monitor is on the other machine by then.
        controller.onRequestClose = { [weak self] in self?.popover.performClose(nil) }
        popover.contentViewController = controller
        store.registerHotkeys()

        // `--show` / `--settings` open the panel on launch; handy for screenshots and manual testing.
        if CommandLine.arguments.contains("--settings") {
            (popover.contentViewController as? PopoverController)?.startInSettings()
        }
        if CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
    }

    private var pendingShow = false

    private func showPopover() {
        guard let button = statusItem.button else { return }
        (popover.contentViewController as? PopoverController)?.prepareForDisplay()
        // Keep the icon highlighted during activation so it doesn't blink off and on.
        button.highlight(true)
        if NSApp.isActive {
            presentPopover()
        } else {
            pendingShow = true
            NSApp.activate(ignoringOtherApps: true)
            // Fallback in case the activation notification never arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.pendingShow else { return }
                self.presentPopover()
            }
        }
    }

    private func presentPopover() {
        guard let button = statusItem.button else { return }
        pendingShow = false
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if pendingShow { presentPopover() }
    }

    @objc private func appResignedActive() {
        pendingShow = false
        statusItem.button?.highlight(false)
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        // Don't leave the key recorder swallowing keystrokes after the panel closes.
        (popover.contentViewController as? PopoverController)?.cancelRecording()
        statusItem.button?.highlight(false)
    }

    @objc private func togglePopover() {
        guard statusItem.button != nil else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }
}
