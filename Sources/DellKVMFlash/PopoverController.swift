import AppKit

/// Borderless row with an animated hover/press background so clicks feel responsive.
final class HoverRowButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var hovering = false
    /// Shows state but takes no click (the current input) — and must not be dimmed like a disabled control.
    var isStatic = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateBackground() }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateBackground(pressed: flag)
    }

    private func updateBackground(pressed: Bool = false) {
        let alpha: CGFloat = (!isEnabled || isStatic) ? 0 : (pressed ? 0.18 : (hovering ? 0.08 : 0))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
        }
    }
}

/// An NSPopover has no Escape handling of its own; this view sits in the responder chain.
final class PopoverView: NSView {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class PopoverController: NSViewController, NSTextFieldDelegate {
    private let store: MonitorStore
    private var showingSettings = false
    private var nameFields: [NSTextField] = []
    private var codeFields: [NSTextField] = []
    private var visibleBoxes: [NSButton] = []
    private enum Recording: Equatable { case port(Int), cycle }
    private var recording: Recording?
    private var keyMonitor: Any?
    private var lastSnapshot = ""
    private var spinner: NSProgressIndicator?
    /// One width for both pages: the panel must not jump when you open settings.
    private let panelWidth: CGFloat = 360
    private var contentWidth: CGFloat { panelWidth - 24 }
    /// NSPopover does not follow preferredContentSize while it is on screen; the owner resizes it.
    var onContentSizeChange: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?

    init(store: MonitorStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        store.onUpdate = { [weak self] in self?.rebuild() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = PopoverView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 100))
        root.onCancel = { [weak self] in self?.escapePressed() }
        view = root
    }

    private func escapePressed() {
        if recording != nil { cancelRecording() }
        else if showingSettings { closeSettings() }
        else { onRequestClose?() }
    }

    func startInSettings() {
        showingSettings = true
    }

    /// Paint immediately from cached state, then refresh in the background.
    func prepareForDisplay() {
        let inputBefore = store.currentInput
        store.refresh { [weak self] in
            guard let self else { return }
            // Settings holds live text fields: only redraw when the detected input actually changed.
            if self.showingSettings {
                if self.store.currentInput != inputBefore { self.rebuild() }
                return
            }
            if self.snapshot() != self.lastSnapshot {
                self.rebuild()
            } else {
                self.spinner?.stopAnimation(nil)
                self.spinner?.isHidden = true
            }
        }
        // refresh() already flagged itself, so this paint shows the cached values with the spinner running.
        rebuild()
    }

    private func snapshot() -> String {
        let ports = store.orderedInputs.map { "\($0.code):\($0.name):\($0.visible):\($0.hotkey?.label ?? "")" }
        // Error and warning text is part of the snapshot: a read that starts failing changes nothing
        // else, and the panel would otherwise keep showing the old (or no) message.
        return ([store.displayName, store.screenInfo, String(store.currentInput ?? -1),
                 String(store.config.hideUnavailable), store.lastError ?? "", store.hotkeyWarning ?? ""]
            + ports + store.usbDevices.map(\.name)).joined(separator: "|")
    }

    func rebuild() {
        nameFields = []
        codeFields = []
        visibleBoxes = []

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if showingSettings {
            buildSettings(into: stack)
        } else {
            buildMain(into: stack)
        }

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

        // The popover owns the view's frame; setting it here shifts the content off its left edge.
        if view.window == nil {
            view.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 100)
        }
        view.layoutSubtreeIfNeeded()
        let height = max(80, stack.fittingSize.height + 24) // stack is inset 12pt top and bottom
        let size = NSSize(width: panelWidth, height: height)
        preferredContentSize = size
        onContentSizeChange?(size)
        lastSnapshot = snapshot()

