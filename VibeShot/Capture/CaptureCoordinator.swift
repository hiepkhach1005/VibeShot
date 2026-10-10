import Foundation

enum CaptureCoordinatorError: LocalizedError, Equatable, Sendable {
    case noDisplays
    case displayTopologyChanged
    case snapshotSetIncomplete

    var errorDescription: String? {
        switch self {
        case .noDisplays:
            "VibeShot could not find an active display to capture."
        case .displayTopologyChanged:
            "The display arrangement changed while VibeShot was capturing. Please try again."
        case .snapshotSetIncomplete:
            "VibeShot could not capture every active display, so no partial session was created."
        }
    }
}

@MainActor
final class CaptureCoordinator: CaptureCommandHandling {
    private let permissionService: any CapturePermissionProviding
    private let displayProvider: any DisplayDescriptorProviding
    private let snapshotProvider: any ScreenSnapshotProviding
    private let pointerProvider: any CapturePointerProviding
    private let sessionConsumer: any CaptureSessionConsuming
    private let permissionRecoveryPresenter: any PermissionRecoveryPresenting
    private let lifecycleMonitor: CaptureLifecycleMonitor
    private let metrics: PrivacySafeMetrics
    private var activeRequestID: UUID?
    private var captureTask: Task<Void, Never>?
    private var captureStartedAt: UInt64?

