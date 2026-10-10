import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VibeShot

struct M4AnnotationTests {
    @Test
    func typedBoundsAndArrowGeometryStayFinite() {
        let style = AnnotationStyle(color: .blue, width: 4)
        let line = LineAnnotation(start: CanvasPoint(x: 10, y: 20), end: CanvasPoint(x: 30, y: 40), style: style)
        #expect(line.bounds == CanvasRect(x: 8, y: 18, width: 24, height: 24))

        let rectangle = RectangleAnnotation(rect: CanvasRect(x: 10, y: 20, width: 30, height: 40), style: style)
        #expect(rectangle.bounds == CanvasRect(x: 8, y: 18, width: 34, height: 44))

        let arrow = ArrowAnnotation(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 100, y: 0), style: style)
        #expect(arrow.geometry.tip == arrow.end)
        #expect(arrow.geometry.left.y > 0)
        #expect(arrow.geometry.right.y < 0)
        #expect(arrow.bounds.minX <= 0 && arrow.bounds.maxX >= 100)
        #expect(ArrowAnnotation(start: arrow.start, end: arrow.start, style: style).geometry.headLength == 0)
    }

    @Test
    func commandStackPreservesOrderIndexAndRedoInvalidation() {
        let canvas = CanvasRect(x: 0, y: 0, width: 100, height: 80)
        let stack = AnnotationCommandStack(document: AnnotationDocument(canvasBounds: canvas))
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = AnnotationItem.line(LineAnnotation(id: firstID, start: CanvasPoint(x: 1, y: 1), end: CanvasPoint(x: 20, y: 1), style: .default))
        let second = AnnotationItem.rectangle(RectangleAnnotation(id: secondID, rect: CanvasRect(x: 2, y: 2, width: 8, height: 8), style: .default))
        #expect(stack.add(first))
        #expect(stack.add(second, at: 0))
        #expect(stack.document.items.map(\.id) == [secondID, firstID])
        #expect(stack.delete(id: secondID))
        #expect(stack.undo())
        #expect(stack.document.items.map(\.id) == [secondID, firstID])
        #expect(stack.undo())
        #expect(stack.document.items.map(\.id) == [firstID])
        #expect(stack.redo())
        #expect(stack.document.items.map(\.id) == [secondID, firstID])
        #expect(stack.add(first) == false) // duplicate IDs cannot disturb history
        let third = AnnotationItem.line(LineAnnotation(start: CanvasPoint(x: 2, y: 10), end: CanvasPoint(x: 8, y: 10), style: .default))
        #expect(stack.add(third))
        #expect(stack.redoCount == 0)
    }

    @Test
    func transientRendersAfterCommittedOrderAndClearsWithoutHistory() {
        let stack = AnnotationCommandStack(document: AnnotationDocument(canvasSize: CGSize(width: 20, height: 20)))
        let committed = AnnotationItem.line(LineAnnotation(start: CanvasPoint(x: 2, y: 2), end: CanvasPoint(x: 18, y: 2), style: .default))
        let transient = AnnotationItem.line(LineAnnotation(start: CanvasPoint(x: 2, y: 4), end: CanvasPoint(x: 18, y: 4), style: AnnotationStyle(color: .green, width: 2)))
        #expect(stack.add(committed))
        stack.setTransient(transient)
        #expect(stack.document.renderedItems == [committed, transient])
        #expect(stack.undoCount == 1)
        #expect(stack.commitTransient())
        #expect(stack.document.items == [committed, transient])
        #expect(stack.undoCount == 2)
        #expect(stack.undo())
        #expect(stack.document.items == [committed])
    }

    @Test
    func gestureReducerTableClampsCoalescesAndRejectsDegenerates() {
        let bounds = CanvasRect(x: 0, y: 0, width: 100, height: 80)
        let style = AnnotationStyle(color: .yellow, width: 4)
        let cases: [(AnnotationTool, AnnotationItem?)] = [
            (.line, .line(LineAnnotation(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 100, y: 80), style: style))),
            (.arrow, .arrow(ArrowAnnotation(start: CanvasPoint(x: 0, y: 0), end: CanvasPoint(x: 100, y: 80), style: style))),
            (.rectangle, .rectangle(RectangleAnnotation(rect: CanvasRect(x: 0, y: 0, width: 100, height: 80), style: style))),
            (.pen, .pen(FreehandStroke(points: [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 100, y: 80)], style: style))),
            (.marker, .marker(HighlightAnnotation(points: [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 100, y: 80)], style: style)))
        ]
        for (tool, expectedShape) in cases {
            var reducer = AnnotationGestureReducer(canvasBounds: bounds)
            #expect(reducer.begin(tool: tool, style: style, at: CanvasPoint(x: -10, y: -10)) == false)
            let began = reducer.begin(tool: tool, style: style, at: CanvasPoint(x: 1, y: 1))
            #expect(began)
            _ = reducer.update(to: CanvasPoint(x: 1.01, y: 1.01))
            _ = reducer.update(to: CanvasPoint(x: 500, y: 500))
            let result = reducer.end()
            #expect(result != nil)
            #expect(result?.tool == expectedShape?.tool)
            #expect(result?.bounds.maxX ?? 0 <= bounds.maxX + style.width)
            #expect(result?.bounds.maxY ?? 0 <= bounds.maxY + style.width)
        }

        var degenerate = AnnotationGestureReducer(canvasBounds: bounds)
        let began = degenerate.begin(tool: .line, style: style, at: CanvasPoint(x: 20, y: 20))
        #expect(began)
        #expect(degenerate.end() == nil)
    }

    @Test
    func gestureCapturesStyleAndTransformMapsResizeWithoutChangingVectors() {
        let document = AnnotationDocument(canvasBounds: CanvasRect(x: 0, y: 0, width: 100, height: 50))
        let transform = CanvasTransform(canvasBounds: document.canvasBounds, destination: CGRect(x: 20, y: 30, width: 200, height: 100))
        #expect(transform.canvasPoint(from: CGPoint(x: 20, y: 30)) == CanvasPoint(x: 0, y: 0))
        #expect(transform.canvasPoint(from: CGPoint(x: 220, y: 130)) == CanvasPoint(x: 100, y: 50))
        #expect(transform.destinationRect(for: CanvasRect(x: 25, y: 10, width: 50, height: 20)) == CGRect(x: 70, y: 50, width: 100, height: 40))

        var reducer = AnnotationGestureReducer(canvasBounds: document.canvasBounds)
        let original = AnnotationStyle(color: .red, width: 3)
        let began = reducer.begin(tool: .line, style: original, at: CanvasPoint(x: 10, y: 10))
        #expect(began)
        _ = reducer.update(to: CanvasPoint(x: 90, y: 40))
        let value = reducer.end()
        #expect(value?.style == original)
    }

    @Test
    func sharedRendererDimsOutsideBrightensSelectionAndClipsVectors() throws {
        let source = try #require(syntheticImage(width: 20, height: 20, color: (0, 1, 0, 1)))
        let document = AnnotationDocument(canvasBounds: CanvasRect(x: 0, y: 0, width: 10, height: 10))
        let stack = AnnotationCommandStack(document: document)
        let line = AnnotationItem.line(LineAnnotation(start: CanvasPoint(x: 0, y: 5), end: CanvasPoint(x: 10, y: 5), style: AnnotationStyle(color: .red, width: 2)))
        #expect(stack.add(line))
        let rendered = try #require(AnnotationRenderer.render(source: source, selection: ImagePixelRect(x: 5, y: 5, width: 10, height: 10), document: stack.document))
        let selected = try #require(pixel(in: rendered, x: 10, y: 8))
        let dimmed = try #require(pixel(in: rendered, x: 0, y: 0))
        #expect(selected.green > dimmed.green)
    }

    @Test
    func versionOneSettingsDecodeWithM4DefaultsAndPersistVersionTwo() throws {
        let old = Data("""
        {"version":1,"regionShortcut":{"keyCode":18,"modifiers":768,"isEnabled":true},"fullScreenShortcut":{"keyCode":29,"modifiers":0,"isEnabled":false},"outputFormat":"png","imageQuality":90,"saveDestination":"askEveryTime"}
        """.utf8)
        let backing = M4DataBacking(values: ["settings.v1": old])
        let store = SettingsStore(backing: backing)
        #expect(store.settings.version == AppSettings.currentVersion)
        #expect(store.settings.lastColor == .defaultColor)
        #expect(store.settings.lastStrokeWidth == Double(AnnotationStyle.default.width))
        try store.update { $0.lastColor = .blue; $0.lastStrokeWidth = 9 }
        let saved = try #require(backing.values["settings.v1"])
        #expect(String(data: saved, encoding: .utf8)?.contains("lastStrokeWidth") == true)
    }

    private func syntheticImage(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func pixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 3 < data.count else { return nil }
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }
}

private final class M4DataBacking: SettingsDataBacking {
    var values: [String: Data]

    init(values: [String: Data] = [:]) { self.values = values }
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data, forKey key: String) throws { values[key] = data }
}