        if view.window?.isVisible == true {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                view.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Main panel

    private func buildMain(into stack: NSStackView) {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .top
        let title = NSStackView()
        title.orientation = .vertical
        title.alignment = .leading
        title.spacing = 2
        title.addArrangedSubview(label(store.displayName, size: 13, weight: .semibold))
        title.addArrangedSubview(label(store.screenInfo, size: 11, color: .secondaryLabelColor))
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        let gear = iconButton("gearshape", label: "配置端口", action: #selector(openSettings))
        header.addArrangedSubview(gear)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        stack.addArrangedSubview(divider())
        let inputsHeader = NSStackView()
        inputsHeader.orientation = .horizontal
        inputsHeader.spacing = 6
        inputsHeader.addArrangedSubview(sectionLabel("输入源"))
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
        if store.isRefreshing { spinner.startAnimation(nil) } else { spinner.isHidden = true }
        inputsHeader.addArrangedSubview(spinner)
        self.spinner = spinner
        stack.addArrangedSubview(inputsHeader)

        // A current input that isn't configured still leads the list: it is what you're looking at.
        if store.currentIsUnlisted, let code = store.currentInput {
            addListRow(inputRow(InputPort(code: code, name: "输入 \(code)（未配置）"), isCurrent: true, enabled: true), to: stack)
        }
        for port in store.listedInputs {
            addListRow(
                inputRow(
                    port, isCurrent: port.code == store.currentInput,
                    enabled: port.visible && store.ddcAvailable
                ),
                to: stack
            )
        }
        if let error = store.lastError {
            stack.addArrangedSubview(label(error, size: 11, color: .systemRed))
        }
        if let warning = store.hotkeyWarning {
            stack.addArrangedSubview(label(warning, size: 11, color: .systemRed))
        }

        stack.addArrangedSubview(divider())
        stack.addArrangedSubview(sectionLabel("USB 键鼠（本机可见）"))
        if store.usbDevices.isEmpty {
            stack.addArrangedSubview(label("本机未看到 USB 键鼠（KVM 可能切到了另一台）", size: 11, color: .secondaryLabelColor))
        } else {
            for device in store.usbDevices {
                addListRow(usbRow(device), to: stack)
            }
        }

        stack.addArrangedSubview(divider())
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.addArrangedSubview(linkButton("刷新", action: #selector(refreshClicked)))
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(linkButton("退出", action: #selector(quitClicked)))
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    }

    /// List rows sit closer together than the sections above and below them.
    private func addListRow(_ row: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(2, after: row)
    }

    /// Fixed tab stops: icon and name in one column, hotkeys right-aligned like a menu's key equivalent.
    /// No indent, so the icon column starts on the same edge as the title and the section headers.
    private var listStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: 16),
            NSTextTab(textAlignment: .right, location: contentWidth - 4),
        ]
        return style
    }

    private func listText(icon: String, iconColor: NSColor, name: String, nameColor: NSColor) -> NSMutableAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let text = NSMutableAttributedString(
            string: "\(icon)\t", attributes: [.font: font, .foregroundColor: iconColor, .paragraphStyle: listStyle]
        )
        text.append(NSAttributedString(
            string: name, attributes: [.font: font, .foregroundColor: nameColor, .paragraphStyle: listStyle]
        ))
        return text
    }

    private func inputRow(_ port: InputPort, isCurrent: Bool, enabled: Bool) -> NSView {
        let row = HoverRowButton(title: "", target: self, action: #selector(inputClicked(_:)))
        row.tag = port.code
        row.isBordered = false
        row.alignment = .left
        row.isEnabled = enabled
        row.isStatic = isCurrent // the current row is a label, not an action
        row.setAccessibilityRole(isCurrent ? .staticText : .button)
        row.setAccessibilityLabel(port.name)
        row.setAccessibilityValue(
            [isCurrent ? "当前" : nil, port.hotkey?.label].compactMap { $0 }.joined(separator: "，")
        )
        let iconColor: NSColor = !enabled ? .tertiaryLabelColor : (isCurrent ? .controlAccentColor : .secondaryLabelColor)
        let nameColor: NSColor = !enabled ? .tertiaryLabelColor : (isCurrent ? .controlAccentColor : .labelColor)
        let text = listText(icon: isCurrent ? "●" : "○", iconColor: iconColor, name: port.name, nameColor: nameColor)
        let trailing = [port.hotkey?.label, isCurrent ? "当前" : nil].compactMap { $0 }.joined(separator: "   ")
        if !trailing.isEmpty {
            let trailingColor: NSColor = !enabled ? .tertiaryLabelColor : (isCurrent ? .controlAccentColor : .secondaryLabelColor)
            text.append(NSAttributedString(string: "\t\(trailing)", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: trailingColor, .paragraphStyle: listStyle,
            ]))
        }
        row.attributedTitle = text
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return row
    }

    private func usbRow(_ device: USBDevice) -> NSView {
        let field = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString()
        text.append(symbolText(device.kind.symbol))
        text.append(NSAttributedString(string: "\t\(device.name)", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: listStyle,
        ]))
        field.attributedStringValue = text
        field.setAccessibilityLabel(device.name)
        field.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        field.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return field
    }

    /// An SF Symbol drawn as a text attachment, so it lands in the same 20pt column as the input dots.
    private func symbolText(_ name: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return NSAttributedString(string: "•")
        }
        let box = NSSize(width: 12, height: 12)
        let tinted = NSImage(size: box, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = tinted
        attachment.bounds = CGRect(x: 0, y: -2, width: box.width, height: box.height)
        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Settings

    private func buildSettings(into stack: NSStackView) {
        let header = NSStackView()
        header.orientation = .horizontal
        header.addArrangedSubview(iconButton("chevron.left", label: "返回", action: #selector(closeSettings)))
        header.addArrangedSubview(label("端口配置", size: 13, weight: .semibold))
        header.addArrangedSubview(NSView())
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.spacing = 6
        columns.addArrangedSubview(columnLabel("名称", width: 140))
        columns.addArrangedSubview(columnLabel("DDC 编号", width: 48))
        columns.addArrangedSubview(columnLabel("热键", width: 84))
        columns.addArrangedSubview(columnLabel("有信号", width: 0))
        columns.addArrangedSubview(columnLabel("删除", width: 24))
        stack.addArrangedSubview(columns)

        for (index, port) in store.config.inputs.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6

            let name = NSTextField(string: port.name)
            name.delegate = self
            name.font = .systemFont(ofSize: 12)
            name.widthAnchor.constraint(equalToConstant: 140).isActive = true
            nameFields.append(name)

            let code = NSTextField(string: String(port.code))
            code.delegate = self
            code.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            code.widthAnchor.constraint(equalToConstant: 48).isActive = true
            codeFields.append(code)

            let hotkeyButton = NSButton(
                title: recording == .port(index) ? "按下…" : (port.hotkey?.label ?? "无"),
                target: self, action: #selector(hotkeyClicked(_:))
            )
            hotkeyButton.tag = index
            hotkeyButton.bezelStyle = .rounded
            hotkeyButton.font = .systemFont(ofSize: 11)
            hotkeyButton.widthAnchor.constraint(equalToConstant: 84).isActive = true
            hotkeyButton.toolTip = "点击后按下组合键；Delete 清除，Esc 取消"

            let visible = NSButton(checkboxWithTitle: "", target: self, action: #selector(configChanged))
            visible.state = port.visible ? .on : .off
            visible.setAccessibilityLabel("\(port.name) 有信号")
            visibleBoxes.append(visible)

            let remove = NSButton(
                image: NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")!,
                target: self, action: #selector(removePort(_:))
            )
            remove.tag = index
            remove.isBordered = false
            remove.contentTintColor = .secondaryLabelColor
            remove.widthAnchor.constraint(equalToConstant: 24).isActive = true
            remove.setAccessibilityLabel("删除 \(port.name)")
            remove.toolTip = "删除这个端口"
            remove.isEnabled = store.config.inputs.count > 1

            row.addArrangedSubview(name)
            row.addArrangedSubview(code)
            row.addArrangedSubview(hotkeyButton)
            row.addArrangedSubview(visible)
            row.addArrangedSubview(remove)
            stack.addArrangedSubview(row)
        }

        let add = linkButton("＋添加端口", action: #selector(addPort))
        stack.addArrangedSubview(add)

        // This table always lists every port; the switch only trims the main panel.
        let hide = NSButton(
            checkboxWithTitle: "隐藏无信号输入源", target: self, action: #selector(hideUnavailableToggled(_:))
        )
        hide.state = store.config.hideUnavailable ? .on : .off
        hide.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(hide)

        // Global: steps through the ports with signal, so two machines become one toggle.
        let cycle = NSStackView()
        cycle.orientation = .horizontal
        cycle.spacing = 6
        cycle.addArrangedSubview(label("下一个输入源", size: 11, color: .secondaryLabelColor))
        let cycleButton = NSButton(
            title: recording == .cycle ? "按下…" : (store.config.cycleHotkey?.label ?? "无"),
            target: self, action: #selector(cycleHotkeyClicked)
        )
        cycleButton.bezelStyle = .rounded
        cycleButton.font = .systemFont(ofSize: 11)
        cycleButton.widthAnchor.constraint(equalToConstant: 84).isActive = true
        cycleButton.toolTip = "点击后按下组合键；Delete 清除，Esc 取消"
        cycle.addArrangedSubview(cycleButton)
        stack.addArrangedSubview(cycle)

        if let code = store.currentInput {
            stack.addArrangedSubview(label("当前检测到的输入编号：\(code)", size: 11, color: .secondaryLabelColor))
        }
        if let warning = store.hotkeyWarning {
            stack.addArrangedSubview(label(warning, size: 11, color: .systemRed))
        }
        stack.addArrangedSubview(hint("「有信号」需手动标记：不勾选会置灰、点不动。"))
        stack.addArrangedSubview(hint("热键全局生效；编号填错时切不到目标端口，切回其他端口即可。"))
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !nameFields.isEmpty else { return }
        // A red field means "not a port code"; nothing is saved until every code is 0–255.
        var allValid = true
        for field in codeFields {
            let valid = Int(field.stringValue).map { (0...255).contains($0) } ?? false
            field.textColor = valid ? .labelColor : .systemRed
            allValid = allValid && valid
        }
        guard allValid else { return }
        collectConfig()
        store.saveConfig()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        // Typing into a field ends hotkey recording, so keystrokes aren't swallowed as a combo.
        cancelRecording()
    }

    private func collectConfig() {
        store.config.inputs = nameFields.indices.map { index in
            var port = store.config.inputs[index]
            port.code = Int(codeFields[index].stringValue) ?? port.code // keep the old code while the field is mid-edit
            port.name = nameFields[index].stringValue
            port.visible = visibleBoxes[index].state == .on
            return port
        }
    }

    // MARK: - Hotkey recording

    @objc private func hotkeyClicked(_ sender: NSButton) {
        beginRecording(.port(sender.tag))
    }

    @objc private func cycleHotkeyClicked() {
        beginRecording(.cycle)
    }

    private func beginRecording(_ target: Recording) {
        stopRecording(rebuild: false)
        recording = target
        rebuild()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleRecorded(event)
            return nil
        }
    }

    private func handleRecorded(_ event: NSEvent) {
        guard let recording else { return }
        if event.keyCode == 53 { stopRecording(); return } // Esc cancels
        if event.keyCode == 51 || event.keyCode == 117 { // Delete clears
            apply(hotkey: nil, to: recording)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { return } // wait for a real combo
        apply(hotkey: Hotkey(
            keyCode: Int(event.keyCode),
            modifiers: Hotkey.carbonModifiers(flags),
            label: Hotkey.label(for: event)
        ), to: recording)
    }

    private func apply(hotkey: Hotkey?, to recording: Recording) {
        switch recording {
        case .port(let index):
            guard store.config.inputs.indices.contains(index) else { return }
            store.config.inputs[index].hotkey = hotkey
        case .cycle:
            store.config.cycleHotkey = hotkey
        }
        commitHotkey()
    }

    private func commitHotkey() {
        store.saveConfig()
        store.registerHotkeys()
        stopRecording()
    }

    func cancelRecording() {
        stopRecording(rebuild: false)
    }

    private func stopRecording(rebuild shouldRebuild: Bool = true) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = nil
        if shouldRebuild { rebuild() }
    }

    // MARK: - Actions

    @objc private func inputClicked(_ sender: NSButton) {
        guard let port = store.config.inputs.first(where: { $0.code == sender.tag }) else { return }
        store.select(port) { [weak self] ok in
            guard let self, ok else { return } // failure keeps the panel open with the error
            NSAccessibility.post(element: self.view, notification: .announcementRequested, userInfo: [
                .announcement: "已切换到 \(port.name)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
            self.onRequestClose?()
        }
    }

    @objc private func refreshClicked() { prepareForDisplay() }
    @objc private func quitClicked() { NSApp.terminate(nil) }
    @objc private func openSettings() { showingSettings = true; rebuild() }
    // Leaving the page must also drop the key monitor, or the main panel keeps eating keystrokes.
    @objc private func closeSettings() { cancelRecording(); showingSettings = false; rebuild() }

    @objc private func configChanged() {
        collectConfig()
        store.saveConfig()
        store.registerHotkeys()
    }

    @objc private func hideUnavailableToggled(_ sender: NSButton) {
        store.config.hideUnavailable = sender.state == .on
        store.saveConfig()
    }

    @objc private func addPort() {
        cancelRecording()
        collectConfig()
        let used = Set(store.config.inputs.map(\.code))
        let code = [27, 19, 20, 21, 22, 23, 24].first { !used.contains($0) } ?? 27
        store.config.inputs.append(InputPort(code: code, name: "新端口"))
        store.saveConfig()
        store.registerHotkeys()
        rebuild()
    }

    @objc private func removePort(_ sender: NSButton) {
        cancelRecording()
        collectConfig()
        guard store.config.inputs.count > 1, store.config.inputs.indices.contains(sender.tag) else { return }
        store.config.inputs.remove(at: sender.tag)
        store.saveConfig()
        store.registerHotkeys()
        rebuild()
    }

    // MARK: - Small helpers

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Wrapping help text: long hints must wrap inside the panel instead of running off the edge.
    private func hint(_ text: String) -> NSTextField {
        let field = label(text, size: 11, color: .secondaryLabelColor)
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = contentWidth
        field.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return field
    }

    private func columnLabel(_ text: String, width: CGFloat) -> NSTextField {
        let field = label(text, size: 10, color: .secondaryLabelColor)
        if width > 0 { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return field
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = HoverRowButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    /// Section headers share the title's left edge, which is also where the row icons start.
    private func sectionLabel(_ text: String) -> NSTextField {
        label(text, size: 11, color: .secondaryLabelColor)
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }
}
