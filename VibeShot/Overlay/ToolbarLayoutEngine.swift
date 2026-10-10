import CoreGraphics
import Foundation

/// Geometry-only toolbar placement seam for the later annotation milestone. M3 does not create
/// annotation controls; keeping this reducer pure lets M4 add them without coupling AppKit panel
/// lifecycle to placement decisions.
struct ToolbarLayout: Equatable, Sendable {
    let verticalFrame: CGRect
    let horizontalFrame: CGRect

    var vertical: CGRect { verticalFrame }
    var horizontal: CGRect { horizontalFrame }
}

struct ToolbarLayoutEngine: Equatable, Sendable {
    var spacing: CGFloat = 12
    var edgeInset: CGFloat = 8

    init(spacing: CGFloat = 12, edgeInset: CGFloat = 8) {
        self.spacing = spacing.isFinite && spacing >= 0 ? spacing : 12
        self.edgeInset = edgeInset.isFinite && edgeInset >= 0 ? edgeInset : 8
    }

    func layout(
        selection: CGRect?,
        visibleFrame: CGRect,
        verticalSize: CGSize = CGSize(width: 42, height: 220),
        horizontalSize: CGSize = CGSize(width: 280, height: 42)
    ) -> ToolbarLayout {
        let visible = visibleFrame.standardized
        let vertical = placeVertical(
            selection: selection?.standardized,
            visible: visible,
            size: sanitized(verticalSize),
            spacing: spacing
        )
        let horizontal = placeHorizontal(
            selection: selection?.standardized,
            visible: visible,
            size: sanitized(horizontalSize),
            spacing: spacing
        )
        return ToolbarLayout(verticalFrame: vertical, horizontalFrame: horizontal)
    }

    /// A local-coordinate convenience for overlay callers that already have a display-local
    /// visible frame.
    func frames(
        around selection: CGRect?,
        in visibleFrame: CGRect,
        verticalSize: CGSize = CGSize(width: 42, height: 220),
        horizontalSize: CGSize = CGSize(width: 280, height: 42)
    ) -> ToolbarLayout {
        layout(selection: selection, visibleFrame: visibleFrame, verticalSize: verticalSize, horizontalSize: horizontalSize)
    }

    private func placeVertical(selection: CGRect?, visible: CGRect, size: CGSize, spacing: CGFloat) -> CGRect {
        let candidates: [CGRect]
        if let selection {
            candidates = [
                CGRect(x: selection.maxX + spacing, y: selection.midY - size.height / 2, width: size.width, height: size.height),
                CGRect(x: selection.minX - spacing - size.width, y: selection.midY - size.height / 2, width: size.width, height: size.height)
            ]
        } else {
            candidates = [
                CGRect(x: visible.maxX - edgeInset - size.width, y: visible.midY - size.height / 2, width: size.width, height: size.height)
            ]
        }
        let candidate = candidates.first(where: { visible.contains($0) }) ?? candidates[0]
        return clamped(candidate, to: visible)
    }

    private func placeHorizontal(selection: CGRect?, visible: CGRect, size: CGSize, spacing: CGFloat) -> CGRect {
        let candidates: [CGRect]
        if let selection {
            candidates = [
                CGRect(x: selection.midX - size.width / 2, y: selection.minY - spacing - size.height, width: size.width, height: size.height),
                CGRect(x: selection.midX - size.width / 2, y: selection.maxY + spacing, width: size.width, height: size.height)
            ]
        } else {
            candidates = [
                CGRect(x: visible.midX - size.width / 2, y: visible.minY + edgeInset, width: size.width, height: size.height)
            ]
        }
        let candidate = candidates.first(where: { visible.contains($0) }) ?? candidates[0]
        return clamped(candidate, to: visible)
    }

    private func sanitized(_ size: CGSize) -> CGSize {
        CGSize(width: max(0, size.width.isFinite ? size.width : 0), height: max(0, size.height.isFinite ? size.height : 0))
    }

    private func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
