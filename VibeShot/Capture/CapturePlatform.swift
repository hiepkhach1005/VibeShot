import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor protocol CaptureCommandHandling: AnyObject {
    func requestCapture(_ command: CaptureCommand)
}

enum DisplayProviderError: LocalizedError, Equatable, Sendable {
    case missingScreenNumber
    case duplicateDisplayID(DisplayID)
    case invalidGeometry(DisplayID)

    var errorDescription: String? {
        switch self {
        case .missingScreenNumber:
            "VibeShot could not identify one of the active displays."
        case let .duplicateDisplayID(displayID):
            "The active display list contains display \(displayID) more than once."
        case let .invalidGeometry(displayID):
            "Display \(displayID) reported invalid geometry."
        }
    }
}

/// The AppKit side of the display topology. Its IDs come only from NSScreenNumber.
@MainActor
protocol DisplayDescriptorProviding: AnyObject {
    func currentDisplayDescriptors() throws -> [ScreenDescriptor]
}

@MainActor protocol CapturePointerProviding: AnyObject {
    func currentPointerLocation() -> GlobalScreenPoint?
}

@MainActor final class AppKitCapturePointerProvider: CapturePointerProviding {
    func currentPointerLocation() -> GlobalScreenPoint? { GlobalScreenPoint(NSEvent.mouseLocation) }
}

@MainActor
final class NSScreenDisplayProvider: DisplayDescriptorProviding {
    private let screensProvider: () -> [NSScreen]

    init(screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.screensProvider = screensProvider
    }

    func currentDisplayDescriptors() throws -> [ScreenDescriptor] {
        var seen = Set<DisplayID>()
        var descriptors: [ScreenDescriptor] = []
        for screen in screensProvider() {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw DisplayProviderError.missingScreenNumber
            }
            let id = DisplayID(number.uint32Value)
            guard seen.insert(id).inserted else { throw DisplayProviderError.duplicateDisplayID(id) }

            let frame = screen.frame
            let scale = Double(screen.backingScaleFactor)
            let pixelSize = PixelSize(
                width: Int((frame.width * CGFloat(scale)).rounded(.toNearestOrAwayFromZero)),
                height: Int((frame.height * CGFloat(scale)).rounded(.toNearestOrAwayFromZero))
            )
            let visibleFrame = screen.visibleFrame
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0,
                  visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
                  visibleFrame.width.isFinite, visibleFrame.height.isFinite,
                  visibleFrame.width >= 0, visibleFrame.height >= 0,
                  scale.isFinite, scale > 0, pixelSize.isValid
            else { throw DisplayProviderError.invalidGeometry(id) }
            descriptors.append(ScreenDescriptor(
                id: id,
                frame: GlobalScreenRect(frame),
                pointPixelScale: scale,
                pixelSize: pixelSize,
                visibleFrame: GlobalScreenRect(visibleFrame),
                persistentDisplayID: CGDisplayCreateUUIDFromDisplayID(id.rawValue).map {
                    (CFUUIDCreateString(nil, $0.takeRetainedValue()) as String).lowercased()
                }
            ))
        }
        return descriptors.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}

enum ScreenSnapshotError: LocalizedError, Equatable, Sendable {
    case noDisplays
    case duplicateDisplayID(DisplayID)
    case missingDisplay(DisplayID)
    case unexpectedDisplay(DisplayID)
    case topologyChanged
    case shareableContentFailed(String)
    case captureFailed(DisplayID, String)

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            "No active displays were available for capture."
        case let .duplicateDisplayID(displayID):
            "ScreenCaptureKit returned display \(displayID) more than once."
        case let .missingDisplay(displayID):
            "ScreenCaptureKit did not return active display \(displayID)."
        case let .unexpectedDisplay(displayID):
            "ScreenCaptureKit returned an unexpected display (\(displayID))."
        case .topologyChanged:
            "The display topology changed while VibeShot was preparing the capture."
        case let .shareableContentFailed(message):
            "ScreenCaptureKit could not enumerate displays: \(message)"
        case let .captureFailed(displayID, message):
            "Could not capture display \(displayID): \(message)"
        }
    }
}

protocol ScreenSnapshotProviding: Sendable {
    func captureDisplays(for descriptors: [ScreenDescriptor]) async throws -> [DisplaySnapshot]
}

