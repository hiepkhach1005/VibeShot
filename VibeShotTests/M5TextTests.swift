import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VibeShot

struct M5TextTests {
    @Test
    func sanitizationTablePreservesTextAndRejectsBlankValues() {
        let cases: [(String, String, Bool)] = [
            ("one\r\ntwo", "one\ntwo", false),
            ("one\rtwo", "one\ntwo", false),
            ("\n \t", "\n \t", true),
            ("a\u{0000}b", "ab", false)
        ]
        for (input, expected, blank) in cases {
            #expect(TextSanitizer.sanitize(input) == expected)
            #expect(TextSanitizer.isBlank(input) == blank)
        }
    }

    @Test
    func textStyleSanitizesFontMetricsAndKeepsValueSemantics() {
        let value = TextStyle(fontName: "", fontSize: .infinity, color: .blue, lineSpacing: -.infinity)
        #expect(value.fontName == "Helvetica")
        #expect(value.fontSize == 16)
        #expect(value.lineSpacing == 2)
        #expect(value.sanitized == value)
        #expect(value.annotationStyle.color == .blue)
    }

    @Test
    func multilineLayoutTableNormalizesLinesAndClipsToFiniteBounds() {
        let cases: [(String, Int)] = [("one\ntwo", 2), ("one\r\ntwo\n", 3), ("", 1)]
        for (text, lineCount) in cases {
            let layout = TextLayoutEngine.layout(text: text, style: .default, in: CanvasRect(x: 0, y: 0, width: 120, height: 80))
            #expect(layout.lineCount == lineCount)
            #expect(layout.contentSize.width.isFinite)
            #expect(layout.contentSize.height.isFinite)
        }
    }

    @Test
    func textValueUsesCanvasBoundsAndOneHistoryCommand() {
        let bounds = CanvasRect(x: 10, y: 12, width: 100, height: 40)
        let value = TextAnnotation(origin: CanvasPoint(x: 10, y: 12), bounds: bounds, text: "Hello\nworld", style: TextStyle(color: .green))
        #expect(value.origin == CanvasPoint(x: 10, y: 12))
        #expect(value.bounds == bounds)
        #expect(value.text == "Hello\nworld")

        let stack = AnnotationCommandStack(document: AnnotationDocument(canvasBounds: CanvasRect(x: 0, y: 0, width: 200, height: 100)))
        #expect(stack.add(.text(value)))
        #expect(stack.undoCount == 1)
        #expect(stack.document.items == [.text(value)])
    }

    @Test
    func destinationTextRectMapsBackThroughSharedCanvasTransform() {
        let transform = CanvasTransform(canvasBounds: CanvasRect(x: 0, y: 0, width: 200, height: 100), destination: CGRect(x: 20, y: 30, width: 400, height: 200))
        #expect(transform.canvasRect(from: CGRect(x: 120, y: 80, width: 100, height: 60)) == CanvasRect(x: 50, y: 25, width: 50, height: 30))
    }

    @Test
    func keyRouterPrioritizesTextInputAndKeepsNativeCommandsPassingThrough() {
        let command = NSEvent.ModifierFlags.command.rawValue
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let option = NSEvent.ModifierFlags.option.rawValue
        let table: [(CaptureKeyInput, Bool, CaptureKeyRoute)] = [
            (CaptureKeyInput(keyCode: 36), true, .textCommit),
            (CaptureKeyInput(keyCode: 36, modifiers: shift), true, .textNewline),
            (CaptureKeyInput(keyCode: 36, modifiers: option), true, .textNewline),
            (CaptureKeyInput(keyCode: 53), true, .textCancel),
            (CaptureKeyInput(keyCode: 8, modifiers: command), true, .passThrough),
            (CaptureKeyInput(keyCode: 6, modifiers: command), false, .undo),
            (CaptureKeyInput(keyCode: 6, modifiers: command | shift), false, .redo),
            (CaptureKeyInput(keyCode: 53), false, .captureCancel)
        ]
        for (input, editing, expected) in table {
            #expect(CaptureKeyRouter.route(input, textEditing: editing) == expected)
        }
    }

    @Test
    func rendererDrawsMultilineTextInsideSharedSelectionClip() throws {
        let source = try #require(syntheticImage(width: 40, height: 40, color: (0, 1, 0, 1)))
        let document = AnnotationDocument(canvasBounds: CanvasRect(x: 0, y: 0, width: 20, height: 20))
        let stack = AnnotationCommandStack(document: document)
        let text = TextAnnotation(
            origin: CanvasPoint(x: 2, y: 2),
            bounds: CanvasRect(x: 2, y: 2, width: 16, height: 14),
            text: "A\nB",
            style: TextStyle(fontName: "Helvetica", fontSize: 10, color: .red)
        )
        #expect(stack.add(.text(text)))
        let rendered = try #require(AnnotationRenderer.render(source: source, selection: ImagePixelRect(x: 5, y: 5, width: 30, height: 30), document: stack.document))
        #expect(rendered.width == source.width)
        #expect(rendered.height == source.height)
    }

    @MainActor
    @Test
    func textEditingSessionCommitsOnceAndCancelsBlankFocusLoss() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        let session = TextEditingSession()
        var commits: [(String, CGRect)] = []
        var cancels = 0
        #expect(session.begin(in: host, frame: CGRect(x: 10, y: 10, width: 120, height: 50), style: .default, onCommit: { commits.append(($0, $1)) }, onCancel: { cancels += 1 }))
        session.editor?.string = "hello\nworld"
        #expect(session.commit())
        #expect(!session.isActive)
        #expect(commits.count == 1)
        #expect(commits.first?.0 == "hello\nworld")
        #expect(!session.commit())

        #expect(session.begin(in: host, frame: CGRect(x: 10, y: 10, width: 120, height: 50), style: .default, onCommit: { commits.append(($0, $1)) }, onCancel: { cancels += 1 }))
        session.editor?.string = " \n"
        session.textDidEndEditing(Notification(name: NSText.didEndEditingNotification))
        #expect(!session.isActive)
        #expect(cancels == 1)
        #expect(commits.count == 1)
    }

    private func syntheticImage(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
