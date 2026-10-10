import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VibeShot

struct M7HardeningTests {
    @MainActor @Test
    func emergencyKeysAndWatchdogAreSessionScoped() async throws {
        #expect(CaptureEmergencyKey.action(keyCode: 53, modifiers: [], characters: nil) == .cancel)
        #expect(CaptureEmergencyKey.action(keyCode: 12, modifiers: .command, characters: "q") == .quit)
        #expect(CaptureEmergencyKey.action(keyCode: 12, modifiers: [], characters: "q") == nil)
        let state = WatchdogTestState()
        let watchdog = CaptureStallWatchdog(threshold: 30, clock: { state.now }, exitProcess: { state.exited() })
        watchdog.checkNow()
        #expect(state.exits == 0)
        watchdog.arm()
        try await Task.sleep(for: .milliseconds(1100))
        watchdog.checkNow()
        #expect(state.exits == 0)
        state.advance()
        watchdog.checkNow()
        watchdog.checkNow()
        #expect(state.exits == 1)
        watchdog.arm()
        watchdog.disarm()
        state.advance()
        watchdog.checkNow()
        #expect(state.exits == 1)
    }

    @MainActor
    @Test
    func interruptionMatrixCancelsOnceAndHonorsOwnedSystemUI() async {
        let cases: [(CaptureLifecycleInterruption, Bool, Int)] = [
            (.screenTopologyChanged, false, 1),
            (.activeSpaceChanged, false, 1),
            (.appResignedActive, true, 0),
            (.appResignedActive, false, 1),
            (.willSleep, true, 1),
            (.didWake, true, 1),
            (.memoryPressureWarning, true, 1),
            (.memoryPressureCritical, true, 1),
            (.permissionRevoked, true, 1)
        ]

        for (interruption, ownsSystemUI, expectedCalls) in cases {
            let monitor = CaptureLifecycleMonitor(
                notificationCenter: NotificationCenter(),
                workspaceNotificationCenter: NotificationCenter()
            )
            var calls: [CaptureLifecycleInterruption] = []
            monitor.onInterruption = { calls.append($0) }
            monitor.start()
            monitor.ownedSystemUI = ownsSystemUI
            monitor.interrupt(interruption)
            monitor.interrupt(interruption)
            #expect(calls.count == expectedCalls)
            #expect(monitor.teardownRequestCount == expectedCalls)
            monitor.stop()
            #expect(!monitor.isMonitoring)
        }

        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let monitor = CaptureLifecycleMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter
        )
        var delivered = 0
        monitor.onInterruption = { _ in delivered += 1 }
        monitor.start()
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<3 { await Task.yield() }
        #expect(delivered == 1)
        monitor.stop()
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<3 { await Task.yield() }
        #expect(delivered == 1)
    }

    @MainActor
    @Test
    func exportFaultAndCancelMatrixRetainsCapture() throws {
        let image = try #require(m7Image())
        let descriptor = ScreenDescriptor(
            id: DisplayID(7),
            frame: GlobalScreenRect(CGRect(x: 0, y: 0, width: 4, height: 4)),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: 4, height: 4)
        )
        let input = try ExportInput(
            sourceImage: image,
            descriptor: descriptor,
            selection: DisplayLocalRect(CGRect(x: 0, y: 0, width: 4, height: 4))
        )

        let cases: [(String, TestImageEncoder.Mode, URL?, ExportActionResult)] = [
            ("encoder", .failure, URL(fileURLWithPath: "/tmp/M7-hardening.png"), .failed),
            ("cancel", .success, nil, .cancelled)
        ]
        for (_, mode, pickedURL, expected) in cases {
            let panel = M7SavePanelSpy(url: pickedURL)
            let coordinator = ExportCoordinator(
                encoder: TestImageEncoder(mode: mode),
                savePanel: panel,
                fileWriter: M7FileWriterSpy(),
                metrics: .noop
            )
            if mode == .failure {
                #expect(throws: ExportError.self) { try coordinator.save(input: input, saveAs: true) }
            } else {
                #expect(try coordinator.save(input: input, saveAs: true).result == expected)
            }
            #expect(CaptureActionPolicy.outcome(for: .saveAs, result: expected) == .retain)
        }

        let sink = RecordingPrivacySafeMetricsSink()
        let metrics = PrivacySafeMetrics(sink: sink)
        metrics.record(
            .teardown,
            durationNanoseconds: 7,
            count: 1,
            estimatedBytes: 11,
            residentBytes: 13
        )
        #expect(sink.metrics == [PrivacySafeMetric(
            stage: .teardown,
            durationNanoseconds: 7,
            count: 1,
            estimatedBytes: 11,
            residentBytes: 13
        )])
    }

    @MainActor
    @Test
    func revokedPermissionReturnsCoordinatorToIdleOnce() async throws {
        let image = try #require(m7Image())
        let descriptor = ScreenDescriptor(
            id: DisplayID(3),
            frame: GlobalScreenRect(CGRect(x: 0, y: 0, width: 1, height: 1)),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: 1, height: 1)
        )
        let consumer = M7SessionConsumerSpy()
        let coordinator = CaptureCoordinator(
            permissionService: M7PermissionSpy(),
            displayProvider: M7DisplayProvider(descriptor: descriptor),
            snapshotProvider: M7SnapshotProvider(snapshot: DisplaySnapshot(descriptor: descriptor, image: image)),
            sessionConsumer: consumer,
            permissionRecoveryPresenter: M7PermissionRecoverySpy(),
            lifecycleMonitor: CaptureLifecycleMonitor(
                notificationCenter: NotificationCenter(),
                workspaceNotificationCenter: NotificationCenter()
            ),
            metrics: .noop
        )

        coordinator.requestCapture(.region)
        for _ in 0..<12 { await Task.yield() }
        #expect(coordinator.phase == .consuming)

        let revocationCalls = [1, 2]
        for _ in revocationCalls { coordinator.permissionDidRevoke() }
        #expect(coordinator.phase == .idle)
        #expect(coordinator.activeSession == nil)
        #expect(coordinator.teardownCount == 1)
        #expect(consumer.cancelledIDs.count == 1)
    }

    private func m7Image() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()
    }
}