/// ScreenCaptureKit's one-shot image adapter. It intentionally returns CGImages only in memory;
/// encoding and persistence belong to a later milestone.
final class ScreenCaptureService: ScreenSnapshotProviding, @unchecked Sendable {
    func captureDisplays(for descriptors: [ScreenDescriptor]) async throws -> [DisplaySnapshot] {
        guard !descriptors.isEmpty else { throw ScreenSnapshotError.noDisplays }

        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.current
        } catch {
            throw ScreenSnapshotError.shareableContentFailed(error.localizedDescription)
        }

        let displays = try mapDisplays(descriptors, from: shareableContent.displays)
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownApplications = shareableContent.applications.filter { $0.processID == ownProcessID }
        let ownWindows = shareableContent.windows.filter { $0.owningApplication?.processID == ownProcessID }

        var snapshots: [DisplaySnapshot] = []
        snapshots.reserveCapacity(descriptors.count)
        for descriptor in descriptors.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            try Task.checkCancellation()
            guard let display = displays[descriptor.id] else {
                throw ScreenSnapshotError.missingDisplay(descriptor.id)
            }
            let filter: SCContentFilter
            if ownApplications.isEmpty {
                // A process may be absent from the shareable application list while one of its
                // windows is still reported. Exclude those windows directly in that case.
                filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            } else {
                // `exceptingWindows` are inclusions/exceptions to an application exclusion, so
                // keep the list empty to ensure VibeShot's own windows never re-enter the filter.
                filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            }
            let configuration = SCStreamConfiguration()
            // The requested size follows the display's logical point size and scale. The returned
            // CGImage dimensions remain authoritative because ScreenCaptureKit may adjust them.
            configuration.width = max(1, Int((CGFloat(display.width) * CGFloat(descriptor.pointPixelScale)).rounded(.toNearestOrAwayFromZero)))
            configuration.height = max(1, Int((CGFloat(display.height) * CGFloat(descriptor.pointPixelScale)).rounded(.toNearestOrAwayFromZero)))
            configuration.showsCursor = false
            configuration.queueDepth = 1

            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                throw ScreenSnapshotError.captureFailed(descriptor.id, error.localizedDescription)
            }
            let actualSize = PixelSize(width: image.width, height: image.height)
            guard actualSize.isValid else { throw ScreenSnapshotError.captureFailed(descriptor.id, "The returned image has no pixels.") }
            snapshots.append(DisplaySnapshot(descriptor: descriptor.replacing(pixelSize: actualSize), image: image))
        }
        return snapshots
    }

    private func mapDisplays(_ descriptors: [ScreenDescriptor], from scDisplays: [SCDisplay]) throws -> [DisplayID: SCDisplay] {
        guard !scDisplays.isEmpty else { throw ScreenSnapshotError.noDisplays }

        var requestedIDs = Set<DisplayID>()
        for descriptor in descriptors {
            guard requestedIDs.insert(descriptor.id).inserted else {
                throw ScreenSnapshotError.duplicateDisplayID(descriptor.id)
            }
        }
        var mapped: [DisplayID: SCDisplay] = [:]
        for display in scDisplays {
            let id = DisplayID(display.displayID)
            guard mapped[id] == nil else { throw ScreenSnapshotError.duplicateDisplayID(id) }
            guard requestedIDs.contains(id) else { throw ScreenSnapshotError.unexpectedDisplay(id) }
            mapped[id] = display
        }
        for descriptor in descriptors {
            guard let display = mapped[descriptor.id] else { throw ScreenSnapshotError.missingDisplay(descriptor.id) }
            guard approximatelyEqual(display.frame, descriptor.frame.rect) else {
                throw ScreenSnapshotError.topologyChanged
            }
        }
        guard mapped.count == requestedIDs.count else { throw ScreenSnapshotError.topologyChanged }
        return mapped
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let epsilon: CGFloat = 0.001
        return abs(lhs.minX - rhs.minX) < epsilon && abs(lhs.minY - rhs.minY) < epsilon &&
            abs(lhs.width - rhs.width) < epsilon && abs(lhs.height - rhs.height) < epsilon
    }
}

/// Kept as a small compatibility value for the M1 fixture tests. The M2 pipeline never encodes
/// or persists this value; it holds CGImages in DisplaySnapshot instead.
struct CapturedDisplay: Equatable, Sendable {
    let displayID: UInt32
    let pixelWidth: Int
    let pixelHeight: Int
    let imageData: Data
}

