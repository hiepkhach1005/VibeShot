import AppKit
import Foundation

/// Compact final toolbar. The vertical strip owns annotation tools and remembered style controls;
/// the horizontal strip is a typed M6 action seam. The older `.horizontalStyle` orientation
/// remains source-compatible for focused M4 callers while the overlay uses `.horizontalActions`.
///
/// Native `toolTip`s are not used: the capture overlay runs at `.screenSaver` level, which sits
/// above the system tooltip window, so hover help is drawn by `ToolbarTooltipView` in the
/// toolbar's superview instead.
@MainActor
final class AnnotationToolbarView: NSView {
    enum Orientation {
        case verticalTools
        case horizontalStyle
        case horizontalActions
    }

    static let buttonSize: CGFloat = 30
    static let buttonSpacing: CGFloat = 2
    static let inset: CGFloat = 5

    /// The natural size for an orientation, so overlay callers do not hard-code button counts.
    static func preferredSize(for orientation: Orientation) -> CGSize {
        let count: Int
        switch orientation {
        case .verticalTools: count = AnnotationTool.allCases.count + 3
        case .horizontalStyle: count = 6 + 4 + 2
        case .horizontalActions: count = CaptureEditorAction.allCases.count
        }
        let length = inset * 2 + CGFloat(count) * buttonSize + CGFloat(max(count - 1, 0)) * buttonSpacing
        let thickness = inset * 2 + buttonSize
        switch orientation {
        case .verticalTools: return CGSize(width: thickness, height: length)
        case .horizontalStyle, .horizontalActions: return CGSize(width: length, height: thickness)
        }
    }