private final class WatchdogTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: UInt64 = 0
    private var count = 0
    var now: UInt64 { lock.withLock { tick } }
    var exits: Int { lock.withLock { count } }
    func advance() { lock.withLock { tick += 1_000_000_000_000 } }
    func exited() { lock.withLock { count += 1 } }
}

private struct TestImageEncoder: ImageEncoding {
    enum Mode: Equatable { case success, failure }
    let mode: Mode

    func encode(_ image: CGImage, format: OutputFormat, quality: Int) throws -> Data {
        if mode == .failure { throw ImageEncodingError.finalizeFailed }
        return Data([0x89, 0x50, 0x4e, 0x47])
    }
}

@MainActor
private final class M7SavePanelSpy: SavePanelPresenting {
    let url: URL?
    init(url: URL?) { self.url = url }
    func chooseURL(defaultDirectory: URL?, suggestedFileName: String, format: OutputFormat) throws -> URL? { url }
}

private struct M7FileWriterSpy: AtomicFileWriting {
    func writeAtomically(_ data: Data, to url: URL) throws {}
}

private struct M7PermissionSpy: CapturePermissionProviding {
    func hasScreenCapturePermission() -> Bool { true }
    func requestScreenCapturePermission() -> Bool { true }
}

@MainActor
private final class M7DisplayProvider: DisplayDescriptorProviding {
    let descriptor: ScreenDescriptor
    init(descriptor: ScreenDescriptor) { self.descriptor = descriptor }
    func currentDisplayDescriptors() throws -> [ScreenDescriptor] { [descriptor] }
}

private struct M7SnapshotProvider: ScreenSnapshotProviding {
    let snapshot: DisplaySnapshot
    func captureDisplays(for descriptors: [ScreenDescriptor]) async throws -> [DisplaySnapshot] { [snapshot] }
}

@MainActor
private final class M7PermissionRecoverySpy: PermissionRecoveryPresenting {
    func presentScreenRecordingDenied() {}
}

@MainActor
private final class M7SessionConsumerSpy: CaptureSessionConsuming {
    private(set) var cancelledIDs: [UUID] = []
    func consume(_ session: CaptureSession, eventHandler: @escaping @MainActor (CaptureSessionEvent) -> Void) {
    }
    func consume(_ session: CaptureSession, completion: @escaping @MainActor (UUID) -> Void) {}
    func cancel(sessionID: UUID) { cancelledIDs.append(sessionID) }
}
