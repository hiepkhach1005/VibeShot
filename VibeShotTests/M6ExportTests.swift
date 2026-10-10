import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VibeShot

struct M6ExportTests {
    @MainActor @Test
    func savePathsAlwaysPassFullQualityToEncoder() async throws {
        let input = try retinaPatternInput()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoder = QualityRecordingEncoder()
        let panel = ExportURLPanel(url: folder.appendingPathComponent("quality.png"))
        let coordinator = ExportCoordinator(encoder: encoder, savePanel: panel)
        #expect(try coordinator.save(input: input, saveAs: true).result == .succeeded)
        #expect(try await coordinator.saveAsync(input: input, saveAs: true, isCurrent: { true }).result == .succeeded)
        let legacy = LegacyQualityStore()
        let legacyCoordinator = ExportCoordinator(settingsStore: legacy, encoder: encoder, savePanel: panel)
        #expect(try legacyCoordinator.save(input: input, saveAs: true).result == .succeeded)
        #expect(try await legacyCoordinator.saveAsync(input: input, saveAs: true, isCurrent: { true }).result == .succeeded)
        #expect(encoder.qualities == [100, 100, 100, 100])
    }
    @MainActor @Test
    func committedRetinaRectangleSurvivesPNGAndTIFFAndAsyncSave() async throws {
        let source = try #require(syntheticImage(width: 200, height: 200))
        let descriptor = ScreenDescriptor(id: DisplayID(1), frame: GlobalScreenRect(CGRect(x: 0, y: 0, width: 100, height: 100)), pointPixelScale: 2, pixelSize: PixelSize(width: 200, height: 200))
        let controller = CaptureOverlayWindowController(sessionID: UUID(), snapshot: DisplaySnapshot(descriptor: descriptor, image: source))
        controller.selectAll()
        controller.setTool(.rectangle)
        controller.setColor(AnnotationColor(red: 1, green: 0, blue: 0))
        controller.setWidth(4)
        _ = controller.beginInteraction(at: CGPoint(x: 20, y: 20))
        _ = controller.endInteraction(at: CGPoint(x: 80, y: 80))
        let input = try controller.makeExportInput()
        #expect(input.document.items.count == 1)
        let representations = try await ExportCoordinator().prepareCopy(input: input)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rectangle.png")
        let coordinator = ExportCoordinator(savePanel: ExportURLPanel(url: url))
        #expect(try await coordinator.saveAsync(input: input, saveAs: true, isCurrent: { true }).result == .succeeded)
        for data in [representations.png, representations.tiff, try Data(contentsOf: url)] {
            let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            #expect(decoded.width == 200 && decoded.height == 200)
            let context = try #require(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 200, height: 200))
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let border = (100 * 200 + 40) * 4
            let center = (100 * 200 + 100) * 4
            #expect(pixels[border] > 230 && pixels[border + 1] < 25)
            #expect(pixels[center + 2] > pixels[center])
        }
        let staleURL = folder.appendingPathComponent("stale.png")
        let stale = ExportCoordinator(savePanel: ExportURLPanel(url: staleURL))
        await #expect(throws: CancellationError.self) { try await stale.saveAsync(input: input, saveAs: true, isCurrent: { false }) }
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        let cancel = ExportCoordinator(savePanel: ExportURLPanel(url: nil))
        #expect(try await cancel.saveAsync(input: input, saveAs: true, isCurrent: { true }).result == .cancelled)
    }
    @Test
    func actionPolicyTableRetainsOnCancelOrError() {
        let actions: [CaptureEditorAction] = [.copy, .save, .saveAs, .print, .share]
        for action in actions {
            #expect(CaptureActionPolicy.outcome(for: action, result: .succeeded) == .close)
            #expect(CaptureActionPolicy.outcome(for: action, result: .cancelled) == .retain)
            #expect(CaptureActionPolicy.outcome(for: action, result: .failed) == .retain)
        }
        #expect(CaptureActionPolicy.outcome(for: .cancel, result: .succeeded) == .retain)
    }

