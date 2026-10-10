import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Namespace for the M4 annotation core. The concrete types below intentionally stay value based
/// and independent of overlay windows so the same vectors can be rendered by preview and, later,
/// by the export pipeline.
enum AnnotationModule {}

// MARK: - Typed canvas geometry

/// A point in the selected canvas. Canvas coordinates are lower-left origin, y-up logical points;
/// they are not display-global points or image pixels.
struct CanvasPoint: Codable, Equatable, Hashable, Sendable {
    let x: CGFloat
    let y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }

    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    func clamped(to bounds: CanvasRect) -> CanvasPoint {
        CanvasPoint(
            x: min(max(x, bounds.minX), bounds.maxX),
            y: min(max(y, bounds.minY), bounds.maxY)
        )
    }
}

/// A rectangle in the selected canvas. It carries the same lower-left/y-up semantics as
/// `CanvasPoint`; conversion to AppKit/Core Graphics rectangles is explicit at the boundary.
struct CanvasRect: Codable, Equatable, Hashable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let raw = CGRect(x: x, y: y, width: width, height: height).standardized
        self.x = raw.origin.x.isFinite ? raw.origin.x : 0
        self.y = raw.origin.y.isFinite ? raw.origin.y : 0
        self.width = raw.width.isFinite ? max(0, raw.width) : 0
        self.height = raw.height.isFinite ? max(0, raw.height) : 0
    }

    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var minX: CGFloat { x }
    var minY: CGFloat { y }
    var maxX: CGFloat { x + width }
    var maxY: CGFloat { y + height }
    var midX: CGFloat { x + width / 2 }
    var midY: CGFloat { y + height / 2 }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func contains(_ point: CanvasPoint) -> Bool {
        cgRect.contains(point.cgPoint)
    }

    func clamped(_ point: CanvasPoint) -> CanvasPoint {
        point.clamped(to: self)
    }
}

// MARK: - Styles and immutable items

/// A serializable color that does not depend on AppKit color-space conversion behavior.
struct AnnotationColor: Codable, Equatable, Hashable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    static let red = AnnotationColor(red: 1, green: 0.16, blue: 0.12)
    static let yellow = AnnotationColor(red: 1, green: 0.82, blue: 0.08)
    static let green = AnnotationColor(red: 0.18, green: 0.78, blue: 0.32)
    static let blue = AnnotationColor(red: 0.16, green: 0.45, blue: 0.95)
    static let black = AnnotationColor(red: 0.05, green: 0.05, blue: 0.06)
    static let white = AnnotationColor(red: 1, green: 1, blue: 1)
    static let defaultColor = AnnotationColor.red

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

struct AnnotationStyle: Codable, Equatable, Sendable {
    let color: AnnotationColor
    let width: CGFloat
    let opacity: CGFloat

    static let `default` = AnnotationStyle(color: .defaultColor, width: 3)

    init(color: AnnotationColor, width: CGFloat, opacity: CGFloat = 1) {
        self.color = color
        self.width = width.isFinite ? min(max(width, 0.5), 128) : 3
        self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1
    }

    var cgColor: CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha * opacity)
    }

    var strokeWidth: CGFloat { width }

    func withOpacity(_ value: CGFloat) -> AnnotationStyle {
        AnnotationStyle(color: color, width: width, opacity: value)
    }
}

/// Text-specific value styling. Text annotations deliberately keep a stable, serializable font
/// name/size rather than retaining AppKit objects or an attributed-string instance. The renderer
/// materializes the platform font only at the Core Text boundary.
enum TextAlignment: String, Codable, CaseIterable, Equatable, Sendable {
    case leading
    case center
    case trailing

    /// Vocabulary aliases for callers using AppKit's left/right terminology.
    static var left: TextAlignment { .leading }
    static var right: TextAlignment { .trailing }
}

struct TextStyle: Codable, Equatable, Hashable, Sendable {
    let fontName: String
    let fontSize: CGFloat
    let color: AnnotationColor
    let alignment: TextAlignment
    let lineSpacing: CGFloat

    static let `default` = TextStyle()

    init(
        fontName: String = "Helvetica",
        fontSize: CGFloat = 16,
        color: AnnotationColor = .defaultColor,
        alignment: TextAlignment = .leading,
        lineSpacing: CGFloat = 2
    ) {
        let trimmedName = fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fontName = trimmedName.isEmpty ? "Helvetica" : trimmedName
        self.fontSize = Self.sanitizeFontSize(fontSize)
        self.color = color
        self.alignment = alignment
        self.lineSpacing = lineSpacing.isFinite ? min(max(lineSpacing, 0), 256) : 2
    }

    init(
        fontName: String = "Helvetica",
        pointSize: CGFloat,
        color: AnnotationColor = .defaultColor,
        alignment: TextAlignment = .leading,
        lineSpacing: CGFloat = 2
    ) {
        self.init(fontName: fontName, fontSize: pointSize, color: color, alignment: alignment, lineSpacing: lineSpacing)
    }

    /// Ensures values coming from old settings or user-created test fixtures remain finite and
    /// bounded before they reach Core Text.
    var sanitized: TextStyle {
        TextStyle(fontName: fontName, fontSize: fontSize, color: color, alignment: alignment, lineSpacing: lineSpacing)
    }

