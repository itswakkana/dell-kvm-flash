import AppKit

/// Menu bar icon: a display outline with a "D" on the screen. AppKit has no SVG renderer, so the same
/// shapes are built with NSBezierPath and drawn as a template image that tints with the menu bar.
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let screen = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 4.25, width: 15, height: 11.75), xRadius: 2.5, yRadius: 2.5
            )
            screen.lineWidth = 1.5
            screen.stroke()

            NSBezierPath(rect: NSRect(x: 8.25, y: 3, width: 1.5, height: 1.25)).fill()
            NSBezierPath(roundedRect: NSRect(x: 5.5, y: 1.5, width: 7, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()

            // "D": stem + bowl, the counter punched out by the even-odd rule.
            // Each subpath runs bottom → right → top → left, so the arc continues where the line ends.
            let d = NSBezierPath()
            d.move(to: NSPoint(x: 5.75, y: 6.25))
            d.line(to: NSPoint(x: 8.5, y: 6.25))
            d.appendArc(withCenter: NSPoint(x: 8.5, y: 10), radius: 3.75, startAngle: -90, endAngle: 90, clockwise: false)
            d.line(to: NSPoint(x: 5.75, y: 13.75))
            d.close()
            d.move(to: NSPoint(x: 7.75, y: 8.1))
            d.line(to: NSPoint(x: 8.5, y: 8.1))
            d.appendArc(withCenter: NSPoint(x: 8.5, y: 10), radius: 1.9, startAngle: -90, endAngle: 90, clockwise: false)
            d.line(to: NSPoint(x: 7.75, y: 11.9))
            d.close()
            d.windingRule = .evenOdd
            d.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
