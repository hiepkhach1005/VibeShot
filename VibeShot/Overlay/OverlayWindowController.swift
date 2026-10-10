import AppKit
import CoreGraphics
import Foundation

/// Owns one borderless panel for one captured display. All panels are constructed by the session
/// consumer before any `show()` call so a partially-created overlay can never expose a live desktop.
@MainActor
final class CaptureOverlayWindowController: NSWindowController {
    let sessionID: UUID
    let snapshot: DisplaySnapshot
    let descriptor: ScreenDescriptor
    let overlayView: CaptureOverlayView

    var onMouseDown: ((CaptureOverlayWindowController, CGPoint) -> Void)?
    var onMouseDragged: ((CaptureOverlayWindowController, CGPoint) -> Void)?
    var onMouseUp: ((CaptureOverlayWindowController, CGPoint) -> Void)?
    var onCommandA: ((CaptureOverlayWindowController) -> Void)?
    var onEscape: ((CaptureOverlayWindowController) -> Void)?
    var onToolChanged: ((CaptureOverlayWindowController, AnnotationTool) -> Void)?
    var onColorChanged: ((CaptureOverlayWindowController, AnnotationColor) -> Void)?
    var onWidthChanged: ((CaptureOverlayWindowController, CGFloat) -> Void)?
    var onTextStyleChanged: ((CaptureOverlayWindowController, TextStyle) -> Void)?
    var onEditorAction: ((CaptureOverlayWindowController, CaptureEditorAction) -> Void)?
    var onCompletedSelectionChange: ((CaptureOverlayWindowController, DisplayLocalRect) -> Void)?

    private enum InteractionMode {
        case selection
        case annotation
        case textEditing
    }

    private var interactionMode: InteractionMode?
    private var selectionBeforeInteraction: DisplayLocalRect?
    private var gestureReducer: AnnotationGestureReducer?
    private(set) var annotationStack: AnnotationCommandStack?
    private(set) var annotationTool: AnnotationTool = .select
    private(set) var annotationColor: AnnotationColor
    private(set) var annotationWidth: CGFloat
    private(set) var textStyle: TextStyle

    init(
        sessionID: UUID,
        snapshot: DisplaySnapshot,
        initialColor: AnnotationColor = .defaultColor,
        initialWidth: CGFloat = AnnotationStyle.default.width,
        initialTextStyle: TextStyle = .default
    ) {
        self.sessionID = sessionID
        self.snapshot = snapshot
        self.descriptor = snapshot.descriptor
        self.annotationColor = initialColor
        self.annotationWidth = AnnotationStyle(color: initialColor, width: initialWidth).width
        self.textStyle = TextStyle(fontName: initialTextStyle.fontName, fontSize: initialTextStyle.fontSize, color: initialColor, alignment: initialTextStyle.alignment, lineSpacing: initialTextStyle.lineSpacing)
        let frame = descriptor.frame.rect
        let geometry = DisplayGeometry(descriptor: descriptor, imageSize: snapshot.pixelSize)
        let selectionController = SelectionController(
            displayBounds: CGRect(origin: .zero, size: frame.size),
            geometry: geometry
        )
        self.overlayView = CaptureOverlayView(
            frame: NSRect(origin: .zero, size: frame.size),
            descriptor: descriptor,
            sourceImage: snapshot.image,
            selectionController: selectionController,
            initialColor: initialColor,
            initialWidth: initialWidth,
            initialTextStyle: initialTextStyle
        )

        let panel = CaptureOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = overlayView
        super.init(window: panel)

        overlayView.onMouseDown = { [weak self] point in
            guard let self else { return }
            self.onMouseDown?(self, point)
        }
        overlayView.onMouseDragged = { [weak self] point in
            guard let self else { return }
            self.onMouseDragged?(self, point)
        }
        overlayView.onMouseUp = { [weak self] point in
            guard let self else { return }
            self.onMouseUp?(self, point)
        }
        overlayView.onCommandA = { [weak self] in
            guard let self else { return }
            self.onCommandA?(self)
        }
        overlayView.onEscape = { [weak self] in
            guard let self else { return }
            self.onEscape?(self)
        }
        overlayView.onToolSelected = { [weak self] tool in
            guard let self else { return }
            self.setTool(tool)
            self.onToolChanged?(self, tool)
        }
        overlayView.onColorSelected = { [weak self] color in
            guard let self else { return }
            self.setColor(color)
            self.onColorChanged?(self, color)
        }
        overlayView.onWidthSelected = { [weak self] width in
            guard let self else { return }
            self.setWidth(width)
            self.onWidthChanged?(self, width)
        }
        overlayView.onTextStyleSelected = { [weak self] style in
            guard let self else { return }
            self.setTextStyle(style)
            self.onTextStyleChanged?(self, self.textStyle)
        }
        overlayView.onTextCommitted = { [weak self] text, destination in
            self?.commitText(text: text, destinationRect: destination)
        }
        overlayView.onTextCancelled = { [weak self] in
            self?.overlayView.needsDisplay = true
        }
        overlayView.onEditorAction = { [weak self] action in
            guard let self else { return }
            self.onEditorAction?(self, action)
        }
        overlayView.onUndo = { [weak self] in self?.undoAnnotation() }
        overlayView.onRedo = { [weak self] in self?.redoAnnotation() }
        overlayView.setAnnotationState(tool: annotationTool, color: annotationColor, width: annotationWidth, textStyle: textStyle)
        // M6 handlers are installed by the session consumer. The toolbar is enabled here so the
        // typed action seam is also available to keyboard routing as soon as a selection exists.
        overlayView.setEditorActionsEnabled(true)
        overlayView.needsLayout = true
    }