    var lineHeight: CGFloat { max(1, fontSize * 1.2 + lineSpacing) }
    var pointSize: CGFloat { fontSize }
    var size: CGFloat { fontSize }

    var nsFont: NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    }

    var font: NSFont { nsFont }
    var textColor: AnnotationColor { color }

    var annotationStyle: AnnotationStyle {
        AnnotationStyle(color: color, width: max(0.5, fontSize * 0.08))
    }

    private static func sanitizeFontSize(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 16 }
        return min(max(value, 6), 256)
    }
}

/// Pure text input policy shared by the editor session and tests. Newlines are normalized without
/// trimming user-visible spaces; blank checks are intentionally separate so a nonblank annotation
/// can preserve leading/trailing spaces when that is what the user entered.
enum TextSanitizer {
    static func normalizeNewlines(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0000}", with: "")
    }

    static func sanitize(_ value: String) -> String { normalizeNewlines(value) }

    static func isBlank(_ value: String) -> Bool {
        normalizeNewlines(value).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TextInputSanitizer {
    static func sanitize(_ value: String) -> String { TextSanitizer.sanitize(value) }
    static func isBlank(_ value: String) -> Bool { TextSanitizer.isBlank(value) }
}

/// Pure, deterministic line layout metadata used by both text editing bounds and rendering.
/// Core Text still measures the final glyphs when drawing; this value type only controls newline
/// normalization, conservative wrapping, and finite line metrics.
struct TextLayout: Equatable, Sendable {
    let lines: [String]
    let lineHeight: CGFloat
    let contentSize: CGSize

    var lineCount: Int { lines.count }
}

enum TextLayoutEngine {
    static func sanitize(_ text: String) -> String { TextSanitizer.sanitize(text) }

    static func sanitizedStyle(_ style: TextStyle) -> TextStyle { style.sanitized }

    static func layout(text: String, style: TextStyle, in bounds: CanvasRect) -> TextLayout {
        let normalized = TextSanitizer.normalizeNewlines(text)
        let safeStyle = style.sanitized
        let width = max(0, bounds.width.isFinite ? bounds.width : 0)
        let estimatedCharacterWidth = max(1, safeStyle.fontSize * 0.55)
        let maximumCharacters = width > 0 ? max(1, Int(floor(width / estimatedCharacterWidth))) : 1
        var lines: [String] = []

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard rawLine.count > maximumCharacters else {
                lines.append(rawLine)
                continue
            }
            var remaining = rawLine
            while remaining.count > maximumCharacters {
                let cut = remaining.index(remaining.startIndex, offsetBy: maximumCharacters)
                let prefix = String(remaining[..<cut])
                if let breakIndex = prefix.lastIndex(where: { $0 == " " || $0 == "\t" }), breakIndex > prefix.startIndex {
                    lines.append(String(prefix[..<breakIndex]))
                    remaining = String(prefix[prefix.index(after: breakIndex)...]) + remaining[cut...]
                } else {
                    lines.append(prefix)
                    remaining = String(remaining[cut...])
                }
            }
            lines.append(remaining)
        }

        if lines.isEmpty { lines = [""] }
        let lineHeight = safeStyle.lineHeight
        let measuredWidth = min(width, CGFloat(lines.map(\.count).max() ?? 0) * estimatedCharacterWidth)
        let measuredHeight = min(max(0, bounds.height), CGFloat(lines.count) * lineHeight)
        return TextLayout(
            lines: lines,
            lineHeight: lineHeight,
            contentSize: CGSize(width: measuredWidth, height: measuredHeight)
        )
    }

    static func layout(_ text: String, style: TextStyle, bounds: CanvasRect) -> TextLayout {
        layout(text: text, style: style, in: bounds)
    }

    static func make(text: String, style: TextStyle, bounds: CanvasRect) -> TextLayout {
        layout(text: text, style: style, in: bounds)
    }
}

/// Actions exposed by the final horizontal editor toolbar. M6 supplies the handlers while the
/// enum remains value-only so the M5 key-routing seam stays independent of AppKit windows.
enum CaptureEditorAction: String, CaseIterable, Equatable, Sendable {
    case copy
    case save
    case saveAs
    case share
    case print
    case cancel

    var displayName: String {
        switch self {
        case .copy: "Copy"
        case .save: "Save"
        case .saveAs: "Save As"
        case .share: "Share"
        case .print: "Print"
        case .cancel: "Cancel"
        }
    }

    var title: String { displayName }

    var isM6Action: Bool { self != .cancel }
}

struct CaptureKeyInput: Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt
    let charactersIgnoringModifiers: String?

    init(keyCode: UInt16, modifiers: UInt = 0, charactersIgnoringModifiers: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }
}

enum CaptureKeyRoute: Equatable, Sendable {
    case textCommit
    case textNewline
    case textCancel
    case undo
    case redo
    case selectAll
    case captureCancel
    case captureCopy
    case captureSave
    case captureSaveAs
    case capturePrint
    case passThrough

