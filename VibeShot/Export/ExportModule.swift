import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Namespace for local image export services introduced in M6.
enum ExportModule {}

// MARK: - Action policy

/// The result of an export operation. Cancellation is a normal user outcome and is deliberately
/// kept distinct from an error so the UI can retain the capture without showing a failure alert.
enum ExportActionResult: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed
}

typealias ExportOutcome = ExportActionResult
typealias CaptureActionResult = ExportActionResult
typealias ExportResult = ExportActionResult

/// The only two terminal overlay decisions. A failed or cancelled operation must never discard a
/// user's capture or annotations.
enum CaptureActionOutcome: Equatable, Sendable {
    case close
    case retain

    static var closeOverlay: Self { .close }
    static var closeCapture: Self { .close }
    static var retainOverlay: Self { .retain }
    static var keepOpen: Self { .retain }
}

typealias ExportActionOutcome = CaptureActionOutcome
typealias ActionOutcome = CaptureActionOutcome

enum CaptureActionPolicy {
    static func outcome(for action: CaptureEditorAction, result: ExportActionResult) -> CaptureActionOutcome {
        guard result == .succeeded else { return .retain }
        switch action {
        case .copy, .save, .saveAs, .print, .share:
            return .close
        case .cancel:
            return .retain
        }
    }

    static func shouldClose(action: CaptureEditorAction, result: ExportActionResult) -> Bool {
        outcome(for: action, result: result) == .close
    }
}

// MARK: - Structured errors

enum ExportError: LocalizedError, Equatable, Sendable {
    case noSelection
    case invalidSelection
    case unsupportedFormat(OutputFormat)
    case invalidQuality(Int)
    case compositorFailed(String)
    case encoderFailed(String)
    case clipboardFailed(String)
    case savePanelFailed(String)
    case saveCancelled
    case folderUnavailable(String)
    case writeFailed(String)
    case printFailed(String)
    case shareFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSelection:
            "Select an image region before exporting."
        case .invalidSelection:
            "The selected region is empty or outside the captured display."
        case let .unsupportedFormat(format):
            "The \(format.displayName) image format is not available on this Mac."
        case let .invalidQuality(value):
            "Image quality must be between 1 and 100 (received \(value))."
        case let .compositorFailed(message):
            "The image could not be composited: \(message)"
        case let .encoderFailed(message):
            "The image could not be encoded: \(message)"
        case let .clipboardFailed(message):
            "The image could not be copied: \(message)"
        case let .savePanelFailed(message):
            "The save panel could not be shown: \(message)"
        case .saveCancelled:
            "Save cancelled."
        case let .folderUnavailable(path):
            "The recent save folder is no longer available: \(path)"
        case let .writeFailed(message):
            "The image could not be written: \(message)"
        case let .printFailed(message):
            "The image could not be printed: \(message)"
        case let .shareFailed(message):
            "The image could not be shared: \(message)"
        }
    }
}

// MARK: - Immutable export input and native compositor

/// A value snapshot handed to export. It owns no mutable overlay state and strips any transient
/// gesture preview before the compositor sees it.
struct ExportInput: @unchecked Sendable {
    let sourceImage: CGImage
    let descriptor: ScreenDescriptor
    let selection: DisplayLocalRect
    let imagePixelRect: ImagePixelRect
    let document: AnnotationDocument

    init(
        snapshot: DisplaySnapshot,
        selection: DisplayLocalRect,
        document: AnnotationDocument? = nil
    ) throws {
        let geometry = DisplayGeometry(descriptor: snapshot.descriptor, imageSize: snapshot.pixelSize)
        let pixelRect = geometry.imagePixelRect(for: selection)
        guard !pixelRect.isEmpty else { throw ExportError.invalidSelection }
        self.sourceImage = snapshot.image
        self.descriptor = snapshot.descriptor
        self.selection = selection
        self.imagePixelRect = pixelRect
        self.document = (document ?? AnnotationDocument(canvasBounds: CanvasRect(selection.rect))).committedOnly
    }