    required init?(coder: NSCoder) { nil }

    var selection: DisplayLocalRect? { overlayView.selectionController.selection }
    var pixelDimensions: PixelSize? { overlayView.selectionController.pixelDimensions }

    func setEditorActionsEnabled(_ enabled: Bool, busy: Bool = false) {
        overlayView.setEditorActionsEnabled(enabled, busy: busy)
    }
    var isInteracting: Bool { interactionMode != nil }
    var hasTransientAnnotation: Bool {
        overlayView.isTextEditing || gestureReducer?.isActive == true || overlayView.annotationStack?.document.transient != nil
    }

    /// Takes the immutable source/selection/vector value snapshot used by all M6 actions. A
    /// transient pen gesture or in-place text editor is deliberately omitted by ExportInput.
    func makeExportInput() throws -> ExportInput {
        guard let selection = overlayView.selectionController.selection else {
            throw ExportError.noSelection
        }
        return try ExportInput(
            snapshot: snapshot,
            selection: selection,
            document: annotationStack?.document
        )
    }

    var actionPresentationView: NSView { overlayView }

    func show() {
        guard let window else { return }
        window.setFrame(descriptor.frame.rect, display: false)
        window.makeKeyAndOrderFront(nil)
    }

    func closeOverlay() {
        _ = overlayView.cancelTextEditing()
        releaseAnnotationDocument()
        window?.orderOut(nil)
        window?.close()
    }

    @discardableResult
    func beginInteraction(at globalPoint: CGPoint) -> SelectionHit {
        let point = localPoint(globalPoint)
        if annotationTool != .select {
            guard let selection = overlayView.selectionController.selectionRect, selection.contains(point) else {
                interactionMode = nil
                return .outside
            }
            ensureAnnotationDocument()
            guard let annotationStack else { return .outside }
            if annotationTool == .text {
                let frame = textDestinationFrame(startingAt: point, in: selection)
                guard overlayView.beginTextEditing(in: frame, style: textStyle) else {
                    interactionMode = nil
                    return .outside
                }
                interactionMode = .textEditing
                overlayView.crossDisplayHintVisible = false
                overlayView.needsDisplay = true
                return .body
            }
            let reducer = gestureReducer ?? AnnotationGestureReducer(canvasBounds: annotationStack.document.canvasBounds)
            let transform = CanvasTransform(canvasBounds: annotationStack.document.canvasBounds, destination: selection)
            var next = reducer
            guard next.begin(tool: annotationTool, style: currentStyle, at: transform.canvasPoint(from: point)) else {
                interactionMode = nil
                return .outside
            }
            gestureReducer = next
            annotationStack.setTransient(next.transient)
            interactionMode = .annotation
            overlayView.crossDisplayHintVisible = false
            overlayView.needsDisplay = true
            return .body
        }

        if overlayView.selectionController.selectionRect != nil,
           !overlayView.selectionController.hitTest(point).isInside {
            // Starting a fresh selection also starts a fresh annotation document. The old vector
            // values are immutable and are released with this selection rather than remapped into
            // an unrelated crop.
            releaseAnnotationDocument()
        }
        selectionBeforeInteraction = overlayView.selectionController.selection
        let hit = overlayView.selectionController.begin(at: point)
        interactionMode = .selection
        overlayView.crossDisplayHintVisible = false
        overlayView.needsDisplay = true
        window?.invalidateCursorRects(for: overlayView)
        return hit
    }