    static var commitText: CaptureKeyRoute { .textCommit }
    static var cancelText: CaptureKeyRoute { .textCancel }
    static var insertNewline: CaptureKeyRoute { .textNewline }
    static var cancelCapture: CaptureKeyRoute { .captureCancel }
}

/// Central key policy. The route is deliberately value-only so text-input priority can be tested
/// without constructing windows. When editing text, every native command (including Cmd+C/V/X/Z)
/// passes through to NSTextView; only Return/Escape are owned by the editor session.
struct CaptureKeyRouter: Sendable {
    static let escapeKeyCode: UInt16 = 53
    static let returnKeyCodes: Set<UInt16> = [36, 52, 76]
    static let zKeyCode: UInt16 = 6
    static let aKeyCode: UInt16 = 0
    static let cKeyCode: UInt16 = 8
    static let pKeyCode: UInt16 = 35
    static let sKeyCode: UInt16 = 1

    private static let commandMask = NSEvent.ModifierFlags.command.rawValue
    private static let shiftMask = NSEvent.ModifierFlags.shift.rawValue
    private static let optionMask = NSEvent.ModifierFlags.option.rawValue
    private static let controlMask = NSEvent.ModifierFlags.control.rawValue

    static func route(_ input: CaptureKeyInput, textEditing: Bool) -> CaptureKeyRoute {
        let flags = input.modifiers
        let command = flags & commandMask != 0
        let shift = flags & shiftMask != 0
        let option = flags & optionMask != 0
        let control = flags & controlMask != 0
        let isReturn = returnKeyCodes.contains(input.keyCode) || input.charactersIgnoringModifiers == "\r" || input.charactersIgnoringModifiers == "\n"
        let isEscape = input.keyCode == escapeKeyCode || input.charactersIgnoringModifiers == "\u{001b}"
        let isZ = input.keyCode == zKeyCode || input.charactersIgnoringModifiers?.lowercased() == "z"
        let isA = input.keyCode == aKeyCode || input.charactersIgnoringModifiers?.lowercased() == "a"

        if textEditing {
            if isEscape { return .textCancel }
            if isReturn {
                if !command && !control && !shift && !option { return .textCommit }
                if !command && !control && (shift || option) { return .textNewline }
            }
            return .passThrough
        }

        if isEscape { return .captureCancel }
        guard command, !control else { return .passThrough }
        let isC = input.keyCode == cKeyCode || input.charactersIgnoringModifiers?.lowercased() == "c"
        let isP = input.keyCode == pKeyCode || input.charactersIgnoringModifiers?.lowercased() == "p"
        let isS = input.keyCode == sKeyCode || input.charactersIgnoringModifiers?.lowercased() == "s"
        if isC { return .captureCopy }
        if isP { return .capturePrint }
        if isS {
            return shift ? .captureSaveAs : .captureSave
        }
        if isZ { return shift ? .redo : .undo }
        if isA { return .selectAll }
        return .passThrough
    }

    static func route(keyCode: UInt16, modifiers: UInt = 0, textEditing: Bool) -> CaptureKeyRoute {
        route(CaptureKeyInput(keyCode: keyCode, modifiers: modifiers), textEditing: textEditing)
    }

    func route(_ input: CaptureKeyInput, textEditing: Bool) -> CaptureKeyRoute {
        Self.route(input, textEditing: textEditing)
    }
}

/// Immutable multiline text value in lower-left canvas coordinates. `origin` is retained as an
/// explicit semantic anchor while `bounds` carries the destination box used by the renderer.
struct TextAnnotation: Annotation, Codable, Hashable {
    let id: UUID
    let origin: CanvasPoint
    let bounds: CanvasRect
    let text: String
    let style: TextStyle

    init(
        id: UUID = UUID(),
        origin: CanvasPoint,
        bounds: CanvasRect,
        text: String,
        style: TextStyle = .default
    ) {
        self.id = id
        self.origin = origin
        self.bounds = bounds
        self.text = TextSanitizer.normalizeNewlines(text)
        self.style = style.sanitized
    }

    init(
        id: UUID = UUID(),
        text: String,
        bounds: CanvasRect,
        style: TextStyle = .default
    ) {
        self.init(id: id, origin: CanvasPoint(x: bounds.minX, y: bounds.minY), bounds: bounds, text: text, style: style)
    }

    init(
        id: UUID = UUID(),
        origin: CanvasPoint,
        text: String,
        style: TextStyle = .default,
        width: CGFloat = 240,
        height: CGFloat = 80
    ) {
        self.init(
            id: id,
            origin: origin,
            bounds: CanvasRect(x: origin.x, y: origin.y, width: width, height: height),
            text: text,
            style: style
        )
    }

    init(
        id: UUID = UUID(),
        origin: CanvasPoint,
        bounds: CanvasRect,
        attributedText: String,
        style: TextStyle = .default
    ) {
        self.init(id: id, origin: origin, bounds: bounds, text: attributedText, style: style)
    }

    /// AppKit convenience for callers that already have an attributed editor value. Attributes
    /// are intentionally flattened into the value-based style/text representation at the model
    /// boundary; the selected TextStyle remains the source of truth for rendering.
    init(
        id: UUID = UUID(),
        origin: CanvasPoint,
        bounds: CanvasRect,
        attributedText: NSAttributedString,
        style: TextStyle = .default
    ) {
        self.init(id: id, origin: origin, bounds: bounds, text: attributedText.string, style: style)
    }