    init(
        sourceImage: CGImage,
        descriptor: ScreenDescriptor,
        selection: DisplayLocalRect,
        document: AnnotationDocument? = nil
    ) throws {
        try self.init(
            snapshot: DisplaySnapshot(descriptor: descriptor.replacing(pixelSize: PixelSize(width: sourceImage.width, height: sourceImage.height)), image: sourceImage),
            selection: selection,
            document: document
        )
    }

    init(
        snapshot: DisplaySnapshot,
        selection: CGRect,
        document: AnnotationDocument? = nil
    ) throws {
        try self.init(snapshot: snapshot, selection: DisplayLocalRect(selection), document: document)
    }

    var source: CGImage { sourceImage }
    var crop: ImagePixelRect { imagePixelRect }
    var annotations: AnnotationDocument { document }
}

enum NativePixelCompositor {
    static func composite(_ input: ExportInput) throws -> CGImage {
        let crop = input.imagePixelRect.clamped(to: PixelSize(width: input.sourceImage.width, height: input.sourceImage.height))
        guard !crop.isEmpty, let cropped = input.sourceImage.cropping(to: crop.cgRect) else {
            throw ExportError.compositorFailed("The source image could not be cropped.")
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: crop.width,
            height: crop.height,
            bitsPerComponent: 8,
            bytesPerRow: crop.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ExportError.compositorFailed("A native sRGB bitmap context could not be created.")
        }

        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        context.setBlendMode(.normal)

        // The document stores lower-left logical canvas vectors. The destination is the exact
        // native pixel rectangle, so one compositor path serves preview/export without a Retina
        // downscale or a second text renderer.
        if !input.document.isEmpty {
            AnnotationRenderer.drawVectors(
                document: input.document,
                in: context,
                destination: CGRect(x: 0, y: 0, width: crop.width, height: crop.height)
            )
        }
        guard let result = context.makeImage() else {
            throw ExportError.compositorFailed("The native bitmap could not be finalized.")
        }
        return result
    }

    static func composite(input: ExportInput) throws -> CGImage { try composite(input) }

    static func render(input: ExportInput) throws -> CGImage { try composite(input) }

    static func crop(source: CGImage, to rect: ImagePixelRect) throws -> CGImage {
        let clamped = rect.clamped(to: PixelSize(width: source.width, height: source.height))
        guard !clamped.isEmpty, let image = source.cropping(to: clamped.cgRect) else {
            throw ExportError.invalidSelection
        }
        return image
    }

    static func crop(source: CGImage, pixelRect: ImagePixelRect) throws -> CGImage {
        try crop(source: source, to: pixelRect)
    }
}

typealias CompositeRenderer = NativePixelCompositor

// MARK: - Image I/O encoding

struct ImageEncoderPolicy: Equatable, Sendable {
    let format: OutputFormat
    let quality: Int

    init(format: OutputFormat, quality: Int = 90) throws {
        guard (1...100).contains(quality) else { throw ExportError.invalidQuality(quality) }
        self.format = format
        self.quality = quality
    }

    init(uncheckedFormat format: OutputFormat, quality: Int = 90) {
        self.format = format
        self.quality = min(max(quality, 1), 100)
    }

    var typeIdentifier: String {
        switch format {
        case .png: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        case .heic: UTType.heic.identifier
        case .bmp: UTType.bmp.identifier
        }
    }

    var uti: UTType { UTType(typeIdentifier) ?? .data }
    var utiIdentifier: String { typeIdentifier }
    var fileExtension: String { format.rawValue }
    var pathExtension: String { fileExtension }
    var appliesQuality: Bool { format.supportsQuality }
    var isLossy: Bool { format.supportsQuality }
    var flattensAlpha: Bool { format == .jpeg || format == .bmp }

    var destinationProperties: [CFString: Any] {
        guard appliesQuality else { return [:] }
        return [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100]
    }
}

