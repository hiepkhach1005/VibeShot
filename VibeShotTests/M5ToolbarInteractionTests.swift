import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VibeShot

struct M5ToolbarInteractionTests {
    @MainActor
    @Test
    func verticalToolButtonsRouteEveryToolAndReflectSelection() throws {
        let toolbar = AnnotationToolbarView(
            frame: CGRect(x: 0, y: 0, width: 54, height: 240),
            orientation: .verticalTools
        )
        var received: [AnnotationTool] = []
        toolbar.onTool = { tool in
            received.append(tool)
            // The production parent applies the callback back to the toolbar through its shared
            // state update. Mirror that seam here so this test covers both routing and selection.
            toolbar.setState(
                tool: tool,
                color: .defaultColor,
                width: AnnotationStyle.default.width,
                canUndo: false,
                canRedo: false
            )
        }

        let toolButtons = toolbar.subviews
            .compactMap { $0 as? NSButton }
            .filter { $0.accessibilityHelp()?.hasSuffix(" annotation tool") == true }
        #expect(toolButtons.count == AnnotationTool.allCases.count)

        for tool in AnnotationTool.allCases {
            let expectedHelp = "Choose \(tool.displayName.lowercased()) annotation tool"
            let button = try #require(toolButtons.first(where: { $0.accessibilityHelp() == expectedHelp }))
            received.removeAll(keepingCapacity: true)

            // Exercise the actual target/action path used by AppKit, rather than calling the
            // toolbar's private selector directly.
            button.performClick(nil)

            #expect(received == [tool])
            #expect(button.state == .on)
            #expect(toolButtons.filter { $0.state == .on }.count == 1)
            #expect(toolButtons.first(where: { $0.state == .on }) === button)
            if tool != .select {
                #expect(received.first != .select)
            }
        }
    }

    @MainActor
    @Test
    func syntheticOverlayControllerCommitsRectangleAndArrowVectors() throws {
        let controller = try #require(makeController())
        controller.selectAll()

        let gestures: [(AnnotationTool, CGPoint, CGPoint)] = [
            (.rectangle, CGPoint(x: 20, y: 20), CGPoint(x: 90, y: 70)),
            (.arrow, CGPoint(x: 110, y: 30), CGPoint(x: 180, y: 95))
        ]

        for (tool, start, end) in gestures {
            controller.setTool(tool)
            #expect(controller.beginInteraction(at: start) == .body)
            controller.updateInteraction(at: end)
            _ = controller.endInteraction(at: end)

            let item = try #require(controller.annotationStack?.document.items.last)
            #expect(item.tool == tool)
            #expect(controller.annotationStack?.document.transient == nil)
        }

        #expect(controller.annotationStack?.document.items.map(\.tool) == [.rectangle, .arrow])
    }

    @MainActor
    @Test
    func syntheticOverlayTextClickStartsEditorAndCommitsTextAnnotation() throws {
        let controller = try #require(makeController())
        controller.selectAll()
        controller.setTool(.text)

        #expect(controller.beginInteraction(at: CGPoint(x: 24, y: 28)) == .body)
        #expect(controller.overlayView.isTextEditing)
        let editor = try #require(controller.overlayView.subviews.compactMap { $0 as? NSTextView }.first)
        editor.string = "Hello VibeShot"
        #expect(controller.overlayView.commitTextEditing())
        _ = controller.endInteraction(at: CGPoint(x: 24, y: 28))

        let item = try #require(controller.annotationStack?.document.items.last)
        #expect(item.tool == .text)
        guard case let .text(annotation) = item else { return }
        #expect(annotation.text == "Hello VibeShot")
        #expect(!controller.overlayView.isTextEditing)
    }

    @MainActor
    private func makeController() -> CaptureOverlayWindowController? {
        guard let image = syntheticImage() else { return nil }
        let frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        let descriptor = ScreenDescriptor(
            id: DisplayID(7),
            frame: GlobalScreenRect(frame),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: 200, height: 120)
        )
        let snapshot = DisplaySnapshot(descriptor: descriptor, image: image)
        return CaptureOverlayWindowController(sessionID: UUID(), snapshot: snapshot)
    }

    private func syntheticImage() -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: 200,
                height: 120,
                bitsPerComponent: 8,
                bytesPerRow: 200 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.3, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        return context.makeImage()
    }
}
