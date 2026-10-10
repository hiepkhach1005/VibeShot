import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VibeShot

struct M2CaptureTests {
    @Test @MainActor
    func requestSamplesPointerBeforeSnapshotWork() async throws {
        let display = testDescriptor(id: 1)
        let pointer = PointerSpy(location: GlobalScreenPoint(x: 105, y: 20))
        let consumer = SessionConsumerSpy()
        let snapshots = SnapshotProviderSpy(snapshots: [DisplaySnapshot(descriptor: display, image: try #require(testImage()))])
        let coordinator = CaptureCoordinator(
            permissionService: PermissionSpy(granted: true),
            displayProvider: DisplayProviderSpy(descriptors: [display]),
            snapshotProvider: snapshots,
            pointerProvider: pointer,
            sessionConsumer: consumer,
            permissionRecoveryPresenter: PermissionRecoverySpy()
        )
        coordinator.requestCapture(.region)
        pointer.location = GlobalScreenPoint(x: 500, y: 500)
        await snapshots.waitUntilCalled()
        await drainCaptureTask()
        #expect(consumer.sessions.first?.pointerLocation == GlobalScreenPoint(x: 105, y: 20))
        coordinator.cancelCapture()
    }
    @Test
    func geometryHandlesNegativeOriginMixedScaleAndVerticalFlip() throws {
        let descriptor = ScreenDescriptor(
            id: DisplayID(17),
            frame: GlobalScreenRect(CGRect(x: -1440, y: 120, width: 1440, height: 900)),
            pointPixelScale: 2,
            pixelSize: PixelSize(width: 2880, height: 1800)
        )
        let geometry = DisplayGeometry(descriptor: descriptor)
        try geometry.validate()

        let global = GlobalScreenRect(CGRect(x: -1430, y: 140, width: 30, height: 40))
        let local = geometry.displayLocalRect(for: global)
        #expect(local.rect == CGRect(x: 10, y: 20, width: 30, height: 40))

        let pixels = geometry.imagePixelRect(for: local)
        #expect(pixels == ImagePixelRect(x: 20, y: 1680, width: 60, height: 80))
        #expect(geometry.displayLocalRect(for: pixels).rect == local.rect)
        #expect(geometry.globalRect(for: pixels).rect == global.rect)
    }

    @Test
    func geometryRoundsOutwardAndClampsToAuthoritativeImage() {
        let descriptor = ScreenDescriptor(
            id: DisplayID(18),
            frame: GlobalScreenRect(CGRect(x: -100, y: -600, width: 100, height: 100)),
            pointPixelScale: 2,
            pixelSize: PixelSize(width: 200, height: 200)
        )
        let geometry = DisplayGeometry(descriptor: descriptor, imageSize: PixelSize(width: 180, height: 160))
        let partiallyOutside = GlobalScreenRect(CGRect(x: -101, y: -601, width: 4.25, height: 4.25))
        let pixels = geometry.imagePixelRect(for: partiallyOutside)
        #expect(pixels.x == 0)
        #expect(pixels.y == 153)
        #expect(pixels.width == 7)
        #expect(pixels.height == 7)
        #expect(pixels.maxX <= 180)
        #expect(pixels.maxY <= 160)
    }

    @Test
    @MainActor
    func permissionIsOnlyRequestedWhenPreflightFailsAndSessionIsConsumed() async throws {
        let permission = PermissionSpy(granted: true)
        let provider = DisplayProviderSpy(descriptors: [testDescriptor(id: 1)])
        let image = try #require(testImage())
        let snapshotProvider = SnapshotProviderSpy(snapshots: [DisplaySnapshot(descriptor: provider.descriptors[0], image: image)])
        let consumer = SessionConsumerSpy(autoComplete: true)
        let coordinator = CaptureCoordinator(
            permissionService: permission,
            displayProvider: provider,
            snapshotProvider: snapshotProvider,
            sessionConsumer: consumer,
            permissionRecoveryPresenter: PermissionRecoverySpy()
        )

        coordinator.requestCapture(.region)
        await snapshotProvider.waitUntilCallCount(1)
        await drainCaptureTask()

        #expect(permission.requestCount == 0)
        #expect(await snapshotProvider.callCountValue() == 1)
        #expect(consumer.sessions.count == 1)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.activeSession == nil)
    }

    @Test
    @MainActor
    func deniedPermissionUsesRecoveryAndReturnsToIdle() async {
        let permission = PermissionSpy(granted: false, requestResult: false)
        let recovery = PermissionRecoverySpy()
        let coordinator = CaptureCoordinator(
            permissionService: permission,
            displayProvider: DisplayProviderSpy(descriptors: [testDescriptor(id: 1)]),
            snapshotProvider: SnapshotProviderSpy(snapshots: []),
            sessionConsumer: SessionConsumerSpy(),
            permissionRecoveryPresenter: recovery
        )

        coordinator.requestCapture(.region)
        await drainCaptureTask()

        #expect(permission.requestCount == 1)
        #expect(recovery.presentCount == 1)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.activeSession == nil)
    }

    @Test
    @MainActor
    func staleConsumerCallbackCannotTearDownNewSession() async throws {
        let permission = PermissionSpy(granted: true)
        let provider = DisplayProviderSpy(descriptors: [testDescriptor(id: 1)])
        let image = try #require(testImage())
        let snapshotProvider = SnapshotProviderSpy(snapshots: [DisplaySnapshot(descriptor: provider.descriptors[0], image: image)])
        let consumer = SessionConsumerSpy()
        let coordinator = CaptureCoordinator(
            permissionService: permission,
            displayProvider: provider,
            snapshotProvider: snapshotProvider,
            sessionConsumer: consumer,
            permissionRecoveryPresenter: PermissionRecoverySpy()
        )

        coordinator.requestCapture(.region)
        await snapshotProvider.waitUntilCallCount(1)
        await drainCaptureTask()
        let firstID = try #require(consumer.sessions.first?.id)
        coordinator.cancelCapture()
        coordinator.requestCapture(.region)
        await snapshotProvider.waitUntilCallCount(2)
        await drainCaptureTask()
        let secondID = try #require(consumer.sessions.last?.id)
        #expect(firstID != secondID)
        consumer.complete(firstID)
        #expect(coordinator.phase == .consuming)
        consumer.complete(secondID)
        #expect(coordinator.phase == .idle)
    }

    @Test
    @MainActor
    func incompleteSnapshotSetDoesNotReachConsumer() async throws {
        let permission = PermissionSpy(granted: true)
        let provider = DisplayProviderSpy(descriptors: [testDescriptor(id: 1), testDescriptor(id: 2)])
        let image = try #require(testImage())
        let snapshots = [DisplaySnapshot(descriptor: provider.descriptors[0], image: image)]
        let consumer = SessionConsumerSpy()
        let snapshotProvider = SnapshotProviderSpy(snapshots: snapshots)
        let coordinator = CaptureCoordinator(
            permissionService: permission,
            displayProvider: provider,
            snapshotProvider: snapshotProvider,
            sessionConsumer: consumer,
            permissionRecoveryPresenter: PermissionRecoverySpy()
        )

        coordinator.requestCapture(.region)
        await snapshotProvider.waitUntilCalled()
        await drainCaptureTask()

        #expect(consumer.sessions.isEmpty)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.lastError as? CaptureCoordinatorError == .snapshotSetIncomplete)
    }

    @Test
    @MainActor
    func multiDisplayMenuUsesTypedDisplayIDs() throws {
        _ = NSApplication.shared
        let displayProvider = DisplayProviderSpy(descriptors: [testDescriptor(id: 9), testDescriptor(id: 4)])
        let capture = MenuCaptureSpy()
        let settings = M2MemorySettingsStore()
        let controller = StatusItemController(
            settingsStore: settings,
            captureHandler: capture,
            loginService: M2LoginSpy(),
            shortcutService: M2HotKeySpy(),
            displayProvider: displayProvider
        )
        controller.rebuildMenu()
        let parent = try #require(controller.menu.item(withTitle: "Capture Full Screen"))
        let children = try #require(parent.submenu?.items.filter { !$0.isSeparatorItem })
        #expect(children.map { $0.representedObject as? DisplayID } == [DisplayID(4), DisplayID(9)])
        NSApp.sendAction(children[0].action!, to: children[0].target, from: children[0])
        #expect(capture.commands == [.fullScreen(displayID: DisplayID(4))])
    }

    private func testDescriptor(id: UInt32) -> ScreenDescriptor {
        ScreenDescriptor(
            id: DisplayID(id),
            frame: GlobalScreenRect(CGRect(x: CGFloat(id) * 100, y: 0, width: 100, height: 80)),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: 100, height: 80)
        )
    }

    private func testImage() -> CGImage? {
        let width = 2
        let height = 2
        let data = Data(repeating: 0, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func drainCaptureTask() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor private final class PointerSpy: CapturePointerProviding {
    var location: GlobalScreenPoint?
    init(location: GlobalScreenPoint?) { self.location = location }
    func currentPointerLocation() -> GlobalScreenPoint? { location }
}

private final class PermissionSpy: CapturePermissionProviding, @unchecked Sendable {
    var granted: Bool
    let requestResult: Bool
    private(set) var requestCount = 0

    init(granted: Bool, requestResult: Bool = true) {
        self.granted = granted
        self.requestResult = requestResult
    }

    func hasScreenCapturePermission() -> Bool { granted }
    func requestScreenCapturePermission() -> Bool {
        requestCount += 1
        if requestResult { granted = true }
        return requestResult
    }
}

@MainActor
private final class DisplayProviderSpy: DisplayDescriptorProviding {
    let descriptors: [ScreenDescriptor]
    init(descriptors: [ScreenDescriptor]) { self.descriptors = descriptors }
    func currentDisplayDescriptors() throws -> [ScreenDescriptor] { descriptors }
}

private actor SnapshotProviderSpy: ScreenSnapshotProviding {
    let snapshots: [DisplaySnapshot]
    private var callCount = 0
    private var callContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    init(snapshots: [DisplaySnapshot]) { self.snapshots = snapshots }
    func captureDisplays(for descriptors: [ScreenDescriptor]) async throws -> [DisplaySnapshot] {
        callCount += 1
        let continuation = callContinuations.removeValue(forKey: callCount)
        continuation?.resume()
        return snapshots
    }
    func callCountValue() -> Int { callCount }
    func waitUntilCalled() async {
        await waitUntilCallCount(1)
    }
    func waitUntilCallCount(_ expected: Int) async {
        if callCount >= expected { return }
        await withCheckedContinuation { callContinuations[expected] = $0 }
    }
}

@MainActor
private final class SessionConsumerSpy: CaptureSessionConsuming {
    private let autoComplete: Bool
    private(set) var sessions: [CaptureSession] = []
    private(set) var completions: [@MainActor (UUID) -> Void] = []
    init(autoComplete: Bool = false) { self.autoComplete = autoComplete }
    func consume(_ session: CaptureSession, completion: @escaping @MainActor (UUID) -> Void) {
        sessions.append(session)
        completions.append(completion)
        if autoComplete { completion(session.id) }
    }
    func complete(_ id: UUID) { completions.forEach { $0(id) } }
}

@MainActor
private final class PermissionRecoverySpy: PermissionRecoveryPresenting {
    private(set) var presentCount = 0
    func presentScreenRecordingDenied() { presentCount += 1 }
}

@MainActor
private final class MenuCaptureSpy: CaptureCommandHandling {
    private(set) var commands: [CaptureCommand] = []
    func requestCapture(_ command: CaptureCommand) { commands.append(command) }
}

private final class M2MemorySettingsStore: SettingsPersisting {
    var settings = AppSettings()
    var loadError: SettingsStoreError?
    func update(_ mutation: (inout AppSettings) -> Void) throws {
        var value = settings
        mutation(&value)
        value.validate()
        settings = value
    }
}

@MainActor
private final class M2LoginSpy: LoginItemServicing {
    var state: LoginItemState = .disabled
    func setEnabled(_ enabled: Bool) throws { state = enabled ? .enabled : .disabled }
}

@MainActor
private final class M2HotKeySpy: HotKeyRegistering {
    func register(kind: ShortcutKind, shortcut: ShortcutDefinition) throws {}
    func unregister(kind: ShortcutKind) {}
}