enum ImageEncodingError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(OutputFormat)
    case invalidQuality(Int)
    case destinationUnavailable(String)
    case flattenFailed
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(format): "\(format.displayName) encoding is unavailable on this Mac."
        case let .invalidQuality(value): "Image quality must be between 1 and 100 (received \(value))."
        case let .destinationUnavailable(message): "Image encoder unavailable: \(message)"
        case .flattenFailed: "The image could not be flattened against white."
        case .finalizeFailed: "Image I/O could not finalize the output data."
        }
    }
}

enum OpaqueImagePreparer {
    static func whiteBackground(_ image: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageEncodingError.flattenFailed }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ImageEncodingError.flattenFailed }
        return result
    }
}

protocol ImageEncoding: Sendable {
    func encode(_ image: CGImage, policy: ImageEncoderPolicy) throws -> Data
    func encode(_ image: CGImage, format: OutputFormat, quality: Int) throws -> Data
    func encodePNG(_ image: CGImage) throws -> Data
    func encodeTIFF(_ image: CGImage) throws -> Data
}

extension ImageEncoding {
    func encode(_ image: CGImage, policy: ImageEncoderPolicy) throws -> Data {
        try encode(image, format: policy.format, quality: policy.quality)
    }

    func encodePNG(_ image: CGImage) throws -> Data {
        try encode(image, format: .png, quality: AppSettings.fixedImageQuality)
    }

    func encodeTIFF(_ image: CGImage) throws -> Data {
        throw ImageEncodingError.destinationUnavailable(UTType.tiff.identifier)
    }
}

struct ImageIOEncoder: ImageEncoding, Sendable {
    init() {}

    func encode(_ image: CGImage, policy: ImageEncoderPolicy) throws -> Data {
        let available = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard available.contains(policy.typeIdentifier) else {
            throw ImageEncodingError.unsupportedFormat(policy.format)
        }
        let imageToEncode: CGImage
        if policy.flattensAlpha {
            imageToEncode = try OpaqueImagePreparer.whiteBackground(image)
        } else {
            imageToEncode = image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            policy.typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ImageEncodingError.destinationUnavailable(policy.typeIdentifier)
        }
        CGImageDestinationAddImage(destination, imageToEncode, policy.destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageEncodingError.finalizeFailed }
        return data as Data
    }

    func encode(_ image: CGImage, format: OutputFormat, quality: Int) throws -> Data {
        do {
            return try encode(image, policy: ImageEncoderPolicy(format: format, quality: quality))
        } catch let error as ImageEncodingError {
            throw error
        } catch {
            throw ImageEncodingError.destinationUnavailable(error.localizedDescription)
        }
    }

    func encodePNG(_ image: CGImage) throws -> Data {
        try encode(image, policy: ImageEncoderPolicy(uncheckedFormat: .png))
    }

    func encodeTIFF(_ image: CGImage) throws -> Data {
        let available = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard available.contains(UTType.tiff.identifier) else {
            throw ImageEncodingError.destinationUnavailable(UTType.tiff.identifier)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else {
            throw ImageEncodingError.destinationUnavailable(UTType.tiff.identifier)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageEncodingError.finalizeFailed }
        return data as Data
    }
}

typealias ImageFileEncoder = ImageIOEncoder
typealias ImageFileEncoding = ImageEncoding

// MARK: - Clipboard

/// All clipboard representations are prepared before the pasteboard is touched. The two data
/// blobs are committed together by `PasteboardAdapter`; this value also gives fakes a deterministic
/// seam for modeling representation generation independently from pasteboard mutation.
struct ClipboardRepresentations: Equatable, Sendable {
    let png: Data
    let tiff: Data

    var compatibility: Data { tiff }
    var compatibilityData: Data { tiff }
}

/// Native-pixel copy work is deliberately value-only. It can therefore run away from AppKit's
/// main actor; only publication of the resulting immutable data is allowed to touch NSPasteboard.
protocol ClipboardRepresentationPreparing: Sendable {
    func prepareRepresentations(for input: ExportInput) throws -> ClipboardRepresentations
}

struct NativeClipboardRepresentationPreparer: ClipboardRepresentationPreparing, Sendable {
    let encoder: any ImageEncoding

    init(encoder: any ImageEncoding = ImageIOEncoder()) {
        self.encoder = encoder
    }