    var attributedString: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: style.nsFont,
            .foregroundColor: style.color.nsColor
        ])
    }

    var rect: CanvasRect { bounds }
    var string: String { text }
    var attributedText: String { text }

    var layout: TextLayout { TextLayoutEngine.layout(text: text, style: style, in: bounds) }
}

enum AnnotationTool: String, CaseIterable, Codable, Equatable, Sendable {
    case select
    case pen
    case line
    case arrow
    case rectangle
    case marker
    case text

    /// Vocabulary aliases used by the architecture/product documents.
    static var freehand: AnnotationTool { .pen }
    static var highlighter: AnnotationTool { .marker }

    var displayName: String {
        switch self {
        case .select: "Select"
        case .pen: "Pen"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .marker: "Marker"
        case .text: "Text"
        }
    }
}

/// The arrowhead is a pure geometry value so preview and future export use exactly the same
/// tip/head construction.
struct ArrowGeometry: Equatable, Sendable {
    let tip: CanvasPoint
    let left: CanvasPoint
    let right: CanvasPoint
    let shaftStart: CanvasPoint
    let shaftEnd: CanvasPoint
    let headLength: CGFloat

    static func make(start: CanvasPoint, end: CanvasPoint, style: AnnotationStyle) -> ArrowGeometry {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length.isFinite, length > 0.0001 else {
            return ArrowGeometry(tip: end, left: end, right: end, shaftStart: start, shaftEnd: end, headLength: 0)
        }

        let ux = dx / length
        let uy = dy / length
        let headLength = min(max(style.width * 4, 8), length * 0.45)
        let headWidth = headLength * 0.55
        let base = CanvasPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        let left = CanvasPoint(x: base.x + (-uy) * headWidth, y: base.y + ux * headWidth)
        let right = CanvasPoint(x: base.x - (-uy) * headWidth, y: base.y - ux * headWidth)
        let shaftEnd = CanvasPoint(x: end.x - ux * (headLength * 0.72), y: end.y - uy * (headLength * 0.72))
        return ArrowGeometry(tip: end, left: left, right: right, shaftStart: start, shaftEnd: shaftEnd, headLength: headLength)
    }

    var points: [CanvasPoint] { [shaftStart, shaftEnd, tip, left, right] }
}

private func canvasBounds(for points: [CanvasPoint], strokeWidth: CGFloat) -> CanvasRect {
    guard let first = points.first else { return CanvasRect(x: 0, y: 0, width: 0, height: 0) }
    var minX = first.x
    var minY = first.y
    var maxX = first.x
    var maxY = first.y
    for point in points.dropFirst() {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
    }
    let inset = max(0, strokeWidth) / 2
    return CanvasRect(x: minX - inset, y: minY - inset, width: maxX - minX + inset * 2, height: maxY - minY + inset * 2)
}

protocol Annotation: Equatable, Identifiable, Sendable {
    var bounds: CanvasRect { get }
}

struct FreehandStroke: Annotation {
    let id: UUID
    let points: [CanvasPoint]
    let style: AnnotationStyle

    init(id: UUID = UUID(), points: [CanvasPoint], style: AnnotationStyle) {
        self.id = id
        self.points = points
        self.style = style
    }

    var bounds: CanvasRect { canvasBounds(for: points, strokeWidth: style.width) }
}

struct LineAnnotation: Annotation {
    let id: UUID
    let start: CanvasPoint
    let end: CanvasPoint
    let style: AnnotationStyle

    init(id: UUID = UUID(), start: CanvasPoint, end: CanvasPoint, style: AnnotationStyle) {
        self.id = id
        self.start = start
        self.end = end
        self.style = style
    }

    var bounds: CanvasRect { canvasBounds(for: [start, end], strokeWidth: style.width) }
}

struct ArrowAnnotation: Annotation {
    let id: UUID
    let start: CanvasPoint
    let end: CanvasPoint
    let style: AnnotationStyle

    init(id: UUID = UUID(), start: CanvasPoint, end: CanvasPoint, style: AnnotationStyle) {
        self.id = id
        self.start = start
        self.end = end
        self.style = style
    }

    var geometry: ArrowGeometry { ArrowGeometry.make(start: start, end: end, style: style) }
    var bounds: CanvasRect { canvasBounds(for: geometry.points, strokeWidth: style.width) }
}

struct RectangleAnnotation: Annotation {
    let id: UUID
    let rect: CanvasRect
    let style: AnnotationStyle

    init(id: UUID = UUID(), rect: CanvasRect, style: AnnotationStyle) {
        self.id = id
        self.rect = rect
        self.style = style
    }

    var bounds: CanvasRect {
        CanvasRect(x: rect.minX - style.width / 2, y: rect.minY - style.width / 2, width: rect.width + style.width, height: rect.height + style.width)
    }
}

struct HighlightAnnotation: Annotation {
    let id: UUID
    let points: [CanvasPoint]
    let style: AnnotationStyle

    init(id: UUID = UUID(), points: [CanvasPoint], style: AnnotationStyle) {
        self.id = id
        self.points = points
        self.style = style
    }

