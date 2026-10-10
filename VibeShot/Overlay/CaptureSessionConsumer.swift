import AppKit
import Carbon
import Foundation

/// A session-scoped Escape key binding. Native save panels may own keyboard focus in a separate
/// process, so an AppKit local monitor cannot observe their Escape events.
@MainActor
private final class CaptureEscapeHotKey {
    private static let signature: OSType = 0x56534345
    private var handler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    var onEscape: (() -> Void)?

    init?() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout.size(ofValue: id), nil, &id)
            guard result == noErr, id.signature == CaptureEscapeHotKey.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<CaptureEscapeHotKey>.fromOpaque(userData).takeUnretainedValue().onEscape?()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard handlerStatus == noErr, handler != nil else { return nil }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let registration = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &reference)
        guard registration == noErr, reference != nil else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return nil
        }
    }

    isolated deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Pure display choice for full-screen capture. An explicit menu ID wins; generic full-screen
/// capture follows the pointer when it is over a captured display, then falls back to stable ID
/// order so a detached/ambiguous display never produces a random target.
struct FullScreenDisplayResolver: Equatable, Sendable {
    func resolve(
        command: CaptureCommand,
        descriptors: [ScreenDescriptor],
        pointer: CGPoint
    ) -> DisplayID? {
        let sorted = descriptors.sorted { $0.id.rawValue < $1.id.rawValue }
        guard case let .fullScreen(displayID: explicit) = command else { return nil }
        if let explicit, sorted.contains(where: { $0.id == explicit }) { return explicit }
        if let pointerDisplay = sorted.first(where: { $0.frame.rect.contains(pointer) }) {
            return pointerDisplay.id
        }
        return sorted.first?.id
    }
}

typealias FullScreenSelectionResolver = FullScreenDisplayResolver

/// Builds one stable panel per captured display, keeps source images immutable, and owns the
/// short-lived annotation documents through the panel controllers. M6 also owns the export
/// re-entry guard and action outcome policy; only successful terminal actions close the capture.
@MainActor
final class CaptureOverlaySessionConsumer: CaptureSessionConsuming {
    private let settingsStore: SettingsPersisting?
    private let exportCoordinator: ExportCoordinator
    private var activeSessionID: UUID?
    private var eventHandler: (@MainActor (CaptureSessionEvent) -> Void)?
    private var overlays: [DisplayID: CaptureOverlayWindowController] = [:]
    private var activeDragDisplayID: DisplayID?
    private var selectedDisplayID: DisplayID?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var escapeHotKey: CaptureEscapeHotKey?
    private var sharingHost: NSPanel?
    private let stallWatchdog = CaptureStallWatchdog()
    private var activeSession: CaptureSession?
    private var ownedSystemUI = false
    private let lifecycleMonitor: CaptureLifecycleMonitor
    private let metrics: PrivacySafeMetrics
    private var overlayStartedAt: UInt64?
    private var copyExportTask: Task<Void, Never>?
    private var copyExportID: UUID?
    private(set) var isExporting = false
    private(set) var teardownCount = 0

    /// Export failures are surfaced by the app delegate as actionable alerts. Tests and embedded
    /// callers can replace this without constructing AppKit alerts.
    var onExportFailure: ((Error) -> Void)?
    var onSettingsFailure: ((Error) -> Void)?

    var activeOverlayCount: Int { overlays.count }
    var activeDisplayID: DisplayID? { selectedDisplayID }
    var keyOverlayDisplayID: DisplayID? { overlays.first { $0.value.window?.isKeyWindow == true }?.key }

    init(
        settingsStore: SettingsPersisting? = nil,
        exportCoordinator: ExportCoordinator? = nil,
        lifecycleMonitor: CaptureLifecycleMonitor = CaptureLifecycleMonitor(),
        metrics: PrivacySafeMetrics = PrivacySafeMetrics()
    ) {
        self.settingsStore = settingsStore
        self.lifecycleMonitor = lifecycleMonitor
        self.metrics = metrics
        self.exportCoordinator = exportCoordinator ?? ExportCoordinator(settingsStore: settingsStore, metrics: metrics)
        if lifecycleMonitor.onInterruption == nil {
            lifecycleMonitor.onInterruption = { [weak self] _ in
                self?.cancelCurrentSession()
            }
        }
    }