    func prepareRepresentations(for input: ExportInput) throws -> ClipboardRepresentations {
        try Task.checkCancellation()
        let image = try NativePixelCompositor.composite(input)
        try Task.checkCancellation()
        do {
            let png = try encoder.encodePNG(image)
            try Task.checkCancellation()
            let tiff = try encoder.encodeTIFF(image)
            try Task.checkCancellation()
            return ClipboardRepresentations(png: png, tiff: tiff)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportError.clipboardFailed(error.localizedDescription)
        }
    }
}

@MainActor
protocol PasteboardWriting: AnyObject {
    func clearContents()
    @discardableResult func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool

    /// Adds one item with both representations after ClipboardWriter has cleared old items.
    /// The writer clears again if this publication fails.
    @discardableResult func writeRepresentations(_ representations: ClipboardRepresentations) -> Bool
}

@MainActor
extension PasteboardWriting {
    /// Compatibility default for narrow test doubles that only implement `setData`. The native
    /// adapter below overrides this with a one-item NSPasteboard `writeObjects` call.
    @discardableResult
    func writeRepresentations(_ representations: ClipboardRepresentations) -> Bool {
        guard setData(representations.png, forType: .png) else {
            clearContents()
            return false
        }
        guard setData(representations.tiff, forType: .tiff) else {
            clearContents()
            return false
        }
        return true
    }
}

@MainActor
final class PasteboardAdapter: PasteboardWriting {
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func clearContents() { pasteboard.clearContents() }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setData(data, forType: type)
    }

    @discardableResult
    func writeRepresentations(_ representations: ClipboardRepresentations) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(representations.png, forType: .png),
              item.setData(representations.tiff, forType: .tiff)
        else {
            pasteboard.clearContents()
            return false
        }

        // NSPasteboard appends one item containing both representations. ClipboardWriter already
        // cleared older items. If AppKit reports a
        // failed commit, clear again so an implementation that exposed a partial item cannot
        // leave VibeShot's PNG/TIFF pair in an indeterminate state. This may discard the previous
        // pasteboard owner because NSPasteboard has no rollback/transaction API; that limitation
        // is surfaced as a copy error rather than silently reporting success.
        let committed = pasteboard.writeObjects([item])
        if !committed { pasteboard.clearContents() }
        return committed
    }
}

@MainActor
final class ClipboardWriter {
    private let pasteboard: PasteboardWriting
    private let encoder: any ImageEncoding

    init(pasteboard: PasteboardWriting = PasteboardAdapter(), encoder: any ImageEncoding = ImageIOEncoder()) {
        self.pasteboard = pasteboard
        self.encoder = encoder
    }

    func prepareRepresentations(image: CGImage) throws -> ClipboardRepresentations {
        do {
            return ClipboardRepresentations(
                png: try encoder.encodePNG(image),
                tiff: try encoder.encodeTIFF(image)
            )
        } catch {
            throw ExportError.clipboardFailed(error.localizedDescription)
        }
    }

    func copy(image: CGImage) throws {
        // Generate every representation before any pasteboard mutation. A compatibility encoding
        // failure therefore cannot leave a newly written PNG behind.
        let representations = try prepareRepresentations(image: image)
        try publish(representations)
    }

    /// The caller must have already generated all representations. This is intentionally the
    /// only pasteboard boundary, so an obsolete/cancelled export has nothing to publish.
    func publish(_ representations: ClipboardRepresentations) throws {
        // All representations are ready; replacing clipboard contents begins here.
        pasteboard.clearContents()
        guard pasteboard.writeRepresentations(representations) else {
            // The native adapter already clears on failure. Keep this defensive clear at the
            // writer boundary so test doubles and future adapters share the same contract.
            pasteboard.clearContents()
            throw ExportError.clipboardFailed("The pasteboard rejected the image transaction.")
        }
    }
}

typealias ClipboardService = ClipboardWriter

// MARK: - Folder bookmarks and balanced security-scoped access