    var bounds: CanvasRect { canvasBounds(for: points, strokeWidth: style.width) }
}

typealias PenAnnotation = FreehandStroke
typealias MarkerAnnotation = HighlightAnnotation

/// Heterogeneous annotations remain ordered in this immutable value enum. Static convenience
/// constructors keep the vocabulary aligned with the architecture document's freehand/marker
/// names while the cases match the tools shown by the temporary M4 controls.
enum AnnotationItem: Equatable, Identifiable, Sendable {
    case pen(FreehandStroke)
    case line(LineAnnotation)
    case arrow(ArrowAnnotation)
    case rectangle(RectangleAnnotation)
    case marker(HighlightAnnotation)
    case text(TextAnnotation)

    static func freehand(_ stroke: FreehandStroke) -> AnnotationItem { .pen(stroke) }
    static func highlight(_ marker: HighlightAnnotation) -> AnnotationItem { .marker(marker) }

    var id: UUID {
        switch self {
        case let .pen(value): value.id
        case let .line(value): value.id
        case let .arrow(value): value.id
        case let .rectangle(value): value.id
        case let .marker(value): value.id
        case let .text(value): value.id
        }
    }

    var style: AnnotationStyle {
        switch self {
        case let .pen(value): value.style
        case let .line(value): value.style
        case let .arrow(value): value.style
        case let .rectangle(value): value.style
        case let .marker(value): value.style
        case let .text(value): value.style.annotationStyle
        }
    }

    var bounds: CanvasRect {
        switch self {
        case let .pen(value): value.bounds
        case let .line(value): value.bounds
        case let .arrow(value): value.bounds
        case let .rectangle(value): value.bounds
        case let .marker(value): value.bounds
        case let .text(value): value.bounds
        }
    }

    var tool: AnnotationTool {
        switch self {
        case .pen: .pen
        case .line: .line
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .marker: .marker
        case .text: .text
        }
    }
}

// MARK: - Ordered document and command history

struct AnnotationDocument: Equatable, Sendable {
    let canvasBounds: CanvasRect
    private(set) var items: [AnnotationItem]
    private(set) var transient: AnnotationItem?

    init(canvasBounds: CanvasRect) {
        self.canvasBounds = canvasBounds
        self.items = []
        self.transient = nil
    }

    init(canvasSize: CGSize) {
        self.init(canvasBounds: CanvasRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height))
    }

    init(canvas: CanvasRect) {
        self.init(canvasBounds: canvas)
    }

    init(size: CGSize) {
        self.init(canvasSize: size)
    }

    var annotations: [AnnotationItem] { items }
    var renderedItems: [AnnotationItem] { items + (transient.map { [$0] } ?? []) }
    var isEmpty: Bool { items.isEmpty && transient == nil }

    /// Export takes a value snapshot of committed annotations only. Transient gesture previews
    /// belong to the overlay interaction and must never leak into a saved, copied, printed, or
    /// shared image.
    var committedOnly: AnnotationDocument {
        var copy = self
        copy.transient = nil
        return copy
    }

    mutating func setTransient(_ item: AnnotationItem?) { transient = item }
    mutating func clearTransient() { transient = nil }

    fileprivate mutating func insert(_ item: AnnotationItem, at index: Int) {
        let insertionIndex = min(max(index, 0), items.count)
        items.insert(item, at: insertionIndex)
    }

    @discardableResult
    fileprivate mutating func remove(id: UUID) -> AnnotationItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    fileprivate mutating func replace(_ item: AnnotationItem, at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index] = item
    }
}

enum AnnotationCommand: Equatable, Sendable {
    case add(item: AnnotationItem, index: Int)
    case update(before: AnnotationItem, after: AnnotationItem, index: Int)
    case delete(item: AnnotationItem, index: Int)

    var index: Int {
        switch self {
        case let .add(_, index), let .update(_, _, index), let .delete(_, index): index
        }
    }

    var item: AnnotationItem {
        switch self {
        case let .add(item, _), let .delete(item, _): item
        case let .update(_, after, _): after
        }
    }
}

/// A reversible command history. New commands clear redo exactly once, while undo/redo apply the
/// inverse operation without manufacturing extra history entries.
final class AnnotationCommandStack {
    private(set) var document: AnnotationDocument
    private var undoCommands: [AnnotationCommand] = []
    private var redoCommands: [AnnotationCommand] = []

    init(document: AnnotationDocument) { self.document = document }

    var canUndo: Bool { !undoCommands.isEmpty }
    var canRedo: Bool { !redoCommands.isEmpty }
    var undoCount: Int { undoCommands.count }
    var redoCount: Int { redoCommands.count }

    func setTransient(_ item: AnnotationItem?) { document.setTransient(item) }
    func clearTransient() { document.clearTransient() }

    @discardableResult
    func commitTransient(at index: Int? = nil) -> Bool {
        guard let item = document.transient else { return false }
        document.clearTransient()
        return add(item, at: index)
    }

    @discardableResult
    func add(_ item: AnnotationItem, at index: Int? = nil) -> Bool {
        let resolved = min(max(index ?? document.items.count, 0), document.items.count)
        return perform(.add(item: item, index: resolved))
    }