    func consume(
        _ session: CaptureSession,
        eventHandler: @escaping @MainActor (CaptureSessionEvent) -> Void
    ) {
        // The coordinator serializes sessions, but a defensive close keeps this consumer safe if a
        // caller replaces a session directly.
        cancelCopyExport()
        if isExporting {
            activeSessionID = nil
            self.eventHandler = nil
            exportCoordinator.cancelPendingShare()
            isExporting = false
            ownedSystemUI = false
        }
        closePanels()
        self.activeSessionID = session.id
        self.eventHandler = eventHandler
        self.activeSession = session
        self.activeDragDisplayID = nil
        self.selectedDisplayID = nil
        self.ownedSystemUI = false
        self.lifecycleMonitor.ownedSystemUI = false
        self.isExporting = false
        self.overlayStartedAt = DispatchTime.now().uptimeNanoseconds

        var built: [DisplayID: CaptureOverlayWindowController] = [:]
        for snapshot in session.displays.sorted(by: { $0.displayID.rawValue < $1.displayID.rawValue }) {
            let initialColor = settingsStore?.settings.lastColor ?? .defaultColor
            let initialWidth = CGFloat(settingsStore?.settings.lastStrokeWidth ?? Double(AnnotationStyle.default.width))
            let controller = CaptureOverlayWindowController(
                sessionID: session.id,
                snapshot: snapshot,
                initialColor: initialColor,
                initialWidth: initialWidth
            )
            controller.onMouseDown = { [weak self] controller, point in
                self?.mouseDown(on: controller, at: point)
            }
            controller.onMouseDragged = { [weak self] controller, point in
                self?.mouseDragged(on: controller, at: point)
            }
            controller.onMouseUp = { [weak self] controller, point in
                self?.mouseUp(on: controller, at: point)
            }
            controller.onCommandA = { [weak self] controller in
                self?.commandA(on: controller)
            }
            controller.onEscape = { [weak self] _ in
                self?.cancelCurrentSession()
            }
            controller.onColorChanged = { [weak self] _, color in
                self?.persistLastColor(color)
            }
            controller.onWidthChanged = { [weak self] _, width in
                self?.persistLastWidth(width)
            }
            controller.onEditorAction = { [weak self, weak controller] _, action in
                guard let self, let controller else { return }
                self.handle(action, on: controller)
            }
            controller.onCompletedSelectionChange = { [weak self] controller, selection in
                self?.persistCompletedSelection(selection, on: controller)
            }
            built[snapshot.displayID] = controller
        }
        overlays = built

        var restoredDisplayID: DisplayID?
        if case .region = session.command,
           settingsStore?.settings.rememberLastRegion == true,
           let target = RememberedRegionDisplayResolver.resolve(command: session.command, descriptors: session.displays.map(\.descriptor), pointer: session.pointerLocation),
           let key = target.persistentDisplayID,
           let remembered = settingsStore?.settings.rememberedRegions[key],
           let region = remembered.displayLocalRect(in: CGRect(origin: .zero, size: target.frame.rect.size)),
           overlays[target.id]?.restoreSelection(region) == true {
            restoredDisplayID = target.id
            selectedDisplayID = target.id
        }

        // All panels are now fully configured, including their stable bitmap backgrounds, before
        // any one is shown. This avoids exposing an un-dimmed desktop during construction.
        overlays.values.forEach { $0.show() }
        NSApp.activate(ignoringOtherApps: true)
        let keyTarget = restoredDisplayID ?? overlays.keys.max { $0.rawValue < $1.rawValue }
        if let keyTarget { overlays[keyTarget]?.window?.makeKey() }
        installLocalMouseMonitor()
        installLocalKeyMonitor()
        escapeHotKey = CaptureEscapeHotKey()
        escapeHotKey?.onEscape = { [weak self] in self?.cancelCurrentSession() }
        stallWatchdog.arm()

        switch session.command {
        case .region:
            emit(restoredDisplayID == nil ? .selecting(sessionID: session.id) : .editing(sessionID: session.id))
        case .fullScreen:
            let targetID = preferredFullScreenDisplayID(for: session)
            if let targetID, let target = overlays[targetID] {
                clearSelections(except: targetID)
                target.selectAll()
                selectedDisplayID = targetID
            }
            // Full-screen capture has no drag phase: the complete display is committed as the
            // selection immediately and the user starts in the editing state.
            emit(.editing(sessionID: session.id))
        }
    }