enum FolderBookmarkError: LocalizedError, Equatable, Sendable {
    case createFailed(String)
    case resolveFailed(String)
    case stale

    var errorDescription: String? {
        switch self {
        case let .createFailed(message): "The save-folder permission could not be remembered: \(message)"
        case let .resolveFailed(message): "The remembered save folder could not be opened: \(message)"
        case .stale: "The remembered save-folder permission is stale. Choose the folder again."
        }
    }
}

@MainActor
final class FolderBookmarkService {
    func makeBookmark(for url: URL) throws -> FolderBookmark {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return FolderBookmark(data: data)
        } catch {
            throw FolderBookmarkError.createFailed(error.localizedDescription)
        }
    }

    func resolve(_ bookmark: FolderBookmark) throws -> URL {
        guard bookmark.isCurrent else { throw FolderBookmarkError.stale }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark.data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale else { throw FolderBookmarkError.stale }
            return url
        } catch let error as FolderBookmarkError {
            throw error
        } catch {
            throw FolderBookmarkError.resolveFailed(error.localizedDescription)
        }
    }

    /// Uses a bookmark when available and falls back to the legacy path used by the unsandboxed
    /// M1 settings. Access is always balanced, including when the operation throws.
    func withAccess<T>(to url: URL, _ operation: () throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        return try operation()
    }
}

typealias SecurityScopedFolderAccess = FolderBookmarkService

// MARK: - Save naming and atomic file writes

struct CollisionSafeFileName: Sendable {
    let date: Date
    let calendar: Calendar

    init(date: Date = Date(), calendar: Calendar = .current) {
        self.date = date
        self.calendar = calendar
    }

    var baseName: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "VibeShot \(formatter.string(from: date))"
    }

    func url(in folder: URL, format: OutputFormat, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var index = 0
        while true {
            let suffix = index == 0 ? "" : " (\(index))"
            let candidate = folder.appendingPathComponent("\(baseName)\(suffix).\(format.rawValue)")
            if !fileExists(candidate) { return candidate }
            index += 1
        }
    }
}

typealias SaveNameGenerator = CollisionSafeFileName

protocol AtomicFileWriting: Sendable {
    func writeAtomically(_ data: Data, to url: URL) throws
}

struct AtomicFileWriter: AtomicFileWriting {
    init() {}

    func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ExportError.writeFailed("\(url.path): \(error.localizedDescription)")
        }
    }
}

@MainActor
protocol SavePanelPresenting: AnyObject {
    func chooseURL(defaultDirectory: URL?, suggestedFileName: String, format: OutputFormat) throws -> URL?
    func chooseURLAsync(defaultDirectory: URL?, suggestedFileName: String, format: OutputFormat) async throws -> URL?
    func cancel()
}

extension SavePanelPresenting {
    func chooseURLAsync(defaultDirectory: URL?, suggestedFileName: String, format: OutputFormat) async throws -> URL? {
        try chooseURL(defaultDirectory: defaultDirectory, suggestedFileName: suggestedFileName, format: format)
    }
    func cancel() {}
}

@MainActor
final class SavePanelService: SavePanelPresenting {
    private var activePanel: NSSavePanel?
    func cancel() { activePanel?.cancel(nil) }

    func chooseURLAsync(defaultDirectory: URL?, suggestedFileName: String, format: OutputFormat) async throws -> URL? {
        try Task.checkCancellation()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [UTType(ImageEncoderPolicy(uncheckedFormat: format).typeIdentifier) ?? .data]
        panel.nameFieldStringValue = suggestedFileName
        panel.directoryURL = defaultDirectory
        panel.level = .modalPanel
        activePanel = panel
        defer { if activePanel === panel { activePanel = nil } }
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }
    func chooseURL(defaultDirectory: URL?, suggestedFileName: String, format: OutputFormat) throws -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [UTType(ImageEncoderPolicy(uncheckedFormat: format).typeIdentifier) ?? .data]
        panel.nameFieldStringValue = suggestedFileName
        panel.directoryURL = defaultDirectory
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }
}

// MARK: - Print and share adapters

