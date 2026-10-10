import AppKit
import Foundation
import Darwin

enum CaptureEmergencyKey {
    enum Action { case cancel, quit }
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Action? {
        if keyCode == 53 { return .cancel }
        if modifiers.contains(.command), characters?.lowercased() == "q" { return .quit }
        return nil
    }
}

/// A narrow last resort for a wedged main thread while capture owns the screen. Absolute Mach
/// time excludes sleep. The lock serializes disarm/re-arm with the final exit decision.
final class CaptureStallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID?
    private var heartbeat: UInt64 = 0
    private var source: DispatchSourceTimer?
    private var timer: Timer?
    private let threshold: Double
    private let exitProcess: @Sendable () -> Void
    private let secondsPerTick: Double
    private let clock: @Sendable () -> UInt64

    init(threshold: Double = 30, clock: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }, exitProcess: @escaping @Sendable () -> Void = { _exit(70) }) {
        self.threshold = threshold
        self.clock = clock
        self.exitProcess = exitProcess
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        secondsPerTick = Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    @MainActor func arm() {
        disarm()
        let id = UUID()
        lock.withLock { generation = id; heartbeat = clock() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.beat(id: id) }
        self.timer = timer
        for mode in [RunLoop.Mode.common, .default, .eventTracking, .modalPanel] {
            RunLoop.main.add(timer, forMode: mode)
        }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "VibeShot.capture-heartbeat"))
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { @Sendable [weak self] in
            guard let self else { return }
            self.check(id: id, now: self.clock())
        }
        self.source = source
        source.resume()
    }

    @MainActor func disarm() {
        lock.withLock { generation = nil }
        timer?.invalidate()
        timer = nil
        source?.cancel()
        source = nil
    }

    private func beat(id: UUID) {
        lock.withLock { if generation == id { heartbeat = clock() } }
    }

    func checkNow() {
        guard let id = lock.withLock({ generation }) else { return }
        check(id: id, now: clock())
    }

    private func check(id: UUID, now: UInt64) {
        lock.withLock {
            guard generation == id, now >= heartbeat,
                  Double(now - heartbeat) * secondsPerTick >= threshold else { return }
            generation = nil
            exitProcess()
        }
    }
}

enum CaptureLifecycleInterruption: Equatable, Sendable {
    case screenTopologyChanged
    case activeSpaceChanged
    case appResignedActive
    case willSleep
    case didWake
    case memoryPressureWarning
    case memoryPressureCritical
    case permissionRevoked

    static var displayTopologyChanged: Self { .screenTopologyChanged }
    static var spaceChanged: Self { .activeSpaceChanged }
    static var memoryWarning: Self { .memoryPressureWarning }
    static var memoryCritical: Self { .memoryPressureCritical }
}

/// Owns every process-level interruption that invalidates an in-flight capture. A single monitor
/// is shared by the coordinator and overlay consumer; this prevents duplicate observers and makes
/// cancellation/idle transitions idempotent.
@MainActor
final class CaptureLifecycleMonitor {
    typealias Interruption = CaptureLifecycleInterruption
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var cancellationIssued = false
    private(set) var isMonitoring = false
    private(set) var interruptionCount = 0
    private(set) var teardownRequestCount = 0
    private(set) var lastInterruption: CaptureLifecycleInterruption?
    var ownedSystemUI = false
    var permissionProbe: (() -> Bool)?
    var onInterruption: (@MainActor (CaptureLifecycleInterruption) -> Void)?

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onInterruption: (@MainActor (CaptureLifecycleInterruption) -> Void)? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.onInterruption = onInterruption
    }

    isolated deinit {
        observers.forEach {
            notificationCenter.removeObserver($0)
            workspaceNotificationCenter.removeObserver($0)
        }
        memoryPressureSource?.cancel()
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        cancellationIssued = false
        lastInterruption = nil

        observers = [
            notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.interrupt(.screenTopologyChanged) }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.interrupt(.activeSpaceChanged) }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.interrupt(.willSleep) }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.interrupt(.didWake) }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.interrupt(.appResignedActive) }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let permissionProbe = self.permissionProbe,
                          !permissionProbe()
                    else { return }
                    self.interrupt(.permissionRevoked)
                }
            }
        ]

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let event = source.data
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.contains(.critical) {
                    self.interrupt(.memoryPressureCritical)
                } else if event.contains(.warning) {
                    self.interrupt(.memoryPressureWarning)
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func stop() {
        guard isMonitoring || !observers.isEmpty || memoryPressureSource != nil else { return }
        observers.forEach {
            notificationCenter.removeObserver($0)
            workspaceNotificationCenter.removeObserver($0)
        }
        observers.removeAll()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        isMonitoring = false
        cancellationIssued = false
        ownedSystemUI = false
    }

    /// Test and platform seams can report a permission transition without fabricating a system
    /// notification. The same idempotent cancellation path is used as for OS notifications.
    func permissionRevoked() {
        interrupt(.permissionRevoked)
    }

    func handle(_ interruption: CaptureLifecycleInterruption) {
        interrupt(interruption)
    }

    func notify(_ interruption: CaptureLifecycleInterruption) {
        interrupt(interruption)
    }

    func memoryPressureWarning() {
        interrupt(.memoryPressureWarning)
    }

    func memoryPressureCritical() {
        interrupt(.memoryPressureCritical)
    }

    /// Handles an interruption exactly once for the currently monitored capture. Deactivation is
    /// ignored only while VibeShot owns a save/print/share system UI; topology, sleep, Space,
    /// memory, and permission interruptions always tear down the capture.
    func interrupt(_ interruption: CaptureLifecycleInterruption) {
        guard isMonitoring else { return }
        if interruption == .appResignedActive, ownedSystemUI { return }
        guard !cancellationIssued else { return }
        cancellationIssued = true
        interruptionCount += 1
        teardownRequestCount += 1
        lastInterruption = interruption
        onInterruption?(interruption)
    }
}
