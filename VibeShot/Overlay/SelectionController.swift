import CoreGraphics
import Foundation

/// The eight resize handles used by the M3 selection boundary. The names describe AppKit's
/// lower-left, y-up coordinate space, so `top` has the greatest y value.
enum SelectionHandle: String, CaseIterable, Hashable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
        case .top, .right, .bottom, .left: return false
        }
    }
}

enum SelectionHit: Equatable, Sendable {
    case handle(SelectionHandle)
    case body
    case outside

    var handle: SelectionHandle? {
        guard case let .handle(value) = self else { return nil }
        return value
    }

    var isInside: Bool {
        switch self {
        case .handle, .body: return true
        case .outside: return false
        }
    }
}

/// Pure state and geometry reducer for one display-local selection.
///
/// It deliberately knows nothing about AppKit events or windows. Callers provide display-local
/// points in the display's lower-left/y-up coordinate space, and all resulting rectangles are
/// clamped to that display. This is the M3 product limitation: a drag cannot create a selection
/// spanning two displays, even though one overlay panel is shown for every captured display.
struct SelectionController: Equatable, Sendable {
    static let defaultMinimumSize: CGFloat = 8

    let displayBounds: CGRect
    let geometry: DisplayGeometry
    let minimumSize: CGFloat

    private(set) var selectionRect: CGRect?
    private var interaction: Interaction?

    private enum Interaction: Equatable, Sendable {
        case creating(start: CGPoint)
        case moving(anchor: CGPoint, original: CGRect)
        case resizing(handle: SelectionHandle, original: CGRect)
    }

    init(
        displayBounds: CGRect,
        geometry: DisplayGeometry,
        minimumSize: CGFloat = SelectionController.defaultMinimumSize
    ) {
        self.displayBounds = displayBounds.standardized
        self.geometry = geometry
        self.minimumSize = minimumSize.isFinite && minimumSize > 0 ? minimumSize : Self.defaultMinimumSize
        self.selectionRect = nil
        self.interaction = nil
    }

    init(
        descriptor: ScreenDescriptor,
        imageSize: PixelSize? = nil,
        minimumSize: CGFloat = SelectionController.defaultMinimumSize
    ) {
        self.init(
            displayBounds: CGRect(origin: .zero, size: descriptor.frame.rect.size),
            geometry: DisplayGeometry(descriptor: descriptor, imageSize: imageSize),
            minimumSize: minimumSize
        )
    }

    /// The current display-local selection, if one exists.
    var selection: DisplayLocalRect? {
        selectionRect.map(DisplayLocalRect.init)
    }

    /// Compatibility/readability aliases used by overlay callers and tests.
    var rect: CGRect? { selectionRect }
    var selectedRect: CGRect? { selectionRect }
    var isSelecting: Bool { interaction != nil }

    /// The current selection's native pixel dimensions, derived through DisplayGeometry rather
    /// than by multiplying points at the call site.
    var pixelDimensions: PixelSize? {
        guard let selectionRect else { return nil }
        let pixels = geometry.imagePixelRect(for: DisplayLocalRect(selectionRect))
        return PixelSize(width: pixels.width, height: pixels.height)
    }

    var pixelSize: PixelSize? { pixelDimensions }

    mutating func beginSelection(at point: CGPoint) {
        beginCreating(at: point)
    }

    /// Begin an interaction based on hit priority. Handles win over the selection body; a click
    /// outside an existing selection starts a fresh selection.
    @discardableResult
    mutating func begin(at point: CGPoint) -> SelectionHit {
        let clampedPoint = clamp(point)
        guard let current = selectionRect else {
            beginCreating(at: clampedPoint)
            return .outside
        }

        switch hitTest(point) {
        case let .handle(handle):
            interaction = .resizing(handle: handle, original: current)
            return .handle(handle)
        case .body:
            interaction = .moving(anchor: clampedPoint, original: current)
            return .body
        case .outside:
            beginCreating(at: clampedPoint)
            return .outside
        }
    }