struct PrintLayout: Equatable, Sendable {
    static func aspectFit(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        aspectFit(imageSize: imageSize, in: bounds)
    }
}

enum PrintResult: Equatable, Sendable {
    case accepted
    case completed
    case cancelled
}

@MainActor
protocol PrintServicing: AnyObject {
    func print(image: CGImage) throws -> PrintResult
}

@MainActor
final class PrintImageView: NSView {
    let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel("VibeShot screenshot")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let imageRect = PrintLayout.aspectFit(imageSize: image.size, in: bounds)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

@MainActor
final class AppKitPrintService: PrintServicing {
    func print(image: CGImage) throws -> PrintResult {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let view = PrintImageView(image: nsImage)
        view.frame = NSRect(x: 0, y: 0, width: 612, height: 792)
        let operation = NSPrintOperation(view: view)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        guard operation.run() else { return .cancelled }
        return .completed
    }
}

@MainActor
protocol ShareServicing: AnyObject {
    func present(image: CGImage, from view: NSView, completion: @escaping (ExportActionResult) -> Void)
    func cancel()
}

@MainActor
extension ShareServicing {
    func cancel() {}
}

/// The picker and delegate are retained until AppKit reports success or failure. No close event
/// is inferred from presenting the sheet, so a dismissed picker leaves the capture intact.
@MainActor
final class AppKitShareService: NSObject, ShareServicing, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private var activePicker: NSSharingServicePicker?
    private var completion: ((ExportActionResult) -> Void)?
    private var activeService: NSSharingService?

    func present(image: CGImage, from view: NSView, completion: @escaping (ExportActionResult) -> Void) {
        guard activePicker == nil else { return }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let picker = NSSharingServicePicker(items: [nsImage])
        picker.delegate = self
        activePicker = picker
        self.completion = completion
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func cancel() { finish(.cancelled) }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        proposedServices
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else {
            finish(.cancelled)
            return
        }
        activeService = service
        service.delegate = self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(.succeeded)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish(.failed)
    }

    private func finish(_ result: ExportActionResult) {
        let callback = completion
        completion = nil
        activeService?.delegate = nil
        activeService = nil
        activePicker = nil
        callback?(result)
    }
}

// MARK: - Export coordinator

/// Coordinates pure compositing with the native AppKit adapters. The consumer owns the action
/// lifecycle/re-entry guard; this type intentionally returns outcomes instead of closing panels.
@MainActor
final class ExportCoordinator {
    let settingsStore: SettingsPersisting?
    let encoder: any ImageEncoding
    let clipboard: ClipboardWriter
    let clipboardPreparer: any ClipboardRepresentationPreparing
    let savePanel: SavePanelPresenting
    let fileWriter: any AtomicFileWriting
    let bookmarkService: FolderBookmarkService
    let printService: PrintServicing
    let shareService: ShareServicing
    let nameGenerator: CollisionSafeFileName
    let metrics: PrivacySafeMetrics

    init(
        settingsStore: SettingsPersisting? = nil,
        encoder: any ImageEncoding = ImageIOEncoder(),
        clipboard: ClipboardWriter? = nil,
        clipboardPreparer: (any ClipboardRepresentationPreparing)? = nil,
        savePanel: SavePanelPresenting = SavePanelService(),
        fileWriter: any AtomicFileWriting = AtomicFileWriter(),
        bookmarkService: FolderBookmarkService = FolderBookmarkService(),
        printService: PrintServicing = AppKitPrintService(),
        shareService: ShareServicing = AppKitShareService(),
        nameGenerator: CollisionSafeFileName = CollisionSafeFileName(),
        metrics: PrivacySafeMetrics = PrivacySafeMetrics()
    ) {
        self.settingsStore = settingsStore
        self.encoder = encoder
        self.clipboard = clipboard ?? ClipboardWriter(encoder: encoder)
        self.clipboardPreparer = clipboardPreparer ?? NativeClipboardRepresentationPreparer(encoder: encoder)
        self.savePanel = savePanel
        self.fileWriter = fileWriter
        self.bookmarkService = bookmarkService
        self.printService = printService
        self.shareService = shareService
        self.nameGenerator = nameGenerator
        self.metrics = metrics
    }