    @discardableResult
    func update(_ item: AnnotationItem) -> Bool {
        guard let index = document.items.firstIndex(where: { $0.id == item.id }) else { return false }
        return perform(.update(before: document.items[index], after: item, index: index))
    }

    @discardableResult
    func update(before: AnnotationItem, after: AnnotationItem, at index: Int) -> Bool {
        perform(.update(before: before, after: after, index: index))
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { return false }
        return perform(.delete(item: document.items[index], index: index))
    }

    @discardableResult
    func delete(_ item: AnnotationItem, at index: Int) -> Bool {
        perform(.delete(item: item, index: index))
    }

    @discardableResult
    func perform(_ command: AnnotationCommand) -> Bool {
        guard apply(command, reversing: false) else { return false }
        undoCommands.append(command)
        redoCommands.removeAll(keepingCapacity: true)
        return true
    }

    /// Verbose aliases make command-oriented callers read naturally without exposing the internal
    /// history arrays.
    @discardableResult
    func execute(_ command: AnnotationCommand) -> Bool { perform(command) }

    @discardableResult
    func apply(_ command: AnnotationCommand) -> Bool { perform(command) }

    @discardableResult
    func undo() -> Bool {
        guard let command = undoCommands.popLast() else { return false }
        guard apply(command, reversing: true) else {
            undoCommands.append(command)
            return false
        }
        redoCommands.append(command)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let command = redoCommands.popLast() else { return false }
        guard apply(command, reversing: false) else {
            redoCommands.append(command)
            return false
        }
        undoCommands.append(command)
        return true
    }

    private func apply(_ command: AnnotationCommand, reversing: Bool) -> Bool {
        switch (command, reversing) {
        case let (.add(item, index), false):
            guard !document.items.contains(where: { $0.id == item.id }) else { return false }
            document.insert(item, at: index)
            return true
        case let (.add(item, _), true):
            return document.remove(id: item.id) != nil
        case let (.update(before, after, index), false):
            guard let actual = document.items.firstIndex(where: { $0.id == before.id }), actual == index else { return false }
            document.replace(after, at: actual)
            return true
        case let (.update(before, _, index), true):
            guard let actual = document.items.firstIndex(where: { $0.id == before.id }), actual == index else { return false }
            document.replace(before, at: actual)
            return true
        case let (.delete(item, _), false):
            return document.remove(id: item.id) != nil
        case let (.delete(item, index), true):
            guard !document.items.contains(where: { $0.id == item.id }) else { return false }
            document.insert(item, at: index)
            return true
        }
    }
}

// MARK: - Gesture reduction

/// Pure reducer for one in-progress draw. A gesture captures its tool/style at begin time,
/// clamps all points to the canvas, coalesces dense pen samples, and refuses degenerate commits.
struct AnnotationGestureReducer: Equatable, Sendable {
    let canvasBounds: CanvasRect
    private(set) var transient: AnnotationItem?

    private enum ActiveGesture: Equatable, Sendable {
        case pen(tool: AnnotationTool, style: AnnotationStyle, points: [CanvasPoint])
        case segment(tool: AnnotationTool, style: AnnotationStyle, start: CanvasPoint, end: CanvasPoint)
        case rectangle(style: AnnotationStyle, start: CanvasPoint, end: CanvasPoint)
    }

    private var active: ActiveGesture?

    init(canvasBounds: CanvasRect) {
        self.canvasBounds = canvasBounds
        self.transient = nil
        self.active = nil
    }

    var isActive: Bool { active != nil }

    var activeTool: AnnotationTool? {
        switch active {
        case let .pen(tool, _, _), let .segment(tool, _, _, _): tool
        case .rectangle: .rectangle
        case nil: nil
        }
    }

    @discardableResult
    mutating func begin(tool: AnnotationTool, style: AnnotationStyle, at point: CanvasPoint) -> Bool {
        guard active == nil, tool != .select, canvasBounds.contains(point) else { return false }
        let clamped = canvasBounds.clamped(point)
        switch tool {
        case .pen, .marker:
            active = .pen(tool: tool, style: style, points: [clamped])
        case .line, .arrow:
            active = .segment(tool: tool, style: style, start: clamped, end: clamped)
        case .rectangle:
            active = .rectangle(style: style, start: clamped, end: clamped)
        case .select, .text:
            return false
        }
        transient = makeItem()
        return true
    }

    @discardableResult
    mutating func update(to point: CanvasPoint) -> AnnotationItem? {
        guard let active else { return transient }
        let clamped = canvasBounds.clamped(point)
        switch active {
        case let .pen(tool, style, points):
            var next = points
            let minimumDistance = max(0.25, style.width * 0.18)
            if let last = next.last, hypot(last.x - clamped.x, last.y - clamped.y) >= minimumDistance {
                next.append(clamped)
            }
            self.active = .pen(tool: tool, style: style, points: next)
        case let .segment(tool, style, start, _):
            self.active = .segment(tool: tool, style: style, start: start, end: clamped)
        case let .rectangle(style, start, _):
            self.active = .rectangle(style: style, start: start, end: clamped)
        }
        transient = makeItem()
        return transient
    }

