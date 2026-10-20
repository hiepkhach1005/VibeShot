import AppKit
import CoreGraphics
import Foundation

/// Compatibility facade for the overlay preview. M4's Core Graphics renderer owns source/dim/bright
/// compositing and vector drawing, and M6's native compositor reuses its vector/text path.
struct CaptureOverlayRenderer {
    static func render(
        source: CGImage,
        selection: ImagePixelRect?,
        dimAlpha: CGFloat = 0.45
    ) -> CGImage? {
        AnnotationRenderer.render(source: source, selection: selection, dimAlpha: dimAlpha)
    }

    static func render(
        source: CGImage,
        selection: ImagePixelRect?,
        document: AnnotationDocument?,
        dimAlpha: CGFloat = 0.45
    ) -> CGImage? {
        AnnotationRenderer.render(source: source, selection: selection, document: document, dimAlpha: dimAlpha)
    }
}

@MainActor
final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The only key handling owned by the in-place editor is Return/Escape. All native editing
/// commands are forwarded to NSTextView so Cmd-C/V/X/Z, selection, input methods, and marked text
/// retain AppKit behavior.
@MainActor
final class TextEditingTextView: NSTextView {
    weak var editingSession: TextEditingSession?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let route = CaptureKeyRouter.route(
            CaptureKeyInput(
                keyCode: event.keyCode,
                modifiers: flags.rawValue,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            ),
            textEditing: true
        )
        switch route {
        case .textCommit:
            editingSession?.commit()
        case .textCancel:
            editingSession?.cancel()
        case .textNewline, .passThrough, .undo, .redo, .selectAll, .captureCancel,
             .captureCopy, .captureSave, .captureSaveAs, .capturePrint:
            super.keyDown(with: event)
        }
    }
}

/// Owns one reusable NSTextView session. `commit` and `cancel` are idempotent and detach the
/// delegate/view before invoking callbacks, which prevents focus-loss notifications from creating
/// duplicate history commands during overlay teardown.
@MainActor
final class TextEditingSession: NSObject, NSTextViewDelegate {
    private weak var hostView: NSView?
    private var textView: TextEditingTextView?
    private(set) var isActive = false
    private var onCommit: ((String, CGRect) -> Void)?
    private var onCancel: (() -> Void)?

    var editor: NSTextView? { textView }
    var frame: CGRect? { textView?.frame }