    func composite(_ input: ExportInput) throws -> CGImage {
        try NativePixelCompositor.composite(input)
    }

    func copy(input: ExportInput) throws -> ExportActionResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var estimatedBytes = 0
        defer {
            metrics.record(
                .export,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt,
                count: 1,
                estimatedBytes: estimatedBytes
            )
        }
        do {
            let image = try composite(input)
            estimatedBytes = privacySafeEstimatedBytes(for: image)
            try clipboard.copy(image: image)
            return .succeeded
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.clipboardFailed(error.localizedDescription)
        }
    }

    /// Performs composition and PNG/TIFF encoding on a detached worker. `ExportInput` and the
    /// returned representations are immutable transfer values; pasteboard publication remains on
    /// the main actor in `publishCopy`.
    func prepareCopy(input: ExportInput) async throws -> ClipboardRepresentations {
        let preparer = clipboardPreparer
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try preparer.prepareRepresentations(for: input)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// The session task owns cancellation. Once an atomic write begins it may finish even if the
    /// user cancels; a completed write is always success, never reported as a failed save.
    func saveAsync(input: ExportInput, saveAs: Bool, isCurrent: @MainActor () -> Bool) async throws -> (result: ExportActionResult, url: URL?) {
        let format = settingsStore?.settings.outputFormat ?? .png
        let quality = AppSettings.fixedImageQuality
        let folder = try recentFolderURL()
        let chosen: URL?
        if saveAs || folder == nil {
            chosen = try await savePanel.chooseURLAsync(defaultDirectory: folder, suggestedFileName: "\(nameGenerator.baseName).\(format.rawValue)", format: format)
            guard chosen != nil else { return (.cancelled, nil) }
        } else { chosen = nil }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let encoder = encoder
        let writer = fileWriter
        let generator = nameGenerator
        let explicitURL = chosen.map { ensureExtension($0, format: format) }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try NativePixelCompositor.composite(input)
            try Task.checkCancellation()
            let data = try encoder.encode(image, format: format, quality: quality)
            try Task.checkCancellation()
            let directory = explicitURL?.deletingLastPathComponent() ?? folder!
            let access = directory.startAccessingSecurityScopedResource()
            defer { if access { directory.stopAccessingSecurityScopedResource() } }
            let url = explicitURL ?? generator.url(in: directory, format: format)
            try Task.checkCancellation()
            try writer.writeAtomically(data, to: url)
            return url
        }
        let url = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        if isCurrent() { try? rememberFolder(url.deletingLastPathComponent()) }
        return (.succeeded, url)
    }

    func publishCopy(_ representations: ClipboardRepresentations) throws -> ExportActionResult {
        do {
            try clipboard.publish(representations)
            return .succeeded
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.clipboardFailed(error.localizedDescription)
        }
    }

    func save(input: ExportInput, saveAs: Bool = false) throws -> (result: ExportActionResult, url: URL?) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var estimatedBytes = 0
        defer {
            metrics.record(
                .export,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt,
                count: 1,
                estimatedBytes: estimatedBytes
            )
        }
        let format = settingsStore?.settings.outputFormat ?? .png
        let quality = AppSettings.fixedImageQuality
        let image: CGImage
        let data: Data
        do {
            image = try composite(input)
            data = try encoder.encode(image, format: format, quality: quality)
            estimatedBytes = data.count
        } catch let error as ImageEncodingError {
            if case let .unsupportedFormat(value) = error {
                throw ExportError.unsupportedFormat(value)
            }
            throw ExportError.encoderFailed(error.localizedDescription)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.encoderFailed(error.localizedDescription)
        }

        let folder = try recentFolderURL()
        let suggested = "\(nameGenerator.baseName).\(format.rawValue)"
        let url: URL
        if saveAs || folder == nil {
            let chosen: URL?
            do {
                chosen = try savePanel.chooseURL(defaultDirectory: folder, suggestedFileName: suggested, format: format)
            } catch {
                throw ExportError.savePanelFailed(error.localizedDescription)
            }
            guard let chosen else {
                return (.cancelled, nil)
            }
            url = ensureExtension(chosen, format: format)
        } else {
            guard let folder else { throw ExportError.folderUnavailable("recent folder") }
            url = bookmarkService.withAccess(to: folder) {
                nameGenerator.url(in: folder, format: format)
            }
        }

        do {
            try writeWithFolderAccess(data, to: url)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.writeFailed("\(url.path): \(error.localizedDescription)")
        }
        // The image is already durably written. A failure to persist the optional recent-folder
        // bookmark must not turn a successful save into a destructive-looking failure or discard
        // the capture; the next Save As can simply ask again.
        try? rememberFolder(url.deletingLastPathComponent())
        _ = image // Keep composition explicit and releaseable after the write.
        return (.succeeded, url)
    }

    func print(input: ExportInput) throws -> ExportActionResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            metrics.record(
                .export,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt,
                count: 1
            )
        }
        do {
            switch try printService.print(image: composite(input)) {
            case .accepted, .completed: return .succeeded
            case .cancelled: return .cancelled
            }
        }
        catch let error as ExportError { throw error }
        catch { throw ExportError.printFailed(error.localizedDescription) }
    }

    func share(input: ExportInput, from view: NSView, completion: @escaping (ExportActionResult) -> Void) throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var estimatedBytes = 0
        defer {
            metrics.record(
                .export,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt,
                count: 1,
                estimatedBytes: estimatedBytes
            )
        }
        do {
            let image = try composite(input)
            estimatedBytes = privacySafeEstimatedBytes(for: image)
            shareService.present(image: image, from: view, completion: completion)
        } catch {
            throw ExportError.shareFailed(error.localizedDescription)
        }
    }

    func cancelPendingShare() {
        savePanel.cancel()
        shareService.cancel()
        if let modal = NSApp.modalWindow {
            NSApp.abortModal()
            modal.orderOut(nil)
        }
    }

    private func recentFolderURL() throws -> URL? {
        guard let settings = settingsStore?.settings, settings.saveDestination == .recentFolder else { return nil }
        if let bookmark = settings.recentFolderBookmark, bookmark.isCurrent {
            do {
                let url = try bookmarkService.resolve(bookmark)
                let isDirectory = bookmarkService.withAccess(to: url) {
                    var value: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
                }
                guard isDirectory else {
                    throw ExportError.folderUnavailable(url.path)
                }
                return url
            } catch {
                // A migrated/legacy path is still useful in an unsandboxed build. Try it before
                // forcing the user through a panel, then report the structured failure if neither
                // representation resolves.
            }
        }
        if let path = settings.recentFolderPath {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let isDirectory = bookmarkService.withAccess(to: url) {
                var value: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
            }
            guard isDirectory else {
                throw ExportError.folderUnavailable(path)
            }
            return url
        }
        return nil
    }

    private func rememberFolder(_ folder: URL) throws {
        guard let settingsStore else { return }
        let destination = settingsStore.settings.saveDestination
        do {
            let bookmark = try bookmarkService.makeBookmark(for: folder)
            try settingsStore.update {
                $0.recentFolderPath = folder.path
                $0.recentFolderBookmark = bookmark
                $0.saveDestination = destination
            }
        } catch {
            // The app is intentionally unsandboxed for the MVP. Preserve the path even when the
            // optional security-scoped bookmark API is unavailable on a particular filesystem.
            try settingsStore.update {
                $0.recentFolderPath = folder.path
                $0.recentFolderBookmark = nil
                $0.saveDestination = destination
            }
        }
    }

    private func writeWithFolderAccess(_ data: Data, to url: URL) throws {
        try bookmarkService.withAccess(to: url.deletingLastPathComponent()) {
            try fileWriter.writeAtomically(data, to: url)
        }
    }

    private func ensureExtension(_ url: URL, format: OutputFormat) -> URL {
        guard url.pathExtension.isEmpty else { return url }
        return url.appendingPathExtension(format.rawValue)
    }
}