    @discardableResult
    mutating func end() -> AnnotationItem? {
        let result = transient
        active = nil
        transient = nil
        guard let result, isMeaningful(result) else { return nil }
        return result
    }

    mutating func cancel() {
        active = nil
        transient = nil
    }

    private func makeItem() -> AnnotationItem? {
        guard let active else { return nil }
        switch active {
        case let .pen(tool, style, points):
            if tool == .marker {
                // Keep the captured style unchanged; marker translucency is a rendering policy,
                // not a mutation of the user's selected color/opacity.
                return .marker(HighlightAnnotation(points: points, style: style))
            }
            return .pen(FreehandStroke(points: points, style: style))
        case let .segment(tool, style, start, end):
            if tool == .arrow { return .arrow(ArrowAnnotation(start: start, end: end, style: style)) }
            return .line(LineAnnotation(start: start, end: end, style: style))
        case let .rectangle(style, start, end):
            return .rectangle(RectangleAnnotation(rect: CanvasRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            ), style: style))
        }
    }

    private func isMeaningful(_ item: AnnotationItem) -> Bool {
        let threshold = max(0.5, item.style.width * 0.2)
        switch item {
        case let .pen(value):
            guard let first = value.points.first else { return false }
            return value.points.contains { hypot($0.x - first.x, $0.y - first.y) >= threshold }
        case let .marker(value):
            guard let first = value.points.first else { return false }
            return value.points.contains { hypot($0.x - first.x, $0.y - first.y) >= threshold }
        case let .line(value):
            return hypot(value.start.x - value.end.x, value.start.y - value.end.y) >= threshold
        case let .arrow(value):
            return hypot(value.start.x - value.end.x, value.start.y - value.end.y) >= threshold
        case let .rectangle(value):
            return value.rect.width >= threshold && value.rect.height >= threshold
        case let .text(value):
            return !TextSanitizer.isBlank(value.text)
        }
    }
}

// MARK: - Shared Core Graphics rendering

/// Maps a logical lower-left canvas into one destination rectangle in a drawing context.
struct CanvasTransform: Equatable, Sendable {
    let canvasBounds: CanvasRect
    let destination: CGRect

    init(canvasBounds: CanvasRect, destination: CGRect) {
        self.canvasBounds = canvasBounds
        self.destination = destination.standardized
    }

    func canvasPoint(from destinationPoint: CGPoint) -> CanvasPoint {
        guard canvasBounds.width > 0, canvasBounds.height > 0, destination.width > 0, destination.height > 0 else {
            return CanvasPoint(x: canvasBounds.minX, y: canvasBounds.minY)
        }
        return CanvasPoint(
            x: canvasBounds.minX + (destinationPoint.x - destination.minX) * canvasBounds.width / destination.width,
            y: canvasBounds.minY + (destinationPoint.y - destination.minY) * canvasBounds.height / destination.height
        ).clamped(to: canvasBounds)
    }

    /// Maps an AppKit/display destination rectangle back into the logical canvas without
    /// mutating any stored annotation vectors. Both rectangles use lower-left/y-up semantics.
    func canvasRect(from destinationRect: CGRect) -> CanvasRect {
        let rect = destinationRect.standardized
        let lower = canvasPoint(from: rect.origin)
        let upper = canvasPoint(from: CGPoint(x: rect.maxX, y: rect.maxY))
        return CanvasRect(
            x: min(lower.x, upper.x),
            y: min(lower.y, upper.y),
            width: abs(upper.x - lower.x),
            height: abs(upper.y - lower.y)
        )
    }

    func canvasRect(for destinationRect: CGRect) -> CanvasRect {
        canvasRect(from: destinationRect)
    }

    var canvasBoundsRect: CanvasRect { canvasRect(from: destination) }

    func destinationRect(for canvasRect: CanvasRect) -> CGRect {
        guard canvasBounds.width > 0, canvasBounds.height > 0 else { return destination }
        return CGRect(
            x: destination.minX + (canvasRect.minX - canvasBounds.minX) * destination.width / canvasBounds.width,
            y: destination.minY + (canvasRect.minY - canvasBounds.minY) * destination.height / canvasBounds.height,
            width: canvasRect.width * destination.width / canvasBounds.width,
            height: canvasRect.height * destination.height / canvasBounds.height
        )
    }
}

enum AnnotationRenderer {
    static func render(document: AnnotationDocument, in context: CGContext, destination: CGRect) {
        drawVectors(document: document, in: context, destination: destination)
    }