    var onTool: ((AnnotationTool) -> Void)?
    var onColor: ((AnnotationColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onTextStyle: ((TextStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onAction: ((CaptureEditorAction) -> Void)?

    private var toolButtons: [(AnnotationTool, ToolbarIconButton)] = []
    private var colorButtons: [(AnnotationColor, ToolbarIconButton)] = []
    private var widthButtons: [(CGFloat, ToolbarIconButton)] = []
    private var actionButtons: [(CaptureEditorAction, ToolbarIconButton)] = []
    private var colorButton: ToolbarIconButton?
    private var styleButton: ToolbarIconButton?
    private var undoButton: ToolbarIconButton?
    private var redoButton: ToolbarIconButton?
    private var selectedTool: AnnotationTool = .select
    private var selectedColor: AnnotationColor = .defaultColor
    private var selectedWidth: CGFloat = AnnotationStyle.default.width
    private var selectedTextStyle: TextStyle = .default
    private var m6ActionsEnabled = false
    private var tooltipView: ToolbarTooltipView?

    let orientation: Orientation

    init(frame frameRect: NSRect, orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        appearance = NSAppearance(named: .darkAqua)
        translatesAutoresizingMaskIntoConstraints = true
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("VibeShot annotation toolbar")
        buildButtons()
        rebuildFocusChain()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override var isHidden: Bool {
        didSet { if isHidden { hideTooltip() } }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        hideTooltip()
    }

    func setState(
        tool: AnnotationTool,
        color: AnnotationColor,
        width: CGFloat,
        canUndo: Bool,
        canRedo: Bool,
        textStyle: TextStyle = .default
    ) {
        selectedTool = tool
        selectedColor = color
        selectedWidth = width
        selectedTextStyle = textStyle.sanitized
        for (value, button) in toolButtons {
            let selected = value == tool
            button.state = selected ? .on : .off
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
        for (value, button) in colorButtons {
            let selected = value == color
            button.state = selected ? .on : .off
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
        for (value, button) in widthButtons {
            let selected = abs(value - width) < 0.01
            button.state = selected ? .on : .off
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
        if let colorButton {
            colorButton.swatchColor = color.nsColor
            colorButton.hoverTitle = "Color: \(colorName(color))"
            colorButton.setAccessibilityValue(colorName(color))
        }
        if let styleButton {
            let isText = tool == .text
            styleButton.symbolName = isText ? "textformat.size" : "lineweight"
            styleButton.hoverTitle = isText
                ? "Text size: \(Int(selectedTextStyle.fontSize)) pt"
                : "Stroke width: \(Int(width)) pt"
            styleButton.setAccessibilityValue(styleButton.hoverTitle)
        }
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
        undoButton?.setAccessibilityValue(canUndo ? "Available" : "Unavailable")
        redoButton?.setAccessibilityValue(canRedo ? "Available" : "Unavailable")
        if let tooltipView, let button = tooltipView.anchor { showTooltip(for: button) }
    }

    func setEditorActionsEnabled(_ enabled: Bool, busy: Bool = false) {
        m6ActionsEnabled = enabled
        for (action, button) in actionButtons where action.isM6Action {
            button.isEnabled = enabled
            button.setAccessibilityValue(enabled ? "Available" : (busy ? "Exporting" : "Unavailable until export actions are installed"))
        }
        if let cancel = actionButtons.first(where: { $0.0 == .cancel })?.1 {
            cancel.isEnabled = true
            cancel.setAccessibilityValue("Available")
        }
    }

    override func layout() {
        super.layout()
        let size = Self.buttonSize
        let step = size + Self.buttonSpacing
        let inset = Self.inset
        switch orientation {
        case .verticalTools:
            let controls = toolButtons.map(\.1) + [colorButton, styleButton, undoButton].compactMap { $0 }
            let x = (bounds.width - size) / 2
            for (index, button) in controls.enumerated() {
                button.frame = CGRect(x: x, y: bounds.height - inset - size - CGFloat(index) * step, width: size, height: size)
            }
        case .horizontalStyle, .horizontalActions:
            let controls = colorButtons.map(\.1) + widthButtons.map(\.1) + [undoButton, redoButton].compactMap { $0 } + actionButtons.map(\.1)
            let y = (bounds.height - size) / 2
            for (index, button) in controls.enumerated() {
                button.frame = CGRect(x: inset + CGFloat(index) * step, y: y, width: size, height: size)
            }
        }
    }

    private func buildButtons() {
        switch orientation {
        case .verticalTools:
            for tool in AnnotationTool.allCases {
                let button = makeButton(symbol: symbol(for: tool), title: hoverTitle(for: tool), label: tool.displayName, help: "Choose \(tool.displayName.lowercased()) annotation tool")
                button.setButtonType(.toggle)
                button.showsSelection = true
                button.target = self
                button.action = #selector(toolPressed(_:))
                toolButtons.append((tool, button))
                addSubview(button)
            }
            let color = makeButton(symbol: nil, title: "Color", label: "Color", help: "Choose annotation color")
            color.hoverDetail = "Click to change"
            color.target = self
            color.action = #selector(colorCyclePressed)
            colorButton = color
            addSubview(color)

            let style = makeButton(symbol: "lineweight", title: "Stroke width", label: "Style", help: "Choose stroke width or text style")
            style.hoverDetail = "Click to change"
            style.target = self
            style.action = #selector(stylePressed)
            styleButton = style
            addSubview(style)

            let undo = makeButton(symbol: "arrow.uturn.backward", title: "Undo", label: "Undo", help: "Undo the latest annotation (Command-Z)")
            undo.hoverDetail = "⌘Z"
            undo.target = self
            undo.action = #selector(undoPressed)
            undoButton = undo
            addSubview(undo)
        case .horizontalStyle:
            let colors: [(AnnotationColor, String)] = [
                (.defaultColor, "Red"), (.yellow, "Yellow"), (.green, "Green"), (.blue, "Blue"), (.black, "Black"), (.white, "White")
            ]
            for (color, name) in colors {
                let button = makeButton(symbol: nil, title: name, label: "Color: \(name)", help: "Use \(name.lowercased()) annotation color")
                button.swatchColor = color.nsColor
                button.tag = colorButtons.count
                button.setButtonType(.toggle)
                button.showsSelection = true
                button.target = self
                button.action = #selector(colorPressed(_:))
                colorButtons.append((color, button))
                addSubview(button)
            }
            for width in [CGFloat(1), 3, 6, 10] {
                let button = makeButton(symbol: "lineweight", title: "\(Int(width)) pt stroke", label: "Width \(Int(width))", help: "Use \(Int(width))-point stroke width")
                button.tag = widthButtons.count
                button.setButtonType(.toggle)
                button.showsSelection = true
                button.target = self
                button.action = #selector(widthPressed(_:))
                widthButtons.append((width, button))
                addSubview(button)
            }
            addUndoRedoButtons()
        case .horizontalActions:
            for action in CaptureEditorAction.allCases {
                let button = makeButton(symbol: symbol(for: action), title: hoverTitle(for: action), label: action.displayName, help: help(for: action))
                button.hoverDetail = shortcut(for: action)
                if action == .cancel { button.iconColor = NSColor.systemRed }
                button.tag = actionButtons.count
                button.target = self
                button.action = #selector(actionPressed(_:))
                actionButtons.append((action, button))
                addSubview(button)
            }
            setEditorActionsEnabled(false)
        }
    }

    private func addUndoRedoButtons() {
        let undo = makeButton(symbol: "arrow.uturn.backward", title: "Undo", label: "Undo", help: "Undo the latest annotation")
        undo.hoverDetail = "⌘Z"
        undo.target = self
        undo.action = #selector(undoPressed)
        undoButton = undo
        addSubview(undo)
        let redo = makeButton(symbol: "arrow.uturn.forward", title: "Redo", label: "Redo", help: "Redo the latest annotation")
        redo.hoverDetail = "⇧⌘Z"
        redo.target = self
        redo.action = #selector(redoPressed)
        redoButton = redo
        addSubview(redo)
    }

    private func makeButton(symbol: String?, title: String, label: String, help: String) -> ToolbarIconButton {
        let button = ToolbarIconButton(symbolName: symbol, hoverTitle: title)
        button.onHoverChange = { [weak self] button, hovering in
            if hovering { self?.showTooltip(for: button) } else { self?.hideTooltip(for: button) }
        }
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(help)
        return button
    }

    private func symbol(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .pen: "scribble.variable"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .marker: "highlighter"
        case .text: "textformat"
        }
    }

    private func hoverTitle(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "Select & move"
        case .pen: "Pen"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .marker: "Highlighter"
        case .text: "Text"
        }
    }

    private func symbol(for action: CaptureEditorAction) -> String {
        switch action {
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .saveAs: "square.and.arrow.down.on.square"
        case .share: "square.and.arrow.up"
        case .print: "printer"
        case .cancel: "xmark"
        }
    }

    private func hoverTitle(for action: CaptureEditorAction) -> String {
        switch action {
        case .copy: "Copy to clipboard"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .share: "Share…"
        case .print: "Print…"
        case .cancel: "Cancel capture"
        }
    }

    private func shortcut(for action: CaptureEditorAction) -> String? {
        switch action {
        case .copy: "⌘C"
        case .save: "⌘S"
        case .saveAs: "⇧⌘S"
        case .share: nil
        case .print: "⌘P"
        case .cancel: "Esc"
        }
    }

    private func help(for action: CaptureEditorAction) -> String {
        action.isM6Action ? action.displayName : "Cancel this capture"
    }

    private func colorName(_ color: AnnotationColor) -> String {
        if color == .defaultColor { return "Red" }
        if color == .yellow { return "Yellow" }
        if color == .green { return "Green" }
        if color == .blue { return "Blue" }
        if color == .black { return "Black" }
        if color == .white { return "White" }
        return "Custom"
    }

    private func rebuildFocusChain() {
        let buttons = subviews.compactMap { $0 as? NSButton }
        for (index, button) in buttons.enumerated() {
            button.nextKeyView = buttons.indices.contains(index + 1) ? buttons[index + 1] : nil
        }
    }

    // MARK: Hover tooltip

    private func showTooltip(for button: ToolbarIconButton) {
        guard let host = superview, !isHidden else { return }
        let tooltip = tooltipView ?? ToolbarTooltipView()
        if tooltip.superview !== host {
            tooltip.removeFromSuperview()
            host.addSubview(tooltip, positioned: .above, relativeTo: self)
        }
        tooltipView = tooltip
        tooltip.anchor = button
        tooltip.setText(title: button.hoverTitle, detail: button.hoverDetail)
        let size = tooltip.fittingSize
        let anchor = button.convert(button.bounds, to: host)
        let gap: CGFloat = 8
        var origin: CGPoint
        switch orientation {
        case .verticalTools:
            origin = CGPoint(x: frame.minX - gap - size.width, y: anchor.midY - size.height / 2)
            if origin.x < host.bounds.minX { origin.x = frame.maxX + gap }
        case .horizontalStyle, .horizontalActions:
            origin = CGPoint(x: anchor.midX - size.width / 2, y: frame.maxY + gap)
            if origin.y + size.height > host.bounds.maxY { origin.y = frame.minY - gap - size.height }
        }
        origin.x = min(max(origin.x, host.bounds.minX + 4), host.bounds.maxX - size.width - 4)
        origin.y = min(max(origin.y, host.bounds.minY + 4), host.bounds.maxY - size.height - 4)
        tooltip.frame = CGRect(origin: origin, size: size)
        tooltip.isHidden = false
    }

    private func hideTooltip(for button: ToolbarIconButton? = nil) {
        guard let tooltipView else { return }
        if let button, tooltipView.anchor !== button { return }
        tooltipView.anchor = nil
        tooltipView.isHidden = true
    }

    private var palette: [AnnotationColor] { [.defaultColor, .yellow, .green, .blue, .black, .white] }
    private var textSizes: [CGFloat] { [12, 16, 20, 28] }

    @objc private func toolPressed(_ sender: NSButton) {
        // Resolve by the button object instead of relying on NSControl.tag. The vertical tool
        // buttons are built from a typed `(AnnotationTool, NSButton)` mapping, and a missing or
        // stale tag would otherwise silently route every click to `.select` (the default tag is
        // zero). This also remains correct if the visual order changes later.
        guard let tool = toolButtons.first(where: { $0.1 === sender })?.0 else { return }
        onTool?(tool)
    }

    @objc private func colorPressed(_ sender: NSButton) {
        guard colorButtons.indices.contains(sender.tag) else { return }
        onColor?(colorButtons[sender.tag].0)
    }

    @objc private func widthPressed(_ sender: NSButton) {
        guard widthButtons.indices.contains(sender.tag) else { return }
        onWidth?(widthButtons[sender.tag].0)
    }

    @objc private func colorCyclePressed() {
        let index = palette.firstIndex(of: selectedColor) ?? 0
        onColor?(palette[(index + 1) % palette.count])
    }

    @objc private func stylePressed() {
        if selectedTool == .text {
            let index = textSizes.firstIndex(of: selectedTextStyle.fontSize) ?? 1
            onTextStyle?(TextStyle(fontName: selectedTextStyle.fontName, fontSize: textSizes[(index + 1) % textSizes.count], color: selectedColor, alignment: selectedTextStyle.alignment, lineSpacing: selectedTextStyle.lineSpacing))
        } else {
            let widths: [CGFloat] = [1, 3, 6, 10]
            let index = widths.firstIndex(where: { abs($0 - selectedWidth) < 0.01 }) ?? 1
            onWidth?(widths[(index + 1) % widths.count])
        }
    }

    @objc private func undoPressed() { onUndo?() }
    @objc private func redoPressed() { onRedo?() }

    @objc private func actionPressed(_ sender: NSButton) {
        guard actionButtons.indices.contains(sender.tag) else { return }
        let action = actionButtons[sender.tag].0
        guard action == .cancel || m6ActionsEnabled else { return }
        onAction?(action)
    }
}

/// Borderless icon button with hover/pressed/selected backgrounds drawn by hand so it reads well
/// on the dark overlay toolbar regardless of the system appearance.
@MainActor
final class ToolbarIconButton: NSButton {
    var symbolName: String? { didSet { if symbolName != oldValue { needsDisplay = true } } }
    var swatchColor: NSColor? { didSet { needsDisplay = true } }
    var iconColor: NSColor? { didSet { needsDisplay = true } }
    var showsSelection = false
    var hoverTitle: String
    var hoverDetail: String?
    var onHoverChange: ((ToolbarIconButton, Bool) -> Void)?

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var hoverArea: NSTrackingArea?

    init(symbolName: String?, hoverTitle: String) {
        self.symbolName = symbolName
        self.hoverTitle = hoverTitle
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChange?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChange?(self, false)
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = showsSelection && state == .on
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        if selected {
            NSColor.controlAccentColor.setFill()
            path.fill()
        } else if isEnabled && (isHighlighted || isHovered) {
            NSColor(white: 1, alpha: isHighlighted ? 0.22 : 0.12).setFill()
            path.fill()
        }

        let alpha: CGFloat = isEnabled ? 1 : 0.32
        if let swatchColor {
            let diameter: CGFloat = 16
            let circle = NSBezierPath(ovalIn: CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter))
            swatchColor.withAlphaComponent(alpha).setFill()
            circle.fill()
            NSColor(white: 1, alpha: 0.85 * alpha).setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            return
        }

        guard let symbolName else { return }
        let tint = (selected ? NSColor.white : (iconColor ?? NSColor(white: 0.94, alpha: 1))).withAlphaComponent(alpha)
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(in: rect.integral, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Small dark hover label drawn inside the overlay, above the toolbar that owns it.
@MainActor
final class ToolbarTooltipView: NSView {
    weak var anchor: ToolbarIconButton?
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.96).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(title: String, detail: String?) {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ])
        if let detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "  \(detail)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(white: 1, alpha: 0.55)
            ]))
        }
        label.attributedStringValue = text
    }
}