    /// Source-compatible M2 completion entry point. The event-based overload above is the path
    /// used by the coordinator for the real overlay consumer.
    func consume(_ session: CaptureSession, completion: @escaping @MainActor (UUID) -> Void) {
        consume(session) { event in
            if event.isTerminal { completion(event.sessionID) }
        }
    }

    func cancel(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        cancelCopyExport()
        let callback = eventHandler
        // Invalidate callbacks before asking a retained share picker to dismiss. AppKit may report
        // that dismissal synchronously; the old callback must not re-enter a newer terminal path.
        activeSessionID = nil
        if isExporting { exportCoordinator.cancelPendingShare() }
        isExporting = false
        ownedSystemUI = false
        lifecycleMonitor.ownedSystemUI = false
        closePanels()
        eventHandler = nil
        activeSession = nil
        activeDragDisplayID = nil
        selectedDisplayID = nil
        callback?(.cancelled(sessionID: sessionID))
    }

    private func mouseDown(on controller: CaptureOverlayWindowController, at point: CGPoint) {
        guard activeSessionID == controller.sessionID else { return }
        let hit = controller.beginInteraction(at: point)
        guard controller.isInteracting else { return }
        if hit == .outside, controller.annotationTool == .select {
            clearSelections(except: controller.descriptor.id)
            emit(.selecting(sessionID: controller.sessionID))
        }
        selectedDisplayID = controller.descriptor.id
        activeDragDisplayID = controller.descriptor.id
    }

    private func mouseDragged(on controller: CaptureOverlayWindowController, at point: CGPoint) {
        guard activeSessionID == controller.sessionID,
              activeDragDisplayID == controller.descriptor.id
        else { return }
        controller.updateInteraction(at: point)
    }

    private func mouseUp(on controller: CaptureOverlayWindowController, at point: CGPoint) {
        guard activeSessionID == controller.sessionID,
              activeDragDisplayID == controller.descriptor.id
        else { return }
        _ = controller.endInteraction(at: point)
        activeDragDisplayID = nil
        selectedDisplayID = controller.descriptor.id
        emit(.editing(sessionID: controller.sessionID))
    }

    private func commandA(on controller: CaptureOverlayWindowController) {
        guard activeSessionID == controller.sessionID else { return }
        clearSelections(except: controller.descriptor.id)
        controller.selectAll()
        selectedDisplayID = controller.descriptor.id
        emit(.editing(sessionID: controller.sessionID))
    }

    private func clearSelections(except displayID: DisplayID) {
        for (id, controller) in overlays where id != displayID {
            controller.clearSelection()
        }
    }

    private func preferredFullScreenDisplayID(for session: CaptureSession) -> DisplayID? {
        FullScreenDisplayResolver().resolve(
            command: session.command,
            descriptors: session.displays.map(\.descriptor),
            pointer: NSEvent.mouseLocation
        )
    }

    private func persistCompletedSelection(_ selection: DisplayLocalRect, on controller: CaptureOverlayWindowController) {
        guard activeSessionID == controller.sessionID,
              case .region = activeSession?.command,
              let settingsStore, settingsStore.settings.rememberLastRegion,
              let key = controller.descriptor.persistentDisplayID,
              let value = RememberedRegion.normalized(
                from: selection,
                in: CGRect(origin: .zero, size: controller.descriptor.frame.rect.size)
              ) else { return }
        do {
            try settingsStore.update { $0.rememberedRegions[key] = value }
        } catch {
            presentSettingsFailure(error, sessionID: controller.sessionID)
        }
    }