    /// Draw the complete preview/export layer directly into an existing Core Graphics context.
    /// Keeping this path direct avoids allocating a full-display intermediate image for every
    /// drag sample in the overlay.
    static func draw(
        source: CGImage,
        selection: ImagePixelRect?,
        document: AnnotationDocument? = nil,
        in context: CGContext,
        destination: CGRect,
        dimAlpha: CGFloat = 0.45
    ) {
        let destination = destination.standardized
        guard destination.width > 0, destination.height > 0 else { return }
        context.draw(source, in: destination)
        context.setFillColor(NSColor.black.withAlphaComponent(min(max(dimAlpha, 0), 1)).cgColor)
        context.fill(destination)
        guard let selection else { return }
        let imageSize = PixelSize(width: source.width, height: source.height)
        let clamped = selection.clamped(to: imageSize)
        guard !clamped.isEmpty else { return }
        let scaleX = destination.width / CGFloat(max(source.width, 1))
        let scaleY = destination.height / CGFloat(max(source.height, 1))
        let lowerLeftRect = CGRect(
            x: destination.minX + CGFloat(clamped.x) * scaleX,
            y: destination.minY + CGFloat(source.height - clamped.maxY) * scaleY,
            width: CGFloat(clamped.width) * scaleX,
            height: CGFloat(clamped.height) * scaleY
        )
        context.saveGState()
        context.clip(to: lowerLeftRect)
        context.draw(source, in: destination)
        context.restoreGState()
        if let document {
            drawVectors(document: document, in: context, destination: lowerLeftRect)
        }
    }

    /// Draw vectors in one save/clip/transform scope. Committed order is retained and the
    /// transient item is drawn last, ensuring previews never reorder committed annotations.
    static func drawVectors(document: AnnotationDocument, in context: CGContext, destination: CGRect) {
        let transform = CanvasTransform(canvasBounds: document.canvasBounds, destination: destination)
        guard transform.canvasBounds.width > 0, transform.canvasBounds.height > 0 else { return }
        let scaleX = destination.width / transform.canvasBounds.width
        let scaleY = destination.height / transform.canvasBounds.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return }

        context.saveGState()
        context.clip(to: destination)
        context.translateBy(
            x: destination.minX - transform.canvasBounds.minX * scaleX,
            y: destination.minY - transform.canvasBounds.minY * scaleY
        )
        context.scaleBy(x: scaleX, y: scaleY)
        for item in document.items {
            draw(item: item, in: context)
        }
        if let transient = document.transient {
            draw(item: transient, in: context)
        }
        context.restoreGState()
    }

    /// Shared source/dim/selection/vector compositor. The selection is an image-space rect
    /// (upper-left origin); vectors are mapped into its lower-left destination rectangle.
    static func render(
        source: CGImage,
        selection: ImagePixelRect?,
        document: AnnotationDocument? = nil,
        dimAlpha: CGFloat = 0.45
    ) -> CGImage? {
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        draw(source: source, selection: selection, document: document, in: context, destination: bounds, dimAlpha: dimAlpha)
        return context.makeImage()
    }

    private static func draw(item: AnnotationItem, in context: CGContext) {
        switch item {
        case let .pen(value): drawStroke(points: value.points, style: value.style, in: context)
        case let .marker(value): drawStroke(points: value.points, style: value.style.withOpacity(value.style.opacity * 0.38), in: context)
        case let .line(value):
            context.setStrokeColor(value.style.cgColor)
            context.setLineWidth(value.style.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: value.start.cgPoint)
            context.addLine(to: value.end.cgPoint)
            context.strokePath()
        case let .arrow(value):
            let geometry = value.geometry
            context.setStrokeColor(value.style.cgColor)
            context.setLineWidth(value.style.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: geometry.shaftStart.cgPoint)
            context.addLine(to: geometry.shaftEnd.cgPoint)
            context.move(to: geometry.left.cgPoint)
            context.addLine(to: geometry.tip.cgPoint)
            context.addLine(to: geometry.right.cgPoint)
            context.strokePath()
        case let .rectangle(value):
            context.setStrokeColor(value.style.cgColor)
            context.setLineWidth(value.style.width)
            context.setLineJoin(.miter)
            context.stroke(value.rect.cgRect)
        case let .text(value):
            drawText(value, in: context)
        }
    }

    private static func drawText(_ value: TextAnnotation, in context: CGContext) {
        guard !TextSanitizer.isBlank(value.text), !value.bounds.isEmpty else { return }
        let style = value.style.sanitized
        let layout = TextLayoutEngine.layout(text: value.text, style: style, in: value.bounds)
        let font = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color.cgColor
        ]
        let safeLines = layout.lines.isEmpty ? [""] : layout.lines
        context.saveGState()
        context.clip(to: value.bounds.cgRect)
        var baseline = value.bounds.maxY - style.fontSize
        for lineText in safeLines {
            guard baseline >= value.bounds.minY - layout.lineHeight else { break }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: lineText, attributes: attributes))
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let available = max(0, value.bounds.width - lineWidth)
            let offset: CGFloat
            switch style.alignment {
            case .leading: offset = 0
            case .center: offset = available / 2
            case .trailing: offset = available
            }
            context.textPosition = CGPoint(x: value.bounds.minX + offset, y: baseline)
            CTLineDraw(line, context)
            baseline -= layout.lineHeight
        }
        context.restoreGState()
    }

    private static func drawStroke(points: [CanvasPoint], style: AnnotationStyle, in context: CGContext) {
        guard let first = points.first else { return }
        context.setStrokeColor(style.cgColor)
        context.setFillColor(style.cgColor)
        context.setLineWidth(style.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if points.count == 1 {
            let radius = style.width / 2
            context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: style.width, height: style.width))
            return
        }
        context.move(to: first.cgPoint)
        for point in points.dropFirst() {
            context.addLine(to: point.cgPoint)
        }
        context.strokePath()
    }
}