    @Test
    func captureKeyRouterWiresM6ActionsButTextEditingPassesNativeCommands() {
        let command = NSEvent.ModifierFlags.command.rawValue
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let cases: [(CaptureKeyInput, CaptureKeyRoute)] = [
            (CaptureKeyInput(keyCode: CaptureKeyRouter.cKeyCode, modifiers: command), .captureCopy),
            (CaptureKeyInput(keyCode: CaptureKeyRouter.sKeyCode, modifiers: command), .captureSave),
            (CaptureKeyInput(keyCode: CaptureKeyRouter.sKeyCode, modifiers: command | shift), .captureSaveAs),
            (CaptureKeyInput(keyCode: CaptureKeyRouter.pKeyCode, modifiers: command), .capturePrint),
            (CaptureKeyInput(keyCode: CaptureKeyRouter.sKeyCode, modifiers: command), .passThrough)
        ]
        for (index, value) in cases.enumerated() {
            let editing = index == cases.count - 1
            #expect(CaptureKeyRouter.route(value.0, textEditing: editing) == value.1)
        }
    }

    @Test
    func exportInputUsesDisplayGeometryAndCommittedOnlyVectors() throws {
        let source = try #require(syntheticImage(width: 200, height: 100))
        let descriptor = ScreenDescriptor(
            id: DisplayID(1),
            frame: GlobalScreenRect(CGRect(x: -100, y: 20, width: 100, height: 50)),
            pointPixelScale: 2,
            pixelSize: PixelSize(width: 200, height: 100)
        )
        let bounds = CanvasRect(x: 10, y: 5, width: 40, height: 20)
        var document = AnnotationDocument(canvasBounds: bounds)
        let line = AnnotationItem.line(LineAnnotation(start: CanvasPoint(x: 10, y: 5), end: CanvasPoint(x: 50, y: 25), style: .default))
        #expect(document.items.isEmpty)
        document.setTransient(line)
        let input = try ExportInput(snapshot: DisplaySnapshot(descriptor: descriptor, image: source), selection: CGRect(x: 10, y: 5, width: 40, height: 20), document: document)
        #expect(input.imagePixelRect == ImagePixelRect(x: 20, y: 50, width: 80, height: 40))
        #expect(input.document.transient == nil)
        let result = try NativePixelCompositor.composite(input)
        #expect(result.width == 80)
        #expect(result.height == 40)
    }

    @Test
    func encoderPolicyOnlyAddsLossyQualityAndUsesUTIs() throws {
        let png = try ImageEncoderPolicy(format: .png, quality: 1)
        let jpeg = try ImageEncoderPolicy(format: .jpeg, quality: 37)
        #expect(png.typeIdentifier == UTType.png.identifier)
        #expect(png.destinationProperties.isEmpty)
        #expect(!png.appliesQuality)
        #expect(jpeg.destinationProperties[kCGImageDestinationLossyCompressionQuality] as? Double == 0.37)
        #expect(jpeg.flattensAlpha)
        #expect(throws: ExportError.self) { try ImageEncoderPolicy(format: .heic, quality: 101) }
    }

    @Test
    func collisionNamesUseStableSuffixesAndPrintLayoutFits() {
        let date = Date(timeIntervalSince1970: 0)
        let generator = CollisionSafeFileName(date: date, calendar: Calendar(identifier: .gregorian))
        let folder = URL(fileURLWithPath: "/tmp")
        let first = generator.url(in: folder, format: .png) { _ in false }
        let second = generator.url(in: folder, format: .png) { url in !url.lastPathComponent.contains("(1)") }
        #expect(first.lastPathComponent.hasSuffix(".png"))
        #expect(second.lastPathComponent.hasSuffix("(1).png"))
        let fit = PrintLayout.aspectFit(imageSize: CGSize(width: 400, height: 200), in: CGRect(x: 0, y: 0, width: 300, height: 300))
        #expect(fit == CGRect(x: 0, y: 75, width: 300, height: 150))
    }