    func updateInteraction(at globalPoint: CGPoint) {
        let point = localPoint(globalPoint)
        switch interactionMode {
        case .selection:
            overlayView.selectionController.update(to: point)
            overlayView.crossDisplayHintVisible = !descriptor.frame.rect.contains(globalPoint)
        case .annotation:
            guard let selection = overlayView.selectionController.selectionRect,
                  let annotationStack,
                  var reducer = gestureReducer
            else { return }
            let transform = CanvasTransform(canvasBounds: annotationStack.document.canvasBounds, destination: selection)
            _ = reducer.update(to: transform.canvasPoint(from: point))
            gestureReducer = reducer
            annotationStack.setTransient(reducer.transient)
            overlayView.crossDisplayHintVisible = false
        case .textEditing:
            // The editor owns its own key/focus lifecycle. A drag after the initial click does not
            // become a vector gesture and is intentionally ignored.
            return
        case nil:
            return
        }
        overlayView.needsDisplay = true
        overlayView.needsLayout = true
        window?.invalidateCursorRects(for: overlayView)
    }

    @discardableResult
    func endInteraction(at globalPoint: CGPoint) -> DisplayLocalRect? {
        updateInteraction(at: globalPoint)
        let result: DisplayLocalRect?
        switch interactionMode {
        case .selection:
            result = overlayView.selectionController.endInteraction()
            ensureAnnotationDocument()
            if let result, result != selectionBeforeInteraction {
                onCompletedSelectionChange?(self, result)
            }
        case .annotation:
            if var reducer = gestureReducer {
                let item = reducer.end()
                gestureReducer = reducer
                annotationStack?.clearTransient()
                if let item { _ = annotationStack?.add(item) }
            }
            result = overlayView.selectionController.selection
        case .textEditing:
            result = overlayView.selectionController.selection
        case nil:
            result = overlayView.selectionController.selection
        }
        interactionMode = nil
        selectionBeforeInteraction = nil
        overlayView.crossDisplayHintVisible = false
        overlayView.needsDisplay = true
        overlayView.needsLayout = true
        overlayView.refreshToolbarState()
        window?.invalidateCursorRects(for: overlayView)
        return result
    }

    func selectAll() {
        let previous = selection
        overlayView.selectionController.selectAll()
        ensureAnnotationDocument()
        overlayView.needsDisplay = true
        overlayView.needsLayout = true
        window?.invalidateCursorRects(for: overlayView)
        if let selection, selection != previous { onCompletedSelectionChange?(self, selection) }
    }

    @discardableResult
    func restoreSelection(_ rect: DisplayLocalRect) -> Bool {
        guard overlayView.selectionController.restoreSelection(rect) else { return false }
        releaseAnnotationDocument()
        ensureAnnotationDocument()
        overlayView.needsDisplay = true
        overlayView.needsLayout = true
        overlayView.refreshToolbarState()
        return true
    }

    func clearSelection() {
        releaseAnnotationDocument()
        overlayView.selectionController.clear()
        overlayView.crossDisplayHintVisible = false
        overlayView.needsDisplay = true
        overlayView.needsLayout = true
        window?.invalidateCursorRects(for: overlayView)
    }

    func setTool(_ tool: AnnotationTool) {
        if overlayView.isTextEditing {
            _ = overlayView.commitTextEditing()
        }
        if tool != annotationTool, gestureReducer?.isActive == true {
            _ = cancelTransient()
        }
        annotationTool = tool
        overlayView.setAnnotationState(tool: annotationTool, color: annotationColor, width: annotationWidth, textStyle: textStyle)
    }

    func setColor(_ color: AnnotationColor) {
        annotationColor = color
        textStyle = TextStyle(fontName: textStyle.fontName, fontSize: textStyle.fontSize, color: color, alignment: textStyle.alignment, lineSpacing: textStyle.lineSpacing)
        overlayView.setAnnotationState(tool: annotationTool, color: annotationColor, width: annotationWidth, textStyle: textStyle)
    }