protocol CapturePermissionProviding: Sendable {
    func hasScreenCapturePermission() -> Bool
    func requestScreenCapturePermission() -> Bool
}

final class CoreGraphicsCapturePermissionService: CapturePermissionProviding, @unchecked Sendable {
    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

@MainActor
protocol PermissionRecoveryPresenting: AnyObject {
    func presentScreenRecordingDenied()
}

@MainActor
final class SystemSettingsPermissionRecoveryPresenter: PermissionRecoveryPresenting {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func presentScreenRecordingDenied() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Access Required"
        alert.informativeText = "Allow VibeShot in System Settings > Privacy & Security > Screen Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Keep the fallback URLs fixed and local to System Settings; never open an arbitrary value
        // derived from an error or user-provided string.
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for rawValue in urls {
            guard let url = URL(string: rawValue), workspace.open(url) else { continue }
            break
        }
    }
}

/// Events emitted by a session consumer are always tagged with the session that produced them.
/// This prevents a late callback from an old overlay from changing a newer capture's state.
enum CaptureSessionEvent: Equatable, Sendable {
    case selecting(sessionID: UUID)
    case editing(sessionID: UUID)
    case exporting(sessionID: UUID)
    case completed(sessionID: UUID)
    case cancelled(sessionID: UUID)

    static func selecting(_ sessionID: UUID) -> Self { .selecting(sessionID: sessionID) }
    static func editing(_ sessionID: UUID) -> Self { .editing(sessionID: sessionID) }
    static func exporting(_ sessionID: UUID) -> Self { .exporting(sessionID: sessionID) }
    static func completed(_ sessionID: UUID) -> Self { .completed(sessionID: sessionID) }
    static func cancelled(_ sessionID: UUID) -> Self { .cancelled(sessionID: sessionID) }

    var sessionID: UUID {
        switch self {
        case let .selecting(sessionID), let .editing(sessionID), let .exporting(sessionID), let .completed(sessionID), let .cancelled(sessionID):
            return sessionID
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled: return true
        case .selecting, .editing, .exporting: return false
        }
    }
}

typealias CaptureSessionConsumerEvent = CaptureSessionEvent

/// Consumer ownership is intentionally asynchronous: the coordinator owns the top-level phase,
/// while the overlay/editor reports phase transitions and terminal events back with a session ID.
/// The older completion overload remains available as a source-compatible bridge for M2 test
/// doubles and small platform adapters.
@MainActor
protocol CaptureSessionConsuming: AnyObject {
    func consume(
        _ session: CaptureSession,
        eventHandler: @escaping @MainActor (CaptureSessionEvent) -> Void
    )

    /// M2 compatibility bridge. New consumers should implement the event-handler overload.
    func consume(_ session: CaptureSession, completion: @escaping @MainActor (UUID) -> Void)

    /// Cancellation is idempotent and may be called after a terminal event.
    func cancel(sessionID: UUID)
}

extension CaptureSessionConsuming {
    /// Existing M2 consumers that only implement the completion overload automatically emit a
    /// terminal completed event. New consumers override this method to emit selecting/editing
    /// transitions while the overlay remains visible.
    func consume(
        _ session: CaptureSession,
        eventHandler: @escaping @MainActor (CaptureSessionEvent) -> Void
    ) {
        consume(session) { id in eventHandler(.completed(sessionID: id)) }
    }

    /// Optional for new event-based consumers; the no-op default keeps lightweight test doubles
    /// source compatible while still allowing the coordinator to issue cancellation.
    func consume(_ session: CaptureSession, completion: @escaping @MainActor (UUID) -> Void) {}
    func cancel(sessionID: UUID) {}
}

/// M2 deliberately had no overlay consumer. It now remains as a useful immediate consumer for
/// tests and headless callers; its event is still session-ID tagged.
@MainActor
final class ImmediateCaptureSessionConsumer: CaptureSessionConsuming {
    func consume(
        _ session: CaptureSession,
        eventHandler: @escaping @MainActor (CaptureSessionEvent) -> Void
    ) {
        eventHandler(.completed(sessionID: session.id))
    }

    func consume(_ session: CaptureSession, completion: @escaping @MainActor (UUID) -> Void) {
        completion(session.id)
    }

    func cancel(sessionID: UUID) {}
}
