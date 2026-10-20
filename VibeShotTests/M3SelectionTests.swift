import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VibeShot

struct M3SelectionTests {
    @Test func rememberedGeometrySurvivesResolutionChangeAndClampsToMinimum() throws {
        let original = try #require(RememberedRegion.normalized(
            from: DisplayLocalRect(CGRect(x: 20, y: 10, width: 40, height: 30)),
            in: CGRect(x: 0, y: 0, width: 100, height: 80)
        ))
        #expect(original.displayLocalRect(in: CGRect(x: 0, y: 0, width: 200, height: 160))?.rect == CGRect(x: 40, y: 20, width: 80, height: 60))
        let tiny = RememberedRegion(x: 0.98, y: 0.98, width: 0.02, height: 0.02)
        #expect(tiny.displayLocalRect(in: CGRect(x: 0, y: 0, width: 100, height: 80))?.rect == CGRect(x: 92, y: 72, width: 8, height: 8))
        #expect(RememberedRegion(x: .nan, y: 0, width: 0.2, height: 0.2).displayLocalRect(in: CGRect(x: 0, y: 0, width: 100, height: 80)) == nil)
    }

    @Test func rememberedDisplayIdentitySurvivesPixelSizeReplacement() {
        let display = ScreenDescriptor(id: DisplayID(3), frame: GlobalScreenRect(CGRect(x: -200, y: 20, width: 100, height: 80)), pointPixelScale: 2, persistentDisplayID: "display-uuid")
        #expect(display.replacing(pixelSize: PixelSize(width: 250, height: 200)).persistentDisplayID == "display-uuid")
        #expect(ScreenDescriptor(id: DisplayID(3), frame: display.frame, pointPixelScale: 2).persistentDisplayID == nil)
    }

    @Test func rememberedRegionTargetsOnlyPointerDisplayAndSkipsFullScreen() {
        let first = ScreenDescriptor(id: DisplayID(1), frame: GlobalScreenRect(CGRect(x: -100, y: 0, width: 100, height: 80)), pointPixelScale: 1, persistentDisplayID: "first")
        let second = ScreenDescriptor(id: DisplayID(2), frame: GlobalScreenRect(CGRect(x: 0, y: 0, width: 100, height: 80)), pointPixelScale: 1, persistentDisplayID: "second")
        let displays = [second, first]
        #expect(RememberedRegionDisplayResolver.resolve(command: .region, descriptors: displays, pointer: GlobalScreenPoint(x: 20, y: 20))?.persistentDisplayID == "second")
        #expect(RememberedRegionDisplayResolver.resolve(command: .region, descriptors: displays, pointer: GlobalScreenPoint(x: 500, y: 500))?.persistentDisplayID == "first")
        #expect(RememberedRegionDisplayResolver.resolve(command: .fullScreen, descriptors: displays, pointer: GlobalScreenPoint(x: 20, y: 20)) == nil)
    }

    @Test func restoreSelectionClampsWithoutEnteringDrag() {
        var value = makeController(width: 100, height: 80)
        let restored = value.restoreSelection(DisplayLocalRect(CGRect(x: 98, y: 78, width: 2, height: 2)))
        #expect(restored)
        #expect(value.selectionRect == CGRect(x: 92, y: 72, width: 8, height: 8))
        #expect(!value.isSelecting)
    }

    @MainActor @Test func completedSelectionCallbackSkipsDragIntermediateAndAnnotation() throws {
        let image = try #require(syntheticImage(width: 100, height: 80, color: (0.2, 0.3, 0.4, 1)))
        let screen = ScreenDescriptor(id: DisplayID(1), frame: GlobalScreenRect(CGRect(x: 0, y: 0, width: 100, height: 80)), pointPixelScale: 1)
        let controller = CaptureOverlayWindowController(sessionID: UUID(), snapshot: DisplaySnapshot(descriptor: screen, image: image))
        var saved: [DisplayLocalRect] = []
        controller.onCompletedSelectionChange = { _, selection in saved.append(selection) }
        _ = controller.beginInteraction(at: CGPoint(x: 10, y: 10))
        controller.updateInteraction(at: CGPoint(x: 60, y: 50))
        #expect(saved.isEmpty)
        _ = controller.endInteraction(at: CGPoint(x: 60, y: 50))
        #expect(saved.count == 1)
        controller.setTool(.rectangle)
        _ = controller.beginInteraction(at: CGPoint(x: 20, y: 20))
        _ = controller.endInteraction(at: CGPoint(x: 40, y: 40))
        #expect(saved.count == 1)
        controller.closeOverlay()
    }

    @MainActor @Test func restoredPointerDisplayKeepsInitialKeyboardFocus() throws {
        _ = NSApplication.shared
        let image = try #require(syntheticImage(width: 100, height: 80, color: (0.2, 0.3, 0.4, 1)))
        let first = ScreenDescriptor(id: DisplayID(1), frame: GlobalScreenRect(CGRect(x: 0, y: 0, width: 100, height: 80)), pointPixelScale: 1, persistentDisplayID: "first")
        let last = ScreenDescriptor(id: DisplayID(9), frame: GlobalScreenRect(CGRect(x: 100, y: 0, width: 100, height: 80)), pointPixelScale: 1, persistentDisplayID: "last")
        let store = RegionMemorySettingsSpy()
        let consumer = CaptureOverlaySessionConsumer(settingsStore: store)
        let session = CaptureSession(command: .region, displays: [DisplaySnapshot(descriptor: first, image: image), DisplaySnapshot(descriptor: last, image: image)], pointerLocation: GlobalScreenPoint(x: 20, y: 20))
        consumer.consume(session, eventHandler: { _ in })
        defer { consumer.cancelActiveCapture() }
        #expect(consumer.activeDisplayID == first.id)
        #expect(consumer.keyOverlayDisplayID == first.id)
    }
    @Test
    func createClampsToOneDisplayAndEnforcesMinimum() {
        let controller = makeController(width: 100, height: 80)
        var value = controller
        value.beginSelection(at: CGPoint(x: 98, y: 78))
        value.update(to: CGPoint(x: 140, y: 120))

        #expect(value.selectionRect?.maxX == 100)
        #expect(value.selectionRect?.maxY == 80)
        #expect(value.selectionRect?.width == 8)
        #expect(value.selectionRect?.height == 8)
        #expect(value.selectionRect?.minX == 92)
        #expect(value.selectionRect?.minY == 72)
    }

    @Test
    func movingSelectionIsClampedWithoutChangingSize() {
        var value = makeController(width: 100, height: 80)
        value.beginSelection(at: CGPoint(x: 20, y: 20))
        value.update(to: CGPoint(x: 60, y: 50))
        _ = value.endInteraction()

        _ = value.begin(at: CGPoint(x: 40, y: 35))
        value.update(to: CGPoint(x: -100, y: -100))
        #expect(value.selectionRect == CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    @Test
    func allEightHandlesResizeAndCrossOppositeEdges() throws {
        for handle in SelectionHandle.allCases {
            var value = makeController(width: 160, height: 120)
            value.beginSelection(at: CGPoint(x: 40, y: 30))
            value.update(to: CGPoint(x: 120, y: 90))
            _ = value.endInteraction()

            let point: CGPoint
            switch handle {
            case .topLeft: point = CGPoint(x: 140, y: 10)
            case .top: point = CGPoint(x: 80, y: 10)
            case .topRight: point = CGPoint(x: 10, y: 10)
            case .right: point = CGPoint(x: 10, y: 60)
            case .bottomRight: point = CGPoint(x: 10, y: 110)
            case .bottom: point = CGPoint(x: 80, y: 110)
            case .bottomLeft: point = CGPoint(x: 140, y: 110)
            case .left: point = CGPoint(x: 140, y: 60)
            }
            value.resize(handle: handle, to: point)
            let rect = try #require(value.selectionRect)
            #expect(rect.width >= 8)
            #expect(rect.height >= 8)
            #expect(rect.minX >= 0)
            #expect(rect.minY >= 0)
            #expect(rect.maxX <= 160)
            #expect(rect.maxY <= 120)
        }
    }

    @Test
    func handleHitWinsOverBodyAndCommandAUsesDisplayGeometry() {
        let descriptor = ScreenDescriptor(
            id: DisplayID(99),
            frame: GlobalScreenRect(CGRect(x: -400, y: 20, width: 100, height: 80)),
            pointPixelScale: 2,
            pixelSize: PixelSize(width: 200, height: 160)
        )
        var value = SelectionController(descriptor: descriptor)
        value.beginSelection(at: CGPoint(x: 20, y: 20))
        value.update(to: CGPoint(x: 80, y: 60))
        _ = value.endInteraction()

        #expect(value.hitTest(CGPoint(x: 20, y: 60)) == .handle(.topLeft))
        #expect(value.hitTest(CGPoint(x: 50, y: 40)) == .body)
        value.commandA()
        #expect(value.selectionRect == CGRect(x: 0, y: 0, width: 100, height: 80))
        #expect(value.pixelDimensions == PixelSize(width: 200, height: 160))
    }

    @Test
    func toolbarLayoutStaysWithinVisibleFrameAndRendererPreservesSelectedBrightness() throws {
        let visible = CGRect(x: -10, y: 30, width: 100, height: 80)
        let layout = ToolbarLayoutEngine().layout(
            selection: CGRect(x: 10, y: 45, width: 70, height: 45),
            visibleFrame: visible,
            verticalSize: CGSize(width: 20, height: 40),
            horizontalSize: CGSize(width: 40, height: 15)
        )
        #expect(visible.contains(layout.verticalFrame))
        #expect(visible.contains(layout.horizontalFrame))

        let source = try #require(syntheticImage(width: 10, height: 10, color: (0, 1, 0, 1)))
        let rendered = try #require(CaptureOverlayRenderer.render(
            source: source,
            selection: ImagePixelRect(x: 3, y: 3, width: 4, height: 4)
        ))
        let selected = try #require(pixel(in: rendered, x: 5, y: 5))
        let dimmed = try #require(pixel(in: rendered, x: 0, y: 0))
        #expect(selected.green > dimmed.green)
    }

    @Test
    func toolbarsAnchorToSelectionBottomRightAndNeverOverlap() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let engine = ToolbarLayoutEngine(spacing: 10, edgeInset: 6)
        let vertical = CGSize(width: 40, height: 300)
        let horizontal = CGSize(width: 200, height: 40)

        let selection = CGRect(x: 200, y: 200, width: 400, height: 300)
        let layout = engine.layout(selection: selection, visibleFrame: visible, verticalSize: vertical, horizontalSize: horizontal)
        #expect(layout.verticalFrame.minX == selection.maxX + 10)
        #expect(layout.verticalFrame.minY == selection.minY)
        #expect(layout.horizontalFrame.maxX == selection.maxX)
        #expect(layout.horizontalFrame.maxY == selection.minY - 10)

        let full = engine.layout(selection: visible, visibleFrame: visible, verticalSize: vertical, horizontalSize: horizontal)
        #expect(visible.contains(full.verticalFrame))
        #expect(visible.contains(full.horizontalFrame))
        #expect(!full.verticalFrame.intersects(full.horizontalFrame))
        #expect(full.verticalFrame.maxX == visible.maxX - 6)
        #expect(full.verticalFrame.minY == visible.minY + 6)
    }

    @Test
    func fullScreenResolverUsesExplicitPointerThenDeterministicFallback() {
        let first = descriptor(id: 2, frame: CGRect(x: -100, y: 0, width: 100, height: 80))
        let second = descriptor(id: 4, frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let resolver = FullScreenDisplayResolver()
        #expect(resolver.resolve(command: .fullScreen(displayID: DisplayID(4)), descriptors: [first, second], pointer: CGPoint(x: -50, y: 20)) == DisplayID(4))
        #expect(resolver.resolve(command: .fullScreen, descriptors: [first, second], pointer: CGPoint(x: 20, y: 20)) == DisplayID(4))
        #expect(resolver.resolve(command: .fullScreen, descriptors: [first, second], pointer: CGPoint(x: 500, y: 500)) == DisplayID(2))
    }

    private func makeController(width: CGFloat, height: CGFloat) -> SelectionController {
        let descriptor = ScreenDescriptor(
            id: DisplayID(1),
            frame: GlobalScreenRect(CGRect(origin: .zero, size: CGSize(width: width, height: height))),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: Int(width), height: Int(height))
        )
        return SelectionController(descriptor: descriptor)
    }

    private func descriptor(id: UInt32, frame: CGRect) -> ScreenDescriptor {
        ScreenDescriptor(
            id: DisplayID(id),
            frame: GlobalScreenRect(frame),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: Int(frame.width), height: Int(frame.height))
        )
    }

    private func syntheticImage(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func pixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        let bytesPerRow = image.bytesPerRow
        let offset = y * bytesPerRow + x * 4
        guard offset + 3 < data.count else { return nil }
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }
}

private final class RegionMemorySettingsSpy: SettingsPersisting {
    var settings = AppSettings(rememberLastRegion: true, rememberedRegions: ["first": RememberedRegion(x: 0.1, y: 0.1, width: 0.4, height: 0.4)])
    var loadError: SettingsStoreError?
    func update(_ mutation: (inout AppSettings) -> Void) throws { mutation(&settings); settings.validate() }
}