    private(set) var phase: CapturePhase = .idle
    private(set) var activeSession: CaptureSession?
    private(set) var requestedCommands: [CaptureCommand] = []
    private(set) var lastError: Error?
    private(set) var teardownCount = 0
    private(set) var lastInterruption: CaptureLifecycleInterruption?
    var onRequest: ((CaptureCommand) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(
        permissionService: any CapturePermissionProviding = CoreGraphicsCapturePermissionService(),
        displayProvider: any DisplayDescriptorProviding = NSScreenDisplayProvider(),
        snapshotProvider: any ScreenSnapshotProviding = ScreenCaptureService(),
        pointerProvider: any CapturePointerProviding = AppKitCapturePointerProvider(),
        sessionConsumer: any CaptureSessionConsuming = ImmediateCaptureSessionConsumer(),
        permissionRecoveryPresenter: any PermissionRecoveryPresenting = SystemSettingsPermissionRecoveryPresenter(),
        lifecycleMonitor: CaptureLifecycleMonitor = CaptureLifecycleMonitor(),
        metrics: PrivacySafeMetrics = PrivacySafeMetrics()
    ) {
        self.permissionService = permissionService
        self.displayProvider = displayProvider
        self.snapshotProvider = snapshotProvider
        self.pointerProvider = pointerProvider
        self.sessionConsumer = sessionConsumer
        self.permissionRecoveryPresenter = permissionRecoveryPresenter
        self.lifecycleMonitor = lifecycleMonitor
        self.metrics = metrics
        lifecycleMonitor.permissionProbe = { permissionService.hasScreenCapturePermission() }
        lifecycleMonitor.onInterruption = { [weak self] interruption in
            self?.handleLifecycleInterruption(interruption)
        }
    }

    func requestCapture(_ command: CaptureCommand) {
        guard phase == .idle else { return }

        let requestID = UUID()
        let pointerLocation = pointerProvider.currentPointerLocation()
        activeRequestID = requestID
        captureStartedAt = DispatchTime.now().uptimeNanoseconds
        lastError = nil
        lastInterruption = nil
        requestedCommands.append(command)
        phase = .checkingPermission
        lifecycleMonitor.start()
        onRequest?(command)
        captureTask = Task { [weak self] in
            await self?.performCapture(command: command, requestID: requestID, pointerLocation: pointerLocation)
        }
    }

    /// Cancellation is safe to call repeatedly and invalidates all callbacks from the old session.
    func cancelCapture() {
        guard let requestID = activeRequestID else {
            captureTask?.cancel()
            captureTask = nil
            activeSession = nil
            phase = .idle
            lifecycleMonitor.stop()
            return
        }
        captureTask?.cancel()
        // Ask the consumer to close its UI first. The callback is session-ID tagged and may
        // synchronously tear down the coordinator; the idempotent guard below handles both paths.
        sessionConsumer.cancel(sessionID: requestID)
        teardown(requestID: requestID)
    }

    /// Platform permission adapters can report a revocation while an overlay is visible. This
    /// enters the same idempotent lifecycle path as topology and memory interruptions.
    func permissionDidRevoke() {
        lifecycleMonitor.permissionRevoked()
    }

    func handlePermissionRevoked() {
        permissionDidRevoke()
    }

    private func performCapture(command: CaptureCommand, requestID: UUID, pointerLocation: GlobalScreenPoint?) async {
        do {
            try Task.checkCancellation()
            let permissionStartedAt = DispatchTime.now().uptimeNanoseconds
            var hasPermission = permissionService.hasScreenCapturePermission()
            if !hasPermission {
                // Do not prompt on every request once access has already been granted.
                _ = permissionService.requestScreenCapturePermission()
                hasPermission = permissionService.hasScreenCapturePermission()
            }
            metrics.record(
                .permission,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- permissionStartedAt,
                count: 1
            )
            guard isCurrent(requestID) else { return }
            guard hasPermission else {
                phase = .permissionRequired
                permissionRecoveryPresenter.presentScreenRecordingDenied()
                teardown(requestID: requestID)
                return
            }

            let descriptors = try displayProvider.currentDisplayDescriptors()
            guard !descriptors.isEmpty else { throw CaptureCoordinatorError.noDisplays }
            guard isCurrent(requestID) else { return }
            phase = .snapshotting

            let snapshots = try await captureSnapshots(for: descriptors)
            try Task.checkCancellation()
            guard isCurrent(requestID) else { return }

            let currentDescriptors = try displayProvider.currentDisplayDescriptors()
            guard sameTopology(descriptors, currentDescriptors) else {
                throw CaptureCoordinatorError.displayTopologyChanged
            }
            guard completeSnapshotSet(snapshots, for: descriptors) else {
                throw CaptureCoordinatorError.snapshotSetIncomplete
            }

            let session = CaptureSession(id: requestID, command: command, displays: snapshots, pointerLocation: pointerLocation)
            activeSession = session
            phase = .consuming
            sessionConsumer.consume(session, eventHandler: { [weak self] event in
                self?.handleSessionEvent(event)
            })
        } catch is CancellationError {
            if isCurrent(requestID) { teardown(requestID: requestID) }
        } catch {
            fail(error, requestID: requestID)
        }
    }

    private func captureSnapshots(for descriptors: [ScreenDescriptor]) async throws -> [DisplaySnapshot] {
        let snapshotStartedAt = DispatchTime.now().uptimeNanoseconds
        do {
            let snapshots = try await snapshotProvider.captureDisplays(for: descriptors)
            let estimatedBytes = privacySafeEstimatedBytes(for: snapshots)
            metrics.record(
                .snapshot,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- snapshotStartedAt,
                count: snapshots.count,
                estimatedBytes: estimatedBytes,
                residentBytes: estimatedBytes
            )
            return snapshots
        } catch {
            metrics.record(
                .snapshot,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- snapshotStartedAt,
                count: 0
            )
            throw error
        }
    }

    private func handleSessionEvent(_ event: CaptureSessionEvent) {
        guard isCurrent(event.sessionID) else { return }
        switch event {
        case .selecting:
            phase = .selecting
        case .editing:
            phase = .editing
        case .exporting:
            phase = .exporting
        case .completed, .cancelled:
            teardown(requestID: event.sessionID)
        }
    }

    private func fail(_ error: Error, requestID: UUID) {
        guard isCurrent(requestID) else { return }
        lastError = error
        onFailure?(error)
        teardown(requestID: requestID)
    }

    private func handleLifecycleInterruption(_ interruption: CaptureLifecycleInterruption) {
        guard activeRequestID != nil else { return }
        lastInterruption = interruption
        cancelCapture()
    }

    private func teardown(requestID: UUID) {
        guard activeRequestID == requestID else { return }
        let residentBytes = activeSession.map { privacySafeEstimatedBytes(for: $0.displays) } ?? 0
        let duration = captureStartedAt.map { DispatchTime.now().uptimeNanoseconds &- $0 } ?? 0
        teardownCount += 1
        metrics.record(
            .teardown,
            durationNanoseconds: duration,
            count: 1,
            estimatedBytes: residentBytes,
            residentBytes: residentBytes
        )
        activeRequestID = nil
        captureTask = nil
        captureStartedAt = nil
        activeSession = nil
        phase = .idle
        lifecycleMonitor.stop()
    }

    private func isCurrent(_ requestID: UUID) -> Bool {
        activeRequestID == requestID
    }

    private func sameTopology(_ lhs: [ScreenDescriptor], _ rhs: [ScreenDescriptor]) -> Bool {
        let left = lhs.sorted { $0.id.rawValue < $1.id.rawValue }
        let right = rhs.sorted { $0.id.rawValue < $1.id.rawValue }
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy {
            $0.id == $1.id && $0.frame == $1.frame &&
                $0.visibleFrame == $1.visibleFrame &&
                $0.pointPixelScale == $1.pointPixelScale && $0.pixelSize == $1.pixelSize &&
                $0.persistentDisplayID == $1.persistentDisplayID
        }
    }

    private func completeSnapshotSet(_ snapshots: [DisplaySnapshot], for descriptors: [ScreenDescriptor]) -> Bool {
        guard snapshots.count == descriptors.count else { return false }
        let expected = Set(descriptors.map(\.id))
        let actual = snapshots.map(\.displayID)
        return actual.count == Set(actual).count && Set(actual) == expected && snapshots.allSatisfy { $0.pixelSize.isValid }
    }
}