    @Test
    func versionedFolderBookmarkPayloadMigratesLegacyDataAndRejectsFutureVersion() throws {
        let legacy = Data("{\"version\":2,\"saveDestination\":\"recentFolder\",\"recentFolderPath\":\"/tmp\",\"recentFolderBookmarkData\":\"AQI=\"}".utf8)
        let decoder = JSONDecoder()
        let migrated = try decoder.decode(AppSettings.self, from: legacy)
        #expect(migrated.recentFolderBookmark?.version == FolderBookmark.currentVersion)
        #expect(migrated.recentFolderBookmark?.data == Data([1, 2]))

        var future = AppSettings(saveDestination: SaveDestination.recentFolder, recentFolderPath: "/tmp", recentFolderBookmark: FolderBookmark(version: 99, data: Data([1])))
        future.validate()
        #expect(future.recentFolderBookmark == nil)
        #expect(future.saveDestination == SaveDestination.recentFolder)
    }

    @MainActor
    @Test
    func clipboardPreparesBothRepresentationsBeforeCommitAndRollsBackPartialFailure() throws {
        let image = try #require(syntheticImage(width: 8, height: 6))
        let pasteboard = PasteboardTransactionSpy()
        let writer = ClipboardWriter(pasteboard: pasteboard)

        let prepared = try writer.prepareRepresentations(image: image)
        #expect(!prepared.png.isEmpty)
        #expect(!prepared.tiff.isEmpty)
        #expect(pasteboard.writeCalls == 0)
        #expect(pasteboard.visiblePNG == nil)
        #expect(pasteboard.visibleTIFF == nil)

        pasteboard.failCommit = true
        #expect(throws: ExportError.self) { try writer.copy(image: image) }
        #expect(pasteboard.writeCalls == 1)
        #expect(pasteboard.visiblePNG == nil)
        #expect(pasteboard.visibleTIFF == nil)
        #expect(pasteboard.clearCalls == 2)

        pasteboard.failCommit = false
        try writer.copy(image: image)
        #expect(pasteboard.writeCalls == 2)
        #expect(pasteboard.visiblePNG != nil)
        #expect(pasteboard.visibleTIFF != nil)
    }

    @MainActor @Test
    func successiveCopiesReplaceThePreviousPasteboardItem() throws {
        let pasteboard = PasteboardTransactionSpy()
        let writer = ClipboardWriter(pasteboard: pasteboard)
        try writer.publish(ClipboardRepresentations(png: Data([1]), tiff: Data([2])))
        try writer.publish(ClipboardRepresentations(png: Data([3]), tiff: Data([4])))
        #expect(pasteboard.items.count == 1)
        #expect(pasteboard.visiblePNG == Data([3]))
        #expect(pasteboard.visibleTIFF == Data([4]))
    }