    @discardableResult
    mutating func beginInteraction(at point: CGPoint) -> SelectionHit {
        begin(at: point)
    }

    mutating func update(to point: CGPoint) {
        guard let interaction else { return }
        switch interaction {
        case let .creating(start):
            selectionRect = createRect(from: start, to: point)
        case let .moving(anchor, original):
            let delta = CGPoint(x: point.x - anchor.x, y: point.y - anchor.y)
            selectionRect = movedRect(original, by: delta)
        case let .resizing(handle, original):
            selectionRect = resizedRect(original, handle: handle, to: point)
        }
    }

    mutating func updateSelection(to point: CGPoint) {
        update(to: point)
    }

    @discardableResult
    mutating func endInteraction() -> DisplayLocalRect? {
        interaction = nil
        return selection
    }

    @discardableResult
    mutating func end() -> DisplayLocalRect? {
        endInteraction()
    }

    mutating func cancelInteraction() {
        interaction = nil
    }

    mutating func clear() {
        interaction = nil
        selectionRect = nil
    }

    @discardableResult
    mutating func restoreSelection(_ rect: DisplayLocalRect) -> Bool {
        let candidate = rect.rect.standardized
        guard rect.isFinite, candidate.width > 0, candidate.height > 0,
              displayBounds.width > 0, displayBounds.height > 0 else { return false }
        let width = min(displayBounds.width, max(minimumSize, candidate.width))
        let height = min(displayBounds.height, max(minimumSize, candidate.height))
        let x = min(max(candidate.minX, displayBounds.minX), displayBounds.maxX - width)
        let y = min(max(candidate.minY, displayBounds.minY), displayBounds.maxY - height)
        selectionRect = CGRect(x: x, y: y, width: width, height: height)
        interaction = nil
        return true
    }

    /// Select the complete captured display. This is the Command+A behavior and the full-screen
    /// command's immediate selection path.
    mutating func selectAll() {
        interaction = nil
        selectionRect = displayBounds
    }

    mutating func selectFullDisplay() {
        selectAll()
    }

    mutating func commandA() {
        selectAll()
    }

    mutating func move(by delta: CGPoint) {
        guard let current = selectionRect else { return }
        selectionRect = movedRect(current, by: delta)
    }

    mutating func resize(handle: SelectionHandle, to point: CGPoint) {
        guard let current = selectionRect else { return }
        selectionRect = resizedRect(current, handle: handle, to: point)
    }

    /// Handle hit testing is intentionally performed before body testing. The default 8-point
    /// radius leaves a usable target while the explicit ordering keeps corners deterministic when
    /// a small selection makes hit areas overlap.
    func hitTest(_ point: CGPoint, handleHitRadius: CGFloat = 8) -> SelectionHit {
        guard let current = selectionRect else { return .outside }
        let radius = max(0, handleHitRadius.isFinite ? handleHitRadius : 8)
        let priority: [SelectionHandle] = [
            .topLeft, .topRight, .bottomRight, .bottomLeft,
            .top, .right, .bottom, .left
        ]
        for handle in priority {
            let center = handleCenter(handle, in: current)
            let hitRect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            if hitRect.contains(point) { return .handle(handle) }
        }
        return current.contains(point) ? .body : .outside
    }

    private mutating func beginCreating(at point: CGPoint) {
        let clampedPoint = clamp(point)
        interaction = .creating(start: clampedPoint)
        // Give the view a stable minimum-sized preview before the first drag event arrives.
        selectionRect = createRect(from: clampedPoint, to: clampedPoint)
    }

    private func createRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let clampedEnd = clamp(end)
        let x = axisForCreation(start: start.x, end: clampedEnd.x, lower: displayBounds.minX, upper: displayBounds.maxX)
        let y = axisForCreation(start: start.y, end: clampedEnd.y, lower: displayBounds.minY, upper: displayBounds.maxY)
        return CGRect(x: x.lowerBound, y: y.lowerBound, width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
    }

