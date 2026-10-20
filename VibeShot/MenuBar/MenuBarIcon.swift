import AppKit

/// Monochrome template glyph for the status item, matching the Vibe app icon
/// (viewfinder corners + bolt). See VIBE_ICON_STYLE.md, section "Menu bar".
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()

            let corners = NSBezierPath()
            corners.lineWidth = 1.7
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            let a: CGFloat = 2, b: CGFloat = 16, arm: CGFloat = 4.2, r: CGFloat = 2
            for (x, y, dx, dy) in [(a, a, 1.0, 1.0), (b, a, -1.0, 1.0), (a, b, 1.0, -1.0), (b, b, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                corners.move(to: NSPoint(x: x, y: y + dy * arm))
                corners.appendArc(from: NSPoint(x: x, y: y), to: NSPoint(x: x + dx * arm, y: y), radius: r)
                corners.line(to: NSPoint(x: x + dx * arm, y: y))
            }
            corners.stroke()

            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 10.0, y: 4.2))
            bolt.line(to: NSPoint(x: 6.0, y: 9.8))
            bolt.line(to: NSPoint(x: 8.8, y: 9.8))
            bolt.line(to: NSPoint(x: 8.0, y: 13.8))
            bolt.line(to: NSPoint(x: 12.0, y: 8.2))
            bolt.line(to: NSPoint(x: 9.2, y: 8.2))
            bolt.close()
            bolt.lineJoinStyle = .round
            bolt.lineWidth = 0.6
            bolt.fill()
            bolt.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VibeShot"
        return image
    }
}