    func setWidth(_ width: CGFloat) {
        annotationWidth = AnnotationStyle(color: annotationColor, width: width).width
        overlayView.setAnnotationState(tool: annotationTool, color: annotationColor, width: annotationWidth, textStyle: textStyle)
    }

    func setTextStyle(_ style: TextStyle) {
        textStyle = TextStyle(fontName: style.fontName, fontSize: style.fontSize, color: annotationColor, alignment: style.alignment, lineSpacing: style.lineSpacing)
        overlayView.setAnnotationState(tool: annotationTool, color: annotationColor, width: annotationWidth, textStyle: textStyle)
    }

    @discardableResult
    func undoAnnotation() -> Bool {
        let result = annotationStack?.undo() ?? false
        if result {
            overlayView.needsDisplay = true
            overlayView.refreshToolbarState()
        }
        return result
    }

    @discardableResult
    func redoAnnotation() -> Bool {
        let result = annotationStack?.redo() ?? false
        if result {
            overlayView.needsDisplay = true
            overlayView.refreshToolbarState()
        }
        return result
    }

    /// Escape consumes an in-progress vector first. A true result keeps the capture session alive.
    @discardableResult
    func cancelTransient() -> Bool {
        if overlayView.isTextEditing {
            return overlayView.cancelTextEditing()
        }
        guard hasTransientAnnotation else { return false }
        gestureReducer?.cancel()
        gestureReducer = nil
        annotationStack?.clearTransient()
        interactionMode = nil
        overlayView.needsDisplay = true
        overlayView.refreshToolbarState()
        return true
    }

    /// Explicitly releases the document before panel teardown so a full-resolution session does
    /// not retain annotation state after cancel/deactivation/display-change cleanup.
    func releaseAnnotationDocument() {
        _ = overlayView.cancelTextEditing()
        gestureReducer?.cancel()
        gestureReducer = nil
        interactionMode = nil
        annotationStack = nil
        overlayView.annotationStack = nil
    }

    private var currentStyle: AnnotationStyle {
        AnnotationStyle(color: annotationColor, width: annotationWidth)
    }

    private func ensureAnnotationDocument() {
        guard let selection = overlayView.selectionController.selectionRect else { return }
        if annotationStack == nil {
            let document = AnnotationDocument(canvasBounds: CanvasRect(selection))
            annotationStack = AnnotationCommandStack(document: document)
            gestureReducer = AnnotationGestureReducer(canvasBounds: document.canvasBounds)
            overlayView.annotationStack = annotationStack
        }
        overlayView.refreshToolbarState()
        overlayView.needsLayout = true
    }

    private func textDestinationFrame(startingAt point: CGPoint, in selection: CGRect) -> CGRect {
        let availableWidth = max(1, selection.maxX - point.x)
        let availableHeight = max(1, selection.maxY - point.y)
        let width = min(availableWidth, max(32, min(240, selection.width * 0.72)))
        let height = min(availableHeight, max(28, min(120, selection.height * 0.28)))
        let x = min(max(point.x, selection.minX), selection.maxX - width)
        let y = min(max(point.y, selection.minY), selection.maxY - height)
        return CGRect(x: x, y: y, width: max(1, width), height: max(1, height))
    }

    private func commitText(text: String, destinationRect: CGRect) {
        guard let selection = overlayView.selectionController.selectionRect,
              let annotationStack,
              !TextSanitizer.isBlank(text)
        else { return }
        let transform = CanvasTransform(canvasBounds: annotationStack.document.canvasBounds, destination: selection)
        let canvasRect = transform.canvasRect(from: destinationRect)
        guard !canvasRect.isEmpty else { return }
        let annotation = TextAnnotation(
            origin: CanvasPoint(x: canvasRect.minX, y: canvasRect.minY),
            bounds: canvasRect,
            text: text,
            style: textStyle
        )
        _ = annotationStack.add(.text(annotation))
        overlayView.needsDisplay = true
        overlayView.refreshToolbarState()
    }

    private func localPoint(_ globalPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: globalPoint.x - descriptor.frame.rect.minX,
            y: globalPoint.y - descriptor.frame.rect.minY
        )
    }
}