    private func resizedRect(_ original: CGRect, handle: SelectionHandle, to point: CGPoint) -> CGRect {
        let p = clamp(point)
        let x: ClosedRange<CGFloat>
        let y: ClosedRange<CGFloat>

        switch handle {
        case .left, .topLeft, .bottomLeft:
            x = axisForResize(moving: p.x, fixed: original.maxX)
        case .right, .topRight, .bottomRight:
            x = axisForResize(moving: p.x, fixed: original.minX)
        case .top, .bottom:
            x = original.minX...original.maxX
        }

        switch handle {
        case .bottom, .bottomLeft, .bottomRight:
            y = axisForResize(moving: p.y, fixed: original.maxY, lower: displayBounds.minY, upper: displayBounds.maxY)
        case .top, .topLeft, .topRight:
            y = axisForResize(moving: p.y, fixed: original.minY, lower: displayBounds.minY, upper: displayBounds.maxY)
        case .left, .right:
            y = original.minY...original.maxY
        }

        return CGRect(x: x.lowerBound, y: y.lowerBound, width: x.upperBound - x.lowerBound, height: y.upperBound - y.lowerBound)
    }

    private func movedRect(_ original: CGRect, by delta: CGPoint) -> CGRect {
        let width = min(original.width, displayBounds.width)
        let height = min(original.height, displayBounds.height)
        let x = clamp(origin: original.minX + delta.x, extent: width, lower: displayBounds.minX, upper: displayBounds.maxX)
        let y = clamp(origin: original.minY + delta.y, extent: height, lower: displayBounds.minY, upper: displayBounds.maxY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func axisForCreation(start: CGFloat, end: CGFloat, lower: CGFloat, upper: CGFloat) -> ClosedRange<CGFloat> {
        let minimum = min(minimumSize, max(0, upper - lower))
        let low = min(start, end)
        let high = max(start, end)
        guard high - low < minimum else {
            return clampRange(low...high, lower: lower, upper: upper)
        }

        let range: ClosedRange<CGFloat>
        if end >= start {
            range = start...(start + minimum)
        } else {
            range = (start - minimum)...start
        }
        return clampRange(range, lower: lower, upper: upper)
    }

    private func axisForResize(moving: CGFloat, fixed: CGFloat) -> ClosedRange<CGFloat> {
        let lower = displayBounds.minX
        let upper = displayBounds.maxX
        // The y-axis uses the same helper by translating the bounds at the call site below.
        // This overload is replaced for y by `axisForResize(moving:fixed:lower:upper:)`.
        return axisForResize(moving: moving, fixed: fixed, lower: lower, upper: upper)
    }

    private func axisForResize(moving: CGFloat, fixed: CGFloat, lower: CGFloat, upper: CGFloat) -> ClosedRange<CGFloat> {
        let minimum = min(minimumSize, max(0, upper - lower))
        var range = min(moving, fixed)...max(moving, fixed)
        if range.upperBound - range.lowerBound < minimum {
            if moving >= fixed {
                range = fixed...(fixed + minimum)
            } else {
                range = (fixed - minimum)...fixed
            }
        }
        return clampRange(range, lower: lower, upper: upper)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, displayBounds.minX), displayBounds.maxX),
            y: min(max(point.y, displayBounds.minY), displayBounds.maxY)
        )
    }

    private func clamp(origin: CGFloat, extent: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(origin, lower), upper - extent)
    }

    private func clampRange(_ range: ClosedRange<CGFloat>, lower: CGFloat, upper: CGFloat) -> ClosedRange<CGFloat> {
        let width = range.upperBound - range.lowerBound
        guard width > 0 else { return lower...lower }
        let clampedWidth = min(width, max(0, upper - lower))
        let origin = clamp(origin: range.lowerBound, extent: clampedWidth, lower: lower, upper: upper)
        return origin...(origin + clampedWidth)
    }

    private func handleCenter(_ handle: SelectionHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

typealias SelectionHandleHit = SelectionHit
