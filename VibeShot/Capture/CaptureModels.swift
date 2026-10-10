import CoreGraphics
import Foundation

/// A stable, typed identity for a physical display.
struct DisplayID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var description: String { String(rawValue) }
}

struct PixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    var isValid: Bool { width > 0 && height > 0 }
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

/// AppKit global coordinates. The origin is the macOS global screen origin and the y axis points up.
struct GlobalScreenRect: Equatable, Sendable {
    let rect: CGRect

    init(_ rect: CGRect) {
        self.rect = rect
    }

    var isFinite: Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite
    }
}

struct GlobalScreenPoint: Equatable, Sendable {
    let x: Double
    let y: Double
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(_ point: CGPoint) { self.init(x: Double(point.x), y: Double(point.y)) }
}

/// Display-local normalized selection geometry; no captured pixels or annotation data.
struct RememberedRegion: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
            x >= 0 && y >= 0 && width > 0 && height > 0 &&
            x <= 1 && y <= 1 && width <= 1 && height <= 1 &&
            x + width <= 1.000001 && y + height <= 1.000001
    }

    static func normalized(from selection: DisplayLocalRect, in bounds: CGRect) -> Self? {
        let rect = selection.rect.standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              bounds.contains(rect) else { return nil }
        let value = Self(
            x: Double((rect.minX - bounds.minX) / bounds.width),
            y: Double((rect.minY - bounds.minY) / bounds.height),
            width: Double(rect.width / bounds.width), height: Double(rect.height / bounds.height)
        )
        return value.isValid ? value : nil
    }

    func displayLocalRect(in bounds: CGRect, minimumSize: CGFloat = 8) -> DisplayLocalRect? {
        guard isValid, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let width = min(bounds.width, max(CGFloat(self.width) * bounds.width, minimumSize))
        let height = min(bounds.height, max(CGFloat(self.height) * bounds.height, minimumSize))
        let x = min(max(bounds.minX + CGFloat(self.x) * bounds.width, bounds.minX), bounds.maxX - width)
        let y = min(max(bounds.minY + CGFloat(self.y) * bounds.height, bounds.minY), bounds.maxY - height)
        return DisplayLocalRect(CGRect(x: x, y: y, width: width, height: height))
    }
}

/// Points relative to one display. The origin is the display's lower-left corner and the y axis points up.
struct DisplayLocalRect: Equatable, Sendable {
    let rect: CGRect

    init(_ rect: CGRect) {
        self.rect = rect
    }

    var isFinite: Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite
    }
}

/// Integer pixels in a CGImage. The origin is the image's upper-left corner and the y axis points down.
struct ImagePixelRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var minX: Int { x }
    var minY: Int { y }
    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func clamped(to size: PixelSize) -> ImagePixelRect {
        let lowerX = max(0, min(x, size.width))
        let lowerY = max(0, min(y, size.height))
        let upperX = max(lowerX, min(maxX, size.width))
        let upperY = max(lowerY, min(maxY, size.height))
        return ImagePixelRect(x: lowerX, y: lowerY, width: upperX - lowerX, height: upperY - lowerY)
    }
}

struct ScreenDescriptor: Equatable, Sendable, Identifiable {
    let id: DisplayID
    let frame: GlobalScreenRect
    /// The unobscured area of the display in global AppKit points. This is used for positioning
    /// future controls without changing the capture coordinate system, which always uses `frame`.
    let visibleFrame: GlobalScreenRect
    let pointPixelScale: Double
    let pixelSize: PixelSize
    let persistentDisplayID: String?

    init(
        id: DisplayID,
        frame: GlobalScreenRect,
        pointPixelScale: Double,
        pixelSize: PixelSize? = nil,
        visibleFrame: GlobalScreenRect? = nil,
        persistentDisplayID: String? = nil
    ) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.pointPixelScale = pointPixelScale
        self.pixelSize = pixelSize ?? PixelSize(
            width: Int((frame.rect.width * pointPixelScale).rounded(.toNearestOrAwayFromZero)),
            height: Int((frame.rect.height * pointPixelScale).rounded(.toNearestOrAwayFromZero))
        )
        self.persistentDisplayID = persistentDisplayID
    }

    init(
        id: DisplayID,
        frame: GlobalScreenRect,
        visibleFrame: GlobalScreenRect,
        pointPixelScale: Double,
        pixelSize: PixelSize? = nil,
        persistentDisplayID: String? = nil
    ) {
        self.init(
            id: id,
            frame: frame,
            pointPixelScale: pointPixelScale,
            pixelSize: pixelSize,
            visibleFrame: visibleFrame,
            persistentDisplayID: persistentDisplayID
        )
    }

    var displayID: DisplayID { id }

    func replacing(pixelSize: PixelSize) -> ScreenDescriptor {
        ScreenDescriptor(
            id: id,
            frame: frame,
            pointPixelScale: pointPixelScale,
            pixelSize: pixelSize,
            visibleFrame: visibleFrame,
            persistentDisplayID: persistentDisplayID
        )
    }
}

enum CaptureCommand: Equatable, Sendable {
    case region
    case fullScreen(displayID: DisplayID?)

    /// Compatibility spelling for the generic M1 shortcut/menu intent.
    static var fullScreen: CaptureCommand { .fullScreen(displayID: nil) }
}

enum CapturePhase: Equatable, Sendable {
    case idle
    case checkingPermission
    case permissionRequired
    case snapshotting
    case consuming
    case selecting
    case editing
    case exporting
}

/// The immutable, session-scoped source set handed to the next milestone's consumer seam.
struct CaptureSession: @unchecked Sendable, Identifiable {
    let id: UUID
    let command: CaptureCommand
    let displays: [DisplaySnapshot]
    let pointerLocation: GlobalScreenPoint?

    init(id: UUID = UUID(), command: CaptureCommand, displays: [DisplaySnapshot], pointerLocation: GlobalScreenPoint? = nil) {
        self.id = id
        self.command = command
        self.displays = displays
        self.pointerLocation = pointerLocation
    }

    var snapshots: [DisplaySnapshot] { displays }
}

enum RememberedRegionDisplayResolver {
    static func resolve(command: CaptureCommand, descriptors: [ScreenDescriptor], pointer: GlobalScreenPoint?) -> ScreenDescriptor? {
        guard command == .region else { return nil }
        let ordered = descriptors.sorted { $0.id.rawValue < $1.id.rawValue }
        guard let pointer else { return ordered.first }
        return ordered.first { $0.frame.rect.contains(pointer.cgPoint) } ?? ordered.first
    }
}

/// A source image paired with the descriptor used to capture it. CGImage is immutable for the
/// purposes of this pipeline and is deliberately retained only in the active session.
struct DisplaySnapshot: @unchecked Sendable {
    let descriptor: ScreenDescriptor
    let image: CGImage

    var displayID: DisplayID { descriptor.id }
    var pixelSize: PixelSize { PixelSize(width: image.width, height: image.height) }
    var imagePixelSize: PixelSize { pixelSize }
}

enum DisplayGeometryError: LocalizedError, Equatable, Sendable {
    case invalidFrame
    case invalidScale
    case invalidImageSize
    case nonFiniteRect

    var errorDescription: String? {
        switch self {
        case .invalidFrame: "The display frame is invalid."
        case .invalidScale: "The display pixel scale is invalid."
        case .invalidImageSize: "The captured image size is invalid."
        case .nonFiniteRect: "The supplied geometry is not finite."
        }
    }
}
