import AppKit
import Foundation

/// Compact final toolbar. The vertical strip owns annotation tools and remembered style controls;
/// the horizontal strip is a typed M6 action seam. The older `.horizontalStyle` orientation
/// remains source-compatible for focused M4 callers while the overlay uses `.horizontalActions`.
@MainActor
final class AnnotationToolbarView: NSView {
    enum Orientation {
        case verticalTools
        case horizontalStyle
        case horizontalActions
    }

    var onTool: ((AnnotationTool) -> Void)?
    var onColor: ((AnnotationColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onTextStyle: ((TextStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onAction: ((CaptureEditorAction) -> Void)?

    private var toolButtons: [(AnnotationTool, NSButton)] = []
    private var colorButtons: [(AnnotationColor, NSButton)] = []
    private var widthButtons: [(CGFloat, NSButton)] = []
    private var actionButtons: [(CaptureEditorAction, NSButton)] = []
    private var colorButton: NSButton?
    private var styleButton: NSButton?
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var selectedTool: AnnotationTool = .select
    private var selectedColor: AnnotationColor = .defaultColor
    private var selectedWidth: CGFloat = AnnotationStyle.default.width
    private var selectedTextStyle: TextStyle = .default
    private var m6ActionsEnabled = false

    let orientation: Orientation

    init(frame frameRect: NSRect, orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor
        translatesAutoresizingMaskIntoConstraints = true
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("VibeShot annotation toolbar")
        buildButtons()
        rebuildFocusChain()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

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
            button.layer?.borderWidth = selected ? 2 : 0
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
        for (value, button) in widthButtons {
            let selected = abs(value - width) < 0.01
            button.state = selected ? .on : .off
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
        colorButton?.contentTintColor = color.nsColor
        colorButton?.setAccessibilityValue(colorName(color))
        styleButton?.title = styleTitle(textStyle: selectedTextStyle, width: width)
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
        undoButton?.setAccessibilityValue(canUndo ? "Available" : "Unavailable")
        redoButton?.setAccessibilityValue(canRedo ? "Available" : "Unavailable")
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
        switch orientation {
        case .verticalTools:
            let inset: CGFloat = 4
            let controls = toolButtons.map(\.1) + [colorButton, styleButton, undoButton].compactMap { $0 }
            let height = max(0, (bounds.height - inset * 2) / CGFloat(max(controls.count, 1)))
            for (index, button) in controls.enumerated() {
                button.frame = CGRect(x: inset, y: bounds.height - inset - CGFloat(index + 1) * height, width: bounds.width - inset * 2, height: height)
            }
        case .horizontalStyle:
            let inset: CGFloat = 4
            let buttonHeight = max(0, bounds.height - inset * 2)
            var x = inset
            for (_, button) in colorButtons {
                button.frame = CGRect(x: x, y: inset, width: 24, height: buttonHeight)
                x += 25
            }
            x += 2
            for (_, button) in widthButtons {
                button.frame = CGRect(x: x, y: inset, width: 25, height: buttonHeight)
                x += 26
            }
            x += 2
            if let undoButton {
                undoButton.frame = CGRect(x: x, y: inset, width: 30, height: buttonHeight)
                x += 31
            }
            if let redoButton {
                redoButton.frame = CGRect(x: x, y: inset, width: 30, height: buttonHeight)
            }
        case .horizontalActions:
            let inset: CGFloat = 4
            let height = max(0, bounds.height - inset * 2)
            let width = max(0, (bounds.width - inset * 2) / CGFloat(max(actionButtons.count, 1)))
            for (index, (_, button)) in actionButtons.enumerated() {
                button.frame = CGRect(x: inset + CGFloat(index) * width, y: inset, width: width, height: height)
            }
        }
    }

    private func buildButtons() {
        switch orientation {
        case .verticalTools:
            for tool in AnnotationTool.allCases {
                let button = makeButton(title: title(for: tool), label: tool.displayName, help: "Choose \(tool.displayName.lowercased()) annotation tool")
                button.setButtonType(.toggle)
                button.target = self
                button.action = #selector(toolPressed(_:))
                toolButtons.append((tool, button))
                addSubview(button)
            }
            let color = makeButton(title: "●", label: "Color", help: "Choose annotation color")
            color.target = self
            color.action = #selector(colorCyclePressed)
            colorButton = color
            addSubview(color)

            let style = makeButton(title: "A", label: "Style", help: "Choose stroke width or text style")
            style.target = self
            style.action = #selector(stylePressed)
            styleButton = style
            addSubview(style)

            let undo = makeButton(title: "↶", label: "Undo", help: "Undo the latest annotation (Command-Z)")
            undo.target = self
            undo.action = #selector(undoPressed)
            undoButton = undo
            addSubview(undo)
        case .horizontalStyle:
            let colors: [(AnnotationColor, String)] = [
                (.defaultColor, "Red"), (.yellow, "Yellow"), (.green, "Green"), (.blue, "Blue"), (.black, "Black"), (.white, "White")
            ]
            for (color, name) in colors {
                let button = makeButton(title: "●", label: "Color: \(name)", help: "Use \(name.lowercased()) annotation color")
                button.contentTintColor = color.nsColor
                button.tag = colorButtons.count
                button.setButtonType(.toggle)
                button.target = self
                button.action = #selector(colorPressed(_:))
                colorButtons.append((color, button))
                addSubview(button)
            }
            for width in [CGFloat(1), 3, 6, 10] {
                let button = makeButton(title: "\(Int(width))", label: "Width \(Int(width))", help: "Use \(Int(width))-point stroke width")
                button.tag = widthButtons.count
                button.setButtonType(.toggle)
                button.target = self
                button.action = #selector(widthPressed(_:))
                widthButtons.append((width, button))
                addSubview(button)
            }
            addUndoRedoButtons()
        case .horizontalActions:
            for action in CaptureEditorAction.allCases {
                let button = makeButton(title: title(for: action), label: action.displayName, help: help(for: action))
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
        let undo = makeButton(title: "↶", label: "Undo", help: "Undo the latest annotation")
        undo.target = self
        undo.action = #selector(undoPressed)
        undoButton = undo
        addSubview(undo)
        let redo = makeButton(title: "↷", label: "Redo", help: "Redo the latest annotation")
        redo.target = self
        redo.action = #selector(redoPressed)
        redoButton = redo
        addSubview(redo)
    }

    private func makeButton(title: String, label: String, help: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.toolTip = help
        button.isBordered = true
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(help)
        return button
    }

    private func title(for tool: AnnotationTool) -> String {
        switch tool {
        case .select: "↖"
        case .pen: "✎"
        case .line: "╱"
        case .arrow: "➜"
        case .rectangle: "□"
        case .marker: "▬"
        case .text: "T"
        }
    }

    private func title(for action: CaptureEditorAction) -> String {
        switch action {
        case .copy: "Copy"
        case .save: "Save"
        case .saveAs: "Save As"
        case .share: "Share"
        case .print: "Print"
        case .cancel: "Cancel"
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

    private func styleTitle(textStyle: TextStyle, width: CGFloat) -> String {
        selectedTool == .text ? "A\(Int(textStyle.fontSize))" : "\(Int(width))"
    }

    private func rebuildFocusChain() {
        let buttons = subviews.compactMap { $0 as? NSButton }
        for (index, button) in buttons.enumerated() {
            button.nextKeyView = buttons.indices.contains(index + 1) ? buttons[index + 1] : nil
        }
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