    @MainActor @Test
    func nativePasteboardAdapterReplacesOldItemsWithOneCurrentItem() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        let old = NSPasteboardItem()
        #expect(old.setData(Data([9]), forType: .png))
        #expect(board.writeObjects([old]))
        let writer = ClipboardWriter(pasteboard: PasteboardAdapter(pasteboard: board))
        try writer.publish(ClipboardRepresentations(png: Data([1]), tiff: Data([2])))
        try writer.publish(ClipboardRepresentations(png: Data([3]), tiff: Data([4])))
        #expect(board.pasteboardItems?.count == 1)
        #expect(board.pasteboardItems?.first?.data(forType: .png) == Data([3]))
        #expect(board.pasteboardItems?.first?.data(forType: .tiff) == Data([4]))
    }

    @MainActor
    @Test
    func copyPreparationRunsOffMainActorBeforeSinglePublication() async throws {
        let input = try retinaPatternInput()
        let gate = CopyPreparationGate()
        let pasteboard = PasteboardTransactionSpy()
        let coordinator = ExportCoordinator(
            clipboard: ClipboardWriter(pasteboard: pasteboard),
            clipboardPreparer: gate
        )

        let preparation = Task { try await coordinator.prepareCopy(input: input) }
        await gate.waitUntilEntered()

        // This is a deterministic main-actor heartbeat: the worker is blocked after beginning,
        // while the main actor remains able to process this turn. It intentionally has no timing
        // threshold.
        var heartbeat = 0
        heartbeat += 1
        #expect(heartbeat == 1)
        #expect(pasteboard.writeCalls == 0)

        gate.allowCompletion()
        let representations = try await preparation.value
        #expect(pasteboard.writeCalls == 0)
        #expect(try coordinator.publishCopy(representations) == .succeeded)
        #expect(pasteboard.writeCalls == 1)

        let cancelledGate = CopyPreparationGate()
        let cancelledCoordinator = ExportCoordinator(clipboard: ClipboardWriter(pasteboard: pasteboard), clipboardPreparer: cancelledGate)
        let cancelled = Task { try await cancelledCoordinator.prepareCopy(input: input) }
        await cancelledGate.waitUntilEntered()
        cancelled.cancel()
        cancelledGate.allowCompletion()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(pasteboard.writeCalls == 1)
    }

    private func retinaPatternInput() throws -> ExportInput {
        let width = 1_024
        let height = 768
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Generated pattern only; no captured/private pixels are used by this regression test.
        for y in stride(from: 0, to: height, by: 32) {
            for x in stride(from: 0, to: width, by: 32) {
                context.setFillColor(CGColor(
                    srgbRed: CGFloat((x / 32) % 2), green: CGFloat((y / 32) % 2), blue: 0.5, alpha: 1
                ))
                context.fill(CGRect(x: x, y: y, width: 32, height: 32))
            }
        }
        let image = try #require(context.makeImage())
        let descriptor = ScreenDescriptor(
            id: DisplayID(9), frame: GlobalScreenRect(CGRect(x: 0, y: 0, width: 512, height: 384)),
            pointPixelScale: 2, pixelSize: PixelSize(width: width, height: height)
        )
        return try ExportInput(sourceImage: image, descriptor: descriptor, selection: DisplayLocalRect(CGRect(x: 0, y: 0, width: 512, height: 384)))
    }

    private func syntheticImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

@MainActor private final class ExportURLPanel: SavePanelPresenting {
    let url: URL?
    init(url: URL?) { self.url = url }
    func chooseURL(defaultDirectory: URL?, suggestedFileName: String, format: OutputFormat) throws -> URL? { url }
}

private final class QualityRecordingEncoder: ImageEncoding, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    var qualities: [Int] { lock.lock(); defer { lock.unlock() }; return recorded }
    func encode(_ image: CGImage, format: OutputFormat, quality: Int) throws -> Data {
        lock.lock(); recorded.append(quality); lock.unlock()
        return Data([1, 2, 3])
    }
    func encodeTIFF(_ image: CGImage) throws -> Data { Data([1]) }
}

private final class LegacyQualityStore: SettingsPersisting {
    var settings = AppSettings(imageQuality: 37)
    var loadError: SettingsStoreError?
    func update(_ mutation: (inout AppSettings) -> Void) throws { mutation(&settings) }
}

private final class CopyPreparationGate: ClipboardRepresentationPreparing, @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func prepareRepresentations(for input: ExportInput) throws -> ClipboardRepresentations {
        entered.signal()
        release.wait()
        try Task.checkCancellation()
        return ClipboardRepresentations(png: Data([1]), tiff: Data([2]))
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.entered.wait()
                continuation.resume()
            }
        }
    }

    func allowCompletion() { release.signal() }
}

@MainActor
private final class PasteboardTransactionSpy: PasteboardWriting {
    var failCommit = false
    var writeCalls = 0
    var clearCalls = 0
    var items: [ClipboardRepresentations] = []
    var visiblePNG: Data? { items.first?.png }
    var visibleTIFF: Data? { items.first?.tiff }

    func clearContents() {
        clearCalls += 1
        items.removeAll()
    }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        _ = data
        _ = type
        return true
    }

    @discardableResult
    func writeRepresentations(_ representations: ClipboardRepresentations) -> Bool {
        writeCalls += 1
        // Model a system/fake that exposes the first representation before reporting a failed
        // compatibility commit. ClipboardWriter must clear this partial state.
        items.append(ClipboardRepresentations(png: representations.png, tiff: Data()))
        guard !failCommit else { return false }
        items[items.count - 1] = representations
        return true
    }
}