    private func presentSettingsFailure(_ error: Error, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        beginOwnedSystemUI(sessionID: sessionID)
        onSettingsFailure?(error)
        guard activeSessionID == sessionID else { return }
        ownedSystemUI = false
        lifecycleMonitor.ownedSystemUI = false
        overlays.values.forEach { $0.show() }
        NSApp.activate(ignoringOtherApps: true)
        if let selectedDisplayID { overlays[selectedDisplayID]?.window?.makeKey() }
    }

    private func emit(_ event: CaptureSessionEvent) {
        guard activeSessionID == event.sessionID else { return }
        eventHandler?(event)
    }

    private func handle(_ action: CaptureEditorAction, on controller: CaptureOverlayWindowController) {
        guard activeSessionID == controller.sessionID else { return }
        if action == .cancel {
            cancelCurrentSession()
            return
        }
        // Every action, including the save panel/share picker, is single-flight. The guard is
        // checked before composing so repeated key presses cannot race two writes or two panels.
        guard !isExporting else { return }
        guard let activeSessionID else { return }
        isExporting = true
        setEditorActionsEnabled(false, busy: true)
        if action != .copy { beginOwnedSystemUI(sessionID: activeSessionID) }
        emit(.exporting(sessionID: activeSessionID))

        do {
            let input = try controller.makeExportInput()
            switch action {
            case .copy:
                beginCopyExport(input: input, sessionID: activeSessionID)
            case .save, .saveAs:
                beginSaveExport(input: input, action: action, sessionID: activeSessionID)
            case .print:
                let result = try exportCoordinator.print(input: input)
                finish(action: action, result: result, sessionID: activeSessionID)
            case .share:
                // The picker owns the completion boundary. Keep exporting/system-UI state alive
                // until its delegate reports success, dismissal, or failure.
                try exportCoordinator.share(input: input, from: makeSharingHost()) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.finish(action: .share, result: result, sessionID: activeSessionID)
                    }
                }
            case .cancel:
                finish(action: action, result: .cancelled, sessionID: activeSessionID)
            }
        } catch {
            reportExportFailure(error, action: action, sessionID: activeSessionID)
        }
    }

    private func beginCopyExport(input: ExportInput, sessionID: UUID) {
        let exportID = UUID()
        copyExportID = exportID
        copyExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let representations = try await self.exportCoordinator.prepareCopy(input: input)
                guard !Task.isCancelled,
                      self.activeSessionID == sessionID,
                      self.copyExportID == exportID,
                      self.isExporting
                else { return }
                let result = try self.exportCoordinator.publishCopy(representations)
                guard !Task.isCancelled,
                      self.activeSessionID == sessionID,
                      self.copyExportID == exportID
                else { return }
                self.copyExportTask = nil
                self.copyExportID = nil
                self.finish(action: .copy, result: result, sessionID: sessionID)
            } catch is CancellationError {
                // Cancellation/replacement invalidates this task before pasteboard publication.
            } catch {
                guard !Task.isCancelled,
                      self.activeSessionID == sessionID,
                      self.copyExportID == exportID
                else { return }
                self.copyExportTask = nil
                self.copyExportID = nil
                self.reportExportFailure(error, action: .copy, sessionID: sessionID)
            }
        }
    }

    private func reportExportFailure(_ error: Error, action: CaptureEditorAction, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        beginOwnedSystemUI(sessionID: sessionID)
        onExportFailure?(error)
        finish(action: action, result: .failed, sessionID: sessionID)
    }

    private func beginSaveExport(input: ExportInput, action: CaptureEditorAction, sessionID: UUID) {
        let job = UUID()
        copyExportID = job
        copyExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await exportCoordinator.saveAsync(input: input, saveAs: action == .saveAs) { [weak self] in
                    self?.activeSessionID == sessionID && self?.copyExportID == job
                }
                guard activeSessionID == sessionID, copyExportID == job else { return }
                copyExportTask = nil
                copyExportID = nil
                finish(action: action, result: result.result, sessionID: sessionID)
            } catch is CancellationError {
            } catch {
                guard activeSessionID == sessionID, copyExportID == job else { return }
                copyExportTask = nil
                copyExportID = nil
                reportExportFailure(error, action: action, sessionID: sessionID)
            }
        }
    }

    private func beginOwnedSystemUI(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        ownedSystemUI = true
        lifecycleMonitor.ownedSystemUI = true
        overlays.values.forEach { $0.window?.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeSharingHost() -> NSView {
        let panel = NSPanel(contentRect: NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 240, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Share Capture"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        sharingHost = panel
        panel.makeKeyAndOrderFront(nil)
        return panel.contentView!
    }

    private func finish(action: CaptureEditorAction, result: ExportActionResult, sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        let shouldClose = CaptureActionPolicy.shouldClose(action: action, result: result)
        isExporting = false
        setEditorActionsEnabled(true)
        ownedSystemUI = false
        lifecycleMonitor.ownedSystemUI = false
        sharingHost?.close()
        sharingHost = nil
        if shouldClose {
            completeCurrentSession(sessionID: sessionID)
        } else {
            overlays.values.forEach { $0.show() }
            NSApp.activate(ignoringOtherApps: true)
            if let selectedDisplayID { overlays[selectedDisplayID]?.window?.makeKey() }
            emit(.editing(sessionID: sessionID))
        }
    }

    private func completeCurrentSession(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        cancelCopyExport()
        let callback = eventHandler
        closePanels()
        activeSessionID = nil
        eventHandler = nil
        activeSession = nil
        isExporting = false
        ownedSystemUI = false
        lifecycleMonitor.ownedSystemUI = false
        callback?(.completed(sessionID: sessionID))
    }

    private func cancelCurrentSession() {
        guard let activeSessionID else { return }
        cancel(sessionID: activeSessionID)
    }

    func cancelActiveCapture() { cancelCurrentSession() }

    private func cancelCopyExport() {
        copyExportTask?.cancel()
        copyExportTask = nil
        copyExportID = nil
    }

    private func setEditorActionsEnabled(_ enabled: Bool, busy: Bool = false) {
        overlays.values.forEach { $0.setEditorActionsEnabled(enabled, busy: busy) }
    }

    private func closePanels() {
        stallWatchdog.disarm()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
        escapeHotKey = nil
        sharingHost?.close()
        sharingHost = nil
        if let overlayStartedAt, !overlays.isEmpty {
            let residentBytes = activeSession.map { privacySafeEstimatedBytes(for: $0.displays) } ?? 0
            metrics.record(
                .overlay,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- overlayStartedAt,
                count: overlays.count,
                estimatedBytes: residentBytes,
                residentBytes: residentBytes
            )
            teardownCount += 1
        }
        self.overlayStartedAt = nil
        removeLocalMouseMonitor()
        overlays.values.forEach { $0.closeOverlay() }
        overlays.removeAll()
        activeDragDisplayID = nil
        selectedDisplayID = nil
        activeSession = nil
    }

    private func installLocalMouseMonitor() {
        removeLocalMouseMonitor()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self,
                  let displayID = self.activeDragDisplayID,
                  let controller = self.overlays[displayID],
                  self.activeSessionID == controller.sessionID
            else { return event }

            let point = NSEvent.mouseLocation
            switch event.type {
            case .leftMouseDragged:
                controller.updateInteraction(at: point)
            case .leftMouseUp:
                _ = controller.endInteraction(at: point)
                self.activeDragDisplayID = nil
                self.selectedDisplayID = controller.descriptor.id
                self.emit(.editing(sessionID: controller.sessionID))
            default:
                return event
            }
            return nil
        }
    }

    private func installLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.activeSessionID != nil else { return event }
            switch CaptureEmergencyKey.action(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers) {
            case .cancel:
                self.cancelCurrentSession()
                return nil
            case .quit:
                self.cancelCurrentSession()
                // Let the native save/print modal session unwind before termination. AppKit may
                // defer a terminate request made synchronously from its panel event callback.
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return nil
            case nil: return event
            }
        }
    }

    private func removeLocalMouseMonitor() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func persistLastColor(_ color: AnnotationColor) {
        guard let settingsStore else { return }
        try? settingsStore.update { $0.lastColor = color }
    }

    private func persistLastWidth(_ width: CGFloat) {
        guard let settingsStore else { return }
        try? settingsStore.update { $0.lastStrokeWidth = Double(width) }
    }

}