    @discardableResult
    func begin(
        in hostView: NSView,
        frame: CGRect,
        style: TextStyle,
        onCommit: @escaping (String, CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) -> Bool {
        guard !isActive else { return false }
        let safeFrame = Self.sanitizedFrame(frame, in: hostView.bounds)
        guard safeFrame.width > 0, safeFrame.height > 0 else { return false }

        let editor = TextEditingTextView(frame: safeFrame)
        editor.editingSession = self
        editor.delegate = self
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = true
        editor.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        editor.textColor = style.color.nsColor
        editor.insertionPointColor = style.color.nsColor
        editor.font = style.nsFont
        editor.textContainerInset = NSSize(width: 5, height: 4)
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = []
        editor.setAccessibilityRole(.textField)
        editor.setAccessibilityLabel("Screenshot annotation text")
        editor.setAccessibilityHelp("Type text. Return commits; Shift-Return or Option-Return inserts a new line; Escape cancels.")
        editor.wantsLayer = true
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor

        self.hostView = hostView
        self.textView = editor
        self.onCommit = onCommit
        self.onCancel = onCancel
        isActive = true
        hostView.addSubview(editor)
        editor.nextKeyView = hostView
        hostView.nextKeyView = editor
        hostView.window?.makeFirstResponder(editor)
        return true
    }

    @discardableResult
    func commit() -> Bool {
        guard isActive, let editor = textView else { return false }
        let text = TextSanitizer.sanitize(editor.string)
        guard !TextSanitizer.isBlank(text) else { return cancel() }
        let destination = editor.frame
        let callback = onCommit
        finish()
        callback?(text, destination)
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        guard isActive else { return false }
        let callback = onCancel
        finish()
        callback?()
        return true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard isActive else { return }
        _ = commit()
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        let editor = textView
        let host = hostView
        // Clear delegate/session first. Removing a first responder can synchronously emit another
        // textDidEndEditing notification; the inactive guard then makes that path a no-op.
        editor?.delegate = nil
        editor?.editingSession = nil
        textView = nil
        hostView = nil
        onCommit = nil
        onCancel = nil
        editor?.removeFromSuperview()
        if let host, host.window?.firstResponder === editor {
            host.window?.makeFirstResponder(host)
        }
    }

    private static func sanitizedFrame(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        let safeBounds = bounds.standardized
        let raw = frame.standardized
        let width = min(max(1, raw.width.isFinite ? raw.width : 1), max(1, safeBounds.width))
        let height = min(max(1, raw.height.isFinite ? raw.height : 1), max(1, safeBounds.height))
        let x = min(max(raw.minX.isFinite ? raw.minX : safeBounds.minX, safeBounds.minX), safeBounds.maxX - width)
        let y = min(max(raw.minY.isFinite ? raw.minY : safeBounds.minY, safeBounds.minY), safeBounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class CaptureOverlayView: NSView {
    let descriptor: ScreenDescriptor
    let sourceImage: NSImage
    let sourceCGImage: CGImage
    var selectionController: SelectionController {
        didSet {
            needsDisplay = true
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }

    var annotationStack: AnnotationCommandStack? {
        didSet {
            needsDisplay = true
            needsLayout = true
            refreshToolbarState()
        }
    }
    private(set) var annotationTool: AnnotationTool = .select
    private(set) var annotationColor: AnnotationColor = .defaultColor
    private(set) var annotationWidth: CGFloat = AnnotationStyle.default.width
    private(set) var textStyle: TextStyle = .default

    var crossDisplayHintVisible = false {
        didSet { needsDisplay = true }
    }

    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onCommandA: (() -> Void)?
    var onEscape: (() -> Void)?
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onColorSelected: ((AnnotationColor) -> Void)?
    var onWidthSelected: ((CGFloat) -> Void)?
    var onTextStyleSelected: ((TextStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onEditorAction: ((CaptureEditorAction) -> Void)?
    var onTextCommitted: ((String, CGRect) -> Void)?
    var onTextCancelled: (() -> Void)?

    private let dimAlpha: CGFloat = 0.45
    private let handleSize: CGFloat = 8
    private let toolbarLayoutEngine = ToolbarLayoutEngine(spacing: 10, edgeInset: 6)
    private let verticalToolbar: AnnotationToolbarView
    private let horizontalToolbar: AnnotationToolbarView
    private let textEditingSession = TextEditingSession()

    init(
        frame frameRect: NSRect,
        descriptor: ScreenDescriptor,
        sourceImage: CGImage,
        selectionController: SelectionController,
        initialColor: AnnotationColor = .defaultColor,
        initialWidth: CGFloat = AnnotationStyle.default.width,
        initialTextStyle: TextStyle = .default
    ) {
        self.descriptor = descriptor
        self.sourceCGImage = sourceImage
        self.sourceImage = NSImage(cgImage: sourceImage, size: frameRect.size)
        self.selectionController = selectionController
        self.annotationColor = initialColor
        self.annotationWidth = AnnotationStyle(color: initialColor, width: initialWidth).width
        self.textStyle = TextStyle(fontName: initialTextStyle.fontName, fontSize: initialTextStyle.fontSize, color: initialColor, alignment: initialTextStyle.alignment, lineSpacing: initialTextStyle.lineSpacing)
        self.verticalToolbar = AnnotationToolbarView(frame: .zero, orientation: .verticalTools)
        self.horizontalToolbar = AnnotationToolbarView(frame: .zero, orientation: .horizontalActions)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resize
        autoresizesSubviews = false
        setAccessibilityRole(.group)
        setAccessibilityLabel("VibeShot screenshot editor")
        setAccessibilityHelp("Select a region, choose an annotation tool, then use the action strip to finish.")
        verticalToolbar.onTool = { [weak self] tool in
            self?.onToolSelected?(tool)
        }
        verticalToolbar.onColor = { [weak self] color in
            self?.onColorSelected?(color)
        }
        verticalToolbar.onWidth = { [weak self] width in
            self?.onWidthSelected?(width)
        }
        verticalToolbar.onTextStyle = { [weak self] style in
            self?.onTextStyleSelected?(style)
        }
        verticalToolbar.onUndo = { [weak self] in self?.onUndo?() }
        verticalToolbar.onRedo = { [weak self] in self?.onRedo?() }
        horizontalToolbar.onAction = { [weak self] action in self?.onEditorAction?(action) }
        addSubview(verticalToolbar)
        addSubview(horizontalToolbar)
        verticalToolbar.isHidden = true
        horizontalToolbar.isHidden = true
        refreshToolbarState()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            window?.invalidateCursorRects(for: self)
        } else if textEditingSession.isActive {
            _ = textEditingSession.cancel()
        }
    }

    override func layout() {
        super.layout()
        guard let selection = selectionController.selectionRect else {
            verticalToolbar.isHidden = true
            horizontalToolbar.isHidden = true
            return
        }
        let layout = toolbarLayoutEngine.layout(
            selection: selection,
            visibleFrame: bounds,
            verticalSize: AnnotationToolbarView.preferredSize(for: .verticalTools),
            horizontalSize: AnnotationToolbarView.preferredSize(for: .horizontalActions)
        )
        verticalToolbar.frame = layout.verticalFrame
        horizontalToolbar.frame = layout.horizontalFrame
        nextKeyView = verticalToolbar
        verticalToolbar.nextKeyView = horizontalToolbar
        horizontalToolbar.nextKeyView = self
        verticalToolbar.isHidden = false
        horizontalToolbar.isHidden = false
        refreshToolbarState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let selection = selectionController.selectionRect
        let selectionPixels = selection.map { selectionController.geometry.imagePixelRect(for: DisplayLocalRect($0)) }
        if let context = NSGraphicsContext.current?.cgContext {
            AnnotationRenderer.draw(
                source: sourceCGImage,
                selection: selectionPixels,
                document: annotationStack?.document,
                in: context,
                destination: bounds,
                dimAlpha: dimAlpha
            )
        } else {
            // Keep a deterministic fallback for a transiently unavailable graphics context.
            sourceImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            NSColor.black.withAlphaComponent(dimAlpha).setFill()
            NSBezierPath(rect: bounds).fill()
        }

        if let selection {
            drawSelectionBorder(selection)
            drawHandles(selection)
            drawPixelBadge(selection)
        }

        if crossDisplayHintVisible {
            drawCrossDisplayHint()
        }
    }

    func setAnnotationState(tool: AnnotationTool, color: AnnotationColor, width: CGFloat, textStyle: TextStyle? = nil) {
        annotationTool = tool
        annotationColor = color
        annotationWidth = AnnotationStyle(color: color, width: width).width
        if let textStyle {
            self.textStyle = TextStyle(fontName: textStyle.fontName, fontSize: textStyle.fontSize, color: color, alignment: textStyle.alignment, lineSpacing: textStyle.lineSpacing)
        } else {
            self.textStyle = TextStyle(fontName: self.textStyle.fontName, fontSize: self.textStyle.fontSize, color: color, alignment: self.textStyle.alignment, lineSpacing: self.textStyle.lineSpacing)
        }
        refreshToolbarState()
        needsDisplay = true
    }

    func setEditorActionsEnabled(_ enabled: Bool, busy: Bool = false) {
        horizontalToolbar.setEditorActionsEnabled(enabled, busy: busy)
    }

    var isTextEditing: Bool { textEditingSession.isActive }

    @discardableResult
    func beginTextEditing(in destinationFrame: CGRect, style: TextStyle? = nil) -> Bool {
        let effectiveStyle = style ?? textStyle
        return textEditingSession.begin(
            in: self,
            frame: destinationFrame,
            style: effectiveStyle,
            onCommit: { [weak self] text, frame in
                self?.onTextCommitted?(text, frame)
                self?.needsDisplay = true
            },
            onCancel: { [weak self] in
                self?.onTextCancelled?()
                self?.needsDisplay = true
            }
        )
    }

    @discardableResult
    func commitTextEditing() -> Bool { textEditingSession.commit() }

    @discardableResult
    func cancelTextEditing() -> Bool { textEditingSession.cancel() }

    func refreshToolbarState() {
        let canUndo = annotationStack?.canUndo ?? false
        let canRedo = annotationStack?.canRedo ?? false
        verticalToolbar.setState(tool: annotationTool, color: annotationColor, width: annotationWidth, canUndo: canUndo, canRedo: canRedo, textStyle: textStyle)
        horizontalToolbar.setState(tool: annotationTool, color: annotationColor, width: annotationWidth, canUndo: canUndo, canRedo: canRedo, textStyle: textStyle)
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard let selection = selectionController.selectionRect else {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        let radius = handleSize
        for handle in SelectionHandle.allCases {
            let center = handleCenter(handle, in: selection)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let cursor: NSCursor
            switch handle {
            case .top, .bottom: cursor = .resizeUpDown
            case .left, .right: cursor = .resizeLeftRight
            case .topLeft, .topRight, .bottomRight, .bottomLeft: cursor = .arrow
            }
            addCursorRect(rect, cursor: cursor)
        }
        addCursorRect(selection, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onMouseDown?(globalPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(globalPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(globalPoint(for: event))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let route = CaptureKeyRouter.route(
            CaptureKeyInput(
                keyCode: event.keyCode,
                modifiers: flags.rawValue,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers
            ),
            textEditing: isTextEditing
        )
        switch route {
        case .textCancel:
            _ = cancelTextEditing()
        case .textCommit:
            _ = commitTextEditing()
        case .textNewline, .passThrough:
            // A text editor is normally first responder, so native commands never reach this
            // view. Preserve AppKit behavior for IME/focus transitions that do route a key here.
            super.keyDown(with: event)
        case .undo:
            onUndo?()
        case .redo:
            onRedo?()
        case .selectAll:
            onCommandA?()
        case .captureCancel:
            onEscape?()
        case .captureCopy:
            onEditorAction?(.copy)
        case .captureSave:
            onEditorAction?(.save)
        case .captureSaveAs:
            onEditorAction?(.saveAs)
        case .capturePrint:
            onEditorAction?(.print)
        }
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        if let window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    private func drawSelectionBorder(_ rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHandles(_ rect: CGRect) {
        for handle in SelectionHandle.allCases {
            let center = handleCenter(handle, in: rect)
            let handleRect = CGRect(
                x: center.x - handleSize / 2,
                y: center.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(rect: handleRect.insetBy(dx: -1, dy: -1)).fill()
            NSColor.white.setFill()
            NSBezierPath(rect: handleRect).fill()
        }
    }

    private func drawPixelBadge(_ rect: CGRect) {
        guard let dimensions = selectionController.pixelDimensions else { return }
        let text = "\(dimensions.width) × \(dimensions.height) px" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 4)
        var badge = CGRect(
            x: rect.midX - (textSize.width + padding.width * 2) / 2,
            y: rect.maxY + 8,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        if badge.maxY > bounds.maxY - 4 {
            badge.origin.y = rect.minY - badge.height - 8
        }
        badge.origin.x = min(max(badge.origin.x, bounds.minX + 4), bounds.maxX - badge.width - 4)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        text.draw(in: badge.insetBy(dx: padding.width, dy: padding.height), withAttributes: attributes)
    }

    private func drawCrossDisplayHint() {
        let text = "Selection is limited to one display" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let rect = CGRect(
            x: bounds.midX - size.width / 2 - 12,
            y: bounds.midY - size.height / 2 - 7,
            width: size.width + 24,
            height: size.height + 14
        )
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        text.draw(in: rect.insetBy(dx: 12, dy: 7), withAttributes: attributes)
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
